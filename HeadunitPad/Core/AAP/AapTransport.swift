//
//  AapTransport.swift
//  HeadunitPad
//
//  Android Auto Protocol transport layer with OpenSSL TLS support
//

import Foundation
import Network
import CoreLocation

protocol AapTransportDelegate: AnyObject {
    func aapTransport(_ transport: AapTransport, didReceiveVideoData data: Data)
    func aapTransport(_ transport: AapTransport, didReceiveAudioData data: Data, on channel: UInt8)
    func aapTransport(_ transport: AapTransport, didRequestMicrophoneCapture isOpen: Bool)
    func aapTransport(_ transport: AapTransport, didRequestLocationUpdates isEnabled: Bool)
    func aapTransport(_ transport: AapTransport, didChangeState state: AapTransportState)
    func aapTransportDidDisconnect(_ transport: AapTransport)
}

enum AapTransportState: Equatable {
    case idle
    case waitingForVersion
    case versionSent
    case tlsHandshaking
    case authenticating
    case authenticatingComplete
    case binding
    case running
    case error(String)
}

class AapTransport {
    weak var delegate: AapTransportDelegate?

    private let tcpHandler: TcpHandler
    private let tlsHandler = OpenSslTlsHandler()
    private let handshakeQueue = DispatchQueue(label: "com.headunitpad.aap.handshake", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "com.headunitpad.aap.processing", qos: .userInitiated)
    private let mediaAckQueue = DispatchQueue(label: "com.headunitpad.aap.media-ack", qos: .utility)
    private var state: AapTransportState = .idle
    private var handshakeTimer: DispatchWorkItem?
    private let versionHandshakeTimeout: TimeInterval = 10.0
    private let tlsHandshakeTimeout: TimeInterval = 15.0
    private let initialVersionRequestDelay: TimeInterval = 0.5
    private let versionRetryInterval: TimeInterval = 2.0
    private let maxVersionRequestAttempts = 3
    private var versionRequestAttempts = 0
    private var versionRetryWorkItem: DispatchWorkItem?
    private var delayedVersionStartWorkItem: DispatchWorkItem?
    private var peerHost: String?
    private var peerPort: UInt16 = 5277
    private var hasTriggeredLauncherPoke = false
    private let enableLauncherPokeFallback = false
    private var tlsIdentityReady = false
    private var mediaSessionIds: [UInt8: UInt64] = [:]
    private var videoAssemblyBuffer = Data()
    private var videoFirstFragmentAtMs: UInt64 = 0
    private var lastVideoRecoveryRequestAtMs: UInt64 = 0
    private let videoAssemblyTimeoutMs: UInt64 = 1200
    private let minVideoRecoveryIntervalMs: UInt64 = 1500
    private let maxVideoAssemblyBytes = 6 * 1024 * 1024
    private var consecutiveTlsDecryptFailures = 0
    private var consecutiveTlsEncryptFailures = 0
    private let maxConsecutiveTlsFailures = 6
    private var startedSensors: Set<UInt64> = []
    private struct AapTraceEntry {
        let timestampMs: UInt64
        let direction: String
        let channel: UInt8
        let flags: UInt8
        let type: UInt16
        let payloadSize: Int
    }
    private var lastAapTrace: [AapTraceEntry] = []
    private let maxAapTraceEntries = 40
    private let aapTraceLock = NSLock()
    private var lastVideoPacketRxAtMs: UInt64 = 0

    private var receiveBuffer = Data()
    private var encryptedReceiveBuffer = Data()
    private let bufferLock = NSLock()

    init(tcpHandler: TcpHandler) {
        self.tcpHandler = tcpHandler
        self.tcpHandler.delegate = self
        setupTls()
    }

    func configurePeer(host: String, port: UInt16) {
        peerHost = host
        peerPort = port
    }

    private func setupTls() {
        if tlsHandler.setup() {
            print("AapTransport: OpenSSL TLS handler initialized")

            let bundle = Bundle.main
            let candidateCertPaths = [
                bundle.path(forResource: "cert", ofType: nil, inDirectory: "HeadunitPad/Resources/Raw"),
                bundle.path(forResource: "cert", ofType: nil, inDirectory: "Resources/Raw"),
                bundle.path(forResource: "cert", ofType: nil, inDirectory: "Raw"),
                bundle.path(forResource: "cert", ofType: nil)
            ]

            let candidateKeyPaths = [
                bundle.path(forResource: "privkey", ofType: nil, inDirectory: "HeadunitPad/Resources/Raw"),
                bundle.path(forResource: "privkey", ofType: nil, inDirectory: "Resources/Raw"),
                bundle.path(forResource: "privkey", ofType: nil, inDirectory: "Raw"),
                bundle.path(forResource: "privkey", ofType: nil)
            ]

            let certPath = candidateCertPaths.compactMap { $0 }.first
            let keyPath = candidateKeyPaths.compactMap { $0 }.first

            guard let certPath, let keyPath else {
                print("AapTransport: Certificate resources not found in app bundle")
                return
            }

            print("AapTransport: Using cert path: \(certPath)")
            print("AapTransport: Using key path: \(keyPath)")

            if tlsHandler.loadCertificate(certPath: certPath, keyPath: keyPath) {
                tlsIdentityReady = tlsHandler.hasClientIdentity()
                print("AapTransport: Certificate loaded successfully, ready=\(tlsIdentityReady)")
            } else {
                tlsIdentityReady = false
                print("AapTransport: Failed to load certificate")
            }
        }
    }

    func startHandshake() {
        print("AapTransport: Starting handshake")
        bufferLock.lock()
        receiveBuffer.removeAll()
        encryptedReceiveBuffer.removeAll()
        bufferLock.unlock()
        tlsHandler.releaseSessionOnly()
        versionRetryWorkItem?.cancel()
        versionRetryWorkItem = nil
        delayedVersionStartWorkItem?.cancel()
        delayedVersionStartWorkItem = nil
        versionRequestAttempts = 0
        hasTriggeredLauncherPoke = false
        setState(.waitingForVersion)

        let delayedStart = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.sendVersionRequestWithRetry()
        }
        delayedVersionStartWorkItem = delayedStart
        handshakeQueue.asyncAfter(deadline: .now() + initialVersionRequestDelay, execute: delayedStart)

        startHandshakeTimeout(for: .waitingForVersion)
    }

    private func startHandshakeTimeout(for handshakeState: AapTransportState) {
        handshakeTimer?.cancel()

        let timeout: TimeInterval
        switch handshakeState {
        case .waitingForVersion:
            timeout = versionHandshakeTimeout
        case .tlsHandshaking:
            timeout = tlsHandshakeTimeout
        default:
            return
        }

        let timer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if case .waitingForVersion = handshakeState, case .waitingForVersion = self.state {
                print("AapTransport: Handshake timeout - no version response received")
                self.setState(.error("Handshake timeout - no response from Headunit Server"))
                self.delegate?.aapTransportDidDisconnect(self)
            }
            if case .tlsHandshaking = handshakeState, case .tlsHandshaking = self.state {
                print("AapTransport: TLS handshake timeout")
                self.setState(.error("TLS handshake timeout"))
                self.delegate?.aapTransportDidDisconnect(self)
            }
        }
        handshakeTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    private func setState(_ newState: AapTransportState) {
        print("AapTransport: State changed from \(state) to \(newState)")
        state = newState

        if newState != .waitingForVersion && newState != .tlsHandshaking {
            handshakeTimer?.cancel()
            handshakeTimer = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.aapTransport(self, didChangeState: newState)
        }
    }

    private func sendVersionRequest() {
        let versionRequest = Data([0x00, 0x02, 0x00, 0x00])
        let message = AapMessage(
            channel: Channel.ID_CTR,
            flags: 0x03,
            type: AapMessageType.VERSION_REQUEST.rawValue,
            payload: versionRequest
        )

        let encoded = message.toData()
        let hex = encoded.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("AapTransport: Sending version request bytes=\(hex)")
        sendRaw(encoded)
    }

    private func sendVersionRequestWithRetry() {
        guard state == .waitingForVersion else {
            return
        }

        versionRequestAttempts += 1

        if versionRequestAttempts == 2 {
            triggerLauncherPokeIfNeeded()
        }

        print("AapTransport: VERSION_REQUEST attempt \(versionRequestAttempts)/\(maxVersionRequestAttempts)")
        sendVersionRequest()

        guard versionRequestAttempts < maxVersionRequestAttempts else {
            return
        }

        let retryWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.sendVersionRequestWithRetry()
        }
        versionRetryWorkItem?.cancel()
        versionRetryWorkItem = retryWork
        handshakeQueue.asyncAfter(deadline: .now() + versionRetryInterval, execute: retryWork)
    }

    private func triggerLauncherPokeIfNeeded() {
        guard enableLauncherPokeFallback else {
            return
        }
        guard !hasTriggeredLauncherPoke else {
            return
        }
        guard let host = peerHost, peerPort == 5277 else {
            return
        }

        hasTriggeredLauncherPoke = true
        print("AapTransport: No version response yet; poking Wifi Launcher at \(host):5289")

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 5289)!)
        let params = NWParameters.tcp
        params.prohibitExpensivePaths = true

        let pokeConnection = NWConnection(to: endpoint, using: params)
        let pokeQueue = DispatchQueue(label: "com.headunitpad.aap.launcher-poke", qos: .utility)
        let timeoutWorkItem = DispatchWorkItem {
            pokeConnection.cancel()
            print("AapTransport: Wifi Launcher poke timeout")
        }

        pokeConnection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("AapTransport: Wifi Launcher poke connected")
                pokeQueue.asyncAfter(deadline: .now() + 0.25) {
                    pokeConnection.cancel()
                }
            case .failed(let error):
                print("AapTransport: Wifi Launcher poke failed: \(error)")
                timeoutWorkItem.cancel()
            case .cancelled:
                timeoutWorkItem.cancel()
            default:
                break
            }
        }

        pokeConnection.start(queue: pokeQueue)
        pokeQueue.asyncAfter(deadline: .now() + 1.0, execute: timeoutWorkItem)
    }

    private func sendStatusOk() {
        let statusData = Data([0x08, 0x00])
        let message = AapMessage(
            channel: Channel.ID_CTR,
            flags: 0x03,
            type: AapMessageType.AUTH_COMPLETE.rawValue,
            payload: statusData
        )

        print("AapTransport: Sending status OK (plaintext)")
        sendRaw(message.toData())
    }

    func send(message: AapMessage) {
        recordAapTrace(direction: "TX", channel: message.channel, flags: message.flags, type: message.type, payloadSize: message.payload.count)

        if state == .authenticating || state == .authenticatingComplete || state == .binding || state == .running {
            processingQueue.async { [weak self] in
                self?.sendEncryptedMessage(message)
            }
        } else {
            let data = message.toData()
            tcpHandler.send(data)
        }
    }

    private func sendEncryptedMessage(_ message: AapMessage) {
        var plain = Data()
        plain.append(UInt8((message.type >> 8) & 0xFF))
        plain.append(UInt8(message.type & 0xFF))
        plain.append(message.payload)

        guard let encryptedPayload = tlsHandler.encrypt(data: plain) else {
            print("AapTransport: Failed to encrypt message type=\(message.type)")
            registerTlsEncryptFailure(context: "message-type-\(message.type)")
            return
        }
        consecutiveTlsEncryptFailures = 0

        let flags = encryptedFlags(for: message)
        var packet = Data()
        packet.append(message.channel)
        packet.append(flags)

        let encLen = UInt16(encryptedPayload.count)
        packet.append(UInt8((encLen >> 8) & 0xFF))
        packet.append(UInt8(encLen & 0xFF))
        packet.append(encryptedPayload)

        tcpHandler.send(packet)
    }

    private func encryptedFlags(for message: AapMessage) -> UInt8 {
        if message.channel != Channel.ID_CTR && isControlMessageType(message.type) {
            return 0x0f
        }
        return 0x0b
    }

    private func isControlMessageType(_ type: UInt16) -> Bool {
        return type >= 1 && type <= 26
    }

    func sendRaw(_ data: Data) {
        tcpHandler.send(data)
    }

    func requestVideoRecovery() {
        requestVideoRecoveryIfNeeded(reason: "external-watchdog", ignoreRecentVideoGuard: false)
    }

    func requestVideoRecoveryForNewDisplay() {
        requestVideoRecoveryIfNeeded(reason: "new-display", ignoreRecentVideoGuard: true)
    }

    func sendTouchEvent(x: Int, y: Int, action: TouchAction, pointerId: Int = 0) {
        sendTouchEvent(
            pointers: [(id: pointerId, x: x, y: y)],
            action: action,
            actionIndex: 0
        )
    }

    func sendTouchEvent(pointers: [(id: Int, x: Int, y: Int)], action: TouchAction, actionIndex: Int) {
        guard !pointers.isEmpty else { return }

        // Input.TouchEvent.Pointer { x=1, y=2, pointer_id=3 }
        var pointerData = Data()
        for pointer in pointers {
            let encodedPointer = ProtoWire.fieldVarint(1, value: UInt64(max(pointer.x, 0)))
                + ProtoWire.fieldVarint(2, value: UInt64(max(pointer.y, 0)))
                + ProtoWire.fieldVarint(3, value: UInt64(max(pointer.id, 0)))
            pointerData += ProtoWire.fieldBytes(1, value: encodedPointer)
        }

        // Input.TouchEvent { pointer_data=1, action_index=2, action=3 }
        let touchEvent = pointerData
            + ProtoWire.fieldVarint(2, value: UInt64(max(actionIndex, 0)))
            + ProtoWire.fieldVarint(3, value: UInt64(action.rawValue))

        // Input.InputReport { timestamp=1, touch_event=3 }
        let timestampNs = DispatchTime.now().uptimeNanoseconds
        let payload = ProtoWire.fieldVarint(1, value: timestampNs)
            + ProtoWire.fieldBytes(3, value: touchEvent)

        let message = AapMessage(
            channel: Channel.ID_INP,
            flags: 0x00,
            type: 0x8001, // Input.MsgType.EVENT
            payload: payload
        )

        print("AapTransport: Send touch action=\(action) pointers=\(pointers.count) actionIndex=\(actionIndex)")

        send(message: message)
    }

    func sendMicrophoneAudioData(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        guard state == .running || state == .binding || state == .authenticatingComplete else { return }

        var streamPayload = Data()
        appendBigEndianTimestampMs(to: &streamPayload)
        streamPayload.append(pcmData)

        sendEncryptedRawStream(channel: Channel.ID_MIC, flags: 0x0b, payload: streamPayload)
    }

    func sendLocationUpdate(_ location: CLLocation) {
        guard state == .running else { return }
        guard ProjectionSettings.gpsSource == .ipad else { return }
        guard startedSensors.contains(1) else { return } // Sensors.SensorType.LOCATION

        let timestampMs = UInt64(max(0, Int64(location.timestamp.timeIntervalSince1970 * 1000)))
        let latitude = Int64((location.coordinate.latitude * 1e7).rounded())
        let longitude = Int64((location.coordinate.longitude * 1e7).rounded())
        let altitude = Int64((location.altitude * 1e2).rounded())
        let speed = Int64((max(location.speed, 0) * 1e3).rounded())
        let bearing = Int64((location.course >= 0 ? location.course : 0) * 1e6)
        let accuracy = UInt64(max(0, Int64((location.horizontalAccuracy * 1e3).rounded())))

        let locationData = ProtoWire.fieldVarint(1, value: timestampMs)
            + ProtoWire.fieldVarint(2, value: UInt64(max(latitude, 0)))
            + ProtoWire.fieldVarint(3, value: UInt64(max(longitude, 0)))
            + ProtoWire.fieldVarint(4, value: accuracy)
            + ProtoWire.fieldVarint(5, value: UInt64(max(altitude, 0)))
            + ProtoWire.fieldVarint(6, value: UInt64(max(speed, 0)))
            + ProtoWire.fieldVarint(7, value: UInt64(max(bearing, 0)))

        let sensorBatch = ProtoWire.fieldBytes(1, value: locationData)
        let message = AapMessage(
            channel: Channel.ID_SEN,
            flags: AapFlags.NORMAL_MESSAGE,
            type: 0x8003,
            payload: sensorBatch
        )
        send(message: message)
    }

    private func appendBigEndianTimestampMs(to data: inout Data) {
        var value = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in (0..<8).reversed() {
            bytes[i] = UInt8(value & 0xFF)
            value >>= 8
        }
        data.append(contentsOf: bytes)
    }

    private func sendEncryptedRawStream(channel: UInt8, flags: UInt8, payload: Data) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.recordAapTrace(direction: "TX", channel: channel, flags: flags, type: 0, payloadSize: payload.count)

            guard let encryptedPayload = self.tlsHandler.encrypt(data: payload) else {
                print("AapTransport: Failed to encrypt raw stream for channel \(Channel.name(for: channel))")
                self.registerTlsEncryptFailure(context: "raw-stream-\(Channel.name(for: channel))")
                return
            }
            self.consecutiveTlsEncryptFailures = 0

            var packet = Data()
            packet.append(channel)
            packet.append(flags)

            let encLen = UInt16(encryptedPayload.count)
            packet.append(UInt8((encLen >> 8) & 0xFF))
            packet.append(UInt8(encLen & 0xFF))
            packet.append(encryptedPayload)

            self.tcpHandler.send(packet)
        }
    }

    private func handleReceivedData(_ data: Data) {
        if state == .authenticating || state == .authenticatingComplete || state == .binding || state == .running {
            appendAndProcessEncryptedBuffer(data)
        } else {
            if state == .waitingForVersion {
                let preview = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("AapTransport: waitingForVersion recv \(data.count) bytes, preview=\(preview)")
            }
            appendAndProcessBuffer(data)
        }
    }

    private func appendAndProcessEncryptedBuffer(_ data: Data) {
        bufferLock.lock()
        encryptedReceiveBuffer.append(data)
        bufferLock.unlock()
        processEncryptedBuffer()
    }

    private func processEncryptedBuffer() {
        while true {
            var channel: UInt8 = 0
            var flags: UInt8 = 0
            var encryptedPayload = Data()

            bufferLock.lock()
            if encryptedReceiveBuffer.count < 4 {
                bufferLock.unlock()
                return
            }

            channel = encryptedReceiveBuffer[0]
            flags = encryptedReceiveBuffer[1]
            let encLen = Int(UInt16(encryptedReceiveBuffer[2]) << 8 | UInt16(encryptedReceiveBuffer[3]))

            if encLen <= 0 || encLen > AapMessage.DEF_BUFFER_LENGTH {
                let dropped = encryptedReceiveBuffer.removeFirst()
                bufferLock.unlock()
                print("AapTransport: Resync encrypted parser, dropped byte 0x\(String(format: "%02x", dropped))")
                continue
            }

            // Streaming packets (notably video) may carry a 4-byte counter when flags == 0x09.
            let headerExtra = (flags == 0x09) ? 4 : 0
            let packetSize = 4 + headerExtra + encLen
            if encryptedReceiveBuffer.count < packetSize {
                bufferLock.unlock()
                return
            }

            let payloadStart = 4 + headerExtra
            let payloadEnd = payloadStart + encLen
            encryptedPayload = encryptedReceiveBuffer.subdata(in: payloadStart..<payloadEnd)
            encryptedReceiveBuffer.removeSubrange(0..<packetSize)
            bufferLock.unlock()

            if (flags & 0x08) != 0x08 {
                print("AapTransport: Invalid encrypted flags=0x\(String(format: "%02x", flags))")
                continue
            }

            guard let decrypted = tlsHandler.decrypt(data: encryptedPayload) else {
                print("AapTransport: Decrypt returned nil for encrypted payload len=\(encryptedPayload.count)")
                registerTlsDecryptFailure(context: "payload-len-\(encryptedPayload.count)")
                continue
            }
            consecutiveTlsDecryptFailures = 0

            if decrypted.count < 2 {
                print("AapTransport: Decrypted payload too short: \(decrypted.count)")
                continue
            }

            let msgType = UInt16(decrypted[0]) << 8 | UInt16(decrypted[1])
            let payload = decrypted.subdata(in: 2..<decrypted.count)

            // Streaming packets on media channels may be continuation chunks without
            // a message type prefix. Treat them as raw stream data unless the packet
            // looks like a small control/media command frame.
            if isMediaChannel(channel)
                && isMediaStreamFlags(flags)
                && !shouldTreatAsMediaControl(flags: flags, type: msgType, payloadSize: payload.count) {
                let fallback = AapMessage(channel: channel, flags: flags, type: 0, payload: decrypted)
                handleMessage(fallback)
                continue
            }

            let message = AapMessage(channel: channel, flags: flags, type: msgType, payload: payload)
            handleMessage(message)
        }
    }

    private func registerTlsDecryptFailure(context: String) {
        consecutiveTlsDecryptFailures += 1
        if consecutiveTlsDecryptFailures >= maxConsecutiveTlsFailures {
            failTransportForTlsErrors(reason: "decrypt-failure-\(context)")
        }
    }

    private func registerTlsEncryptFailure(context: String) {
        consecutiveTlsEncryptFailures += 1
        if consecutiveTlsEncryptFailures >= maxConsecutiveTlsFailures {
            failTransportForTlsErrors(reason: "encrypt-failure-\(context)")
        }
    }

    private func failTransportForTlsErrors(reason: String) {
        if case .error = state {
            return
        }

        print("AapTransport: Too many TLS failures, forcing disconnect, reason=\(reason)")
        dumpRecentAapTrace(reason: reason)
        setState(.error("TLS stream failure (\(reason))"))
        tcpHandler.disconnect()
        delegate?.aapTransportDidDisconnect(self)
    }

    private func isMediaChannel(_ channel: UInt8) -> Bool {
        return channel == Channel.ID_VID || Channel.isAudio(channel)
    }

    private func isMediaStreamFlags(_ flags: UInt8) -> Bool {
        // Stream payload fragment flags; excludes control-style 0x0f.
        return flags == 0x08 || flags == 0x09 || flags == 0x0a || flags == 0x0b
    }

    private func isKnownMediaMsgType(_ type: UInt16) -> Bool {
        switch type {
        case 0, 1, 0x8000, 0x8001, 0x8002, 0x8003, 0x8004, 0x8005, 0x8006, 0x8007, 0x8008, 0x8009, 0x800A, 0x800B:
            return true
        default:
            return false
        }
    }

    private func shouldTreatAsMediaControl(flags: UInt8, type: UInt16, payloadSize: Int) -> Bool {
        guard isKnownMediaMsgType(type) else {
            return false
        }

        // Fragmented flags (first/middle/last) are stream data in practice.
        // Avoid accidentally parsing large NAL fragments as MEDIA_SETUP/START.
        if flags == 0x08 || flags == 0x09 || flags == 0x0a {
            return false
        }

        // Keep only small packets as control/media command candidates.
        return payloadSize <= 512
    }

    private func appendAndProcessBuffer(_ data: Data) {
        bufferLock.lock()
        receiveBuffer.append(data)
        bufferLock.unlock()
        processBuffer()
    }

    private func processBuffer() {
        while true {
            var messageData: Data?

            bufferLock.lock()
            if receiveBuffer.count >= AapMessage.FRAME_HEADER_SIZE {
                let channel = receiveBuffer[0]
                let length = UInt16(receiveBuffer[2]) << 8 | UInt16(receiveBuffer[3])
                let totalMessageSize = Int(length) + 4

                let invalidChannel = channel > Channel.ID_WIFI
                let invalidLength = length < 2 || totalMessageSize > AapMessage.DEF_BUFFER_LENGTH

                if invalidChannel || invalidLength {
                    let dropped = receiveBuffer.removeFirst()
                    print("AapTransport: Resync frame parser, dropped byte 0x\(String(format: "%02x", dropped))")
                    bufferLock.unlock()
                    continue
                }

                if receiveBuffer.count >= totalMessageSize {
                    messageData = receiveBuffer.subdata(in: 0..<totalMessageSize)
                    receiveBuffer.removeSubrange(0..<totalMessageSize)
                }
            }
            bufferLock.unlock()

            guard let frame = messageData else {
                return
            }

            if let message = AapMessage(data: frame) {
                handleMessage(message)
            }
        }
    }

    private func beginTlsHandshake() {
        guard tlsIdentityReady else {
            setState(.error("TLS identity not loaded (cert/key missing in bundle)"))
            delegate?.aapTransportDidDisconnect(self)
            return
        }

        do {
            let step = try tlsHandler.startHandshakeSession()
            processTlsHandshakeStep(step)
            startHandshakeTimeout(for: .tlsHandshaking)
        } catch {
            print("AapTransport: Failed to start TLS handshake: \(error)")
            setState(.error("TLS handshake failed: \(error.localizedDescription)"))
            delegate?.aapTransportDidDisconnect(self)
        }
    }

    private func continueTlsHandshake(with payload: Data) {
        do {
            let step = try tlsHandler.continueHandshake(with: payload)
            processTlsHandshakeStep(step)
        } catch {
            print("AapTransport: TLS handshake step failed: \(error)")
            setState(.error("TLS handshake failed: \(error.localizedDescription)"))
            delegate?.aapTransportDidDisconnect(self)
        }
    }

    private func processTlsHandshakeStep(_ step: OpenSslHandshakeStep) {
        if !step.outgoingData.isEmpty {
            let tlsPreview = step.outgoingData.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            let message = AapMessage(
                channel: Channel.ID_CTR,
                flags: 0x03,
                type: AapMessageType.MESSAGE_ENCAPSULATED_SSL.rawValue,
                payload: step.outgoingData
            )
            sendRaw(message.toData())
            print("AapTransport: Sent encapsulated SSL payload: \(step.outgoingData.count) bytes, tlsPreview=\(tlsPreview)")
        }

        if step.isComplete {
            print("AapTransport: TLS handshake completed")
            tlsHandler.postHandshakeReset()
            setState(.authenticating)
            sendStatusOk()
        }
    }

    private func handleMessage(_ message: AapMessage) {
        recordAapTrace(direction: "RX", channel: message.channel, flags: message.flags, type: message.type, payloadSize: message.payload.count)

        if message.channel != Channel.ID_VID && !Channel.isAudio(message.channel) && message.channel != Channel.ID_MIC {
            print("AapTransport: Received message on channel \(Channel.name(for: message.channel)), type=\(message.type), size=\(message.payload.count)")
        }

        // Android Auto may carry control message types on non-control channels with flag 0x0f.
        // Do not treat normal media payload types (e.g. 0/1) as control just because type value is small.
        if message.channel != Channel.ID_CTR && message.flags == 0x0f && isControlMessageType(message.type) {
            handleControlMessage(message)
            return
        }

        switch message.channel {
        case Channel.ID_CTR:
            handleControlMessage(message)

        case Channel.ID_SEN:
            handleSensorMessage(message)

        case Channel.ID_INP:
            handleInputMessage(message)

        case Channel.ID_VID:
            handleVideoMessage(message)

        case Channel.ID_AUD, Channel.ID_AU1, Channel.ID_AU2:
            handleAudioMessage(message)

        case Channel.ID_MIC:
            handleMicrophoneMessage(message)

        case Channel.ID_MPB:
            handleMediaPlaybackMessage(message)

        case Channel.ID_NAV:
            handleNavigationMessage(message)

        default:
            print("AapTransport: Unhandled channel \(message.channel)")
        }
    }

    private func handleMediaPlaybackMessage(_ message: AapMessage) {
        // Media playback channel is optional for HeadunitPad runtime.
        // Consume packets explicitly to avoid protocol-side "unhandled channel" behavior.
        switch message.type {
        case 0x8001: // MediaPlaybackStatus
            break
        case 0x8002: // MediaPlaybackInput
            break
        case 0x8003: // MediaPlaybackMetadata
            break
        default:
            break
        }
    }

    private func handleNavigationMessage(_ message: AapMessage) {
        switch message.type {
        case 0x8004: // NavigationStatus.MsgType.NEXTTURNDETAILS
            let road = ProtoWire.extractFirstString(from: message.payload, fieldNumber: 1) ?? ""
            let side = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 2) ?? 0
            let nextTurn = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 3) ?? 0
            let turnNumber = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 5)
            let turnAngle = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 6)

            let sideName = navSideName(side)
            let eventName = navEventName(nextTurn)
            print("AapTransport: NAV detail road='\(road)' side=\(sideName)(\(side)) next=\(eventName)(\(nextTurn)) turnNo=\(turnNumber.map(String.init) ?? "-") angle=\(turnAngle.map(String.init) ?? "-")")

        case 0x8005: // NavigationStatus.MsgType.NEXTTURNDISTANCEANDTIME
            let distance = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 1)
            let time = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 2)
            print("AapTransport: NAV distance/time distanceM=\(distance.map(String.init) ?? "-") etaSec=\(time.map(String.init) ?? "-")")

        default:
            let road = ProtoWire.extractFirstString(from: message.payload, fieldNumber: 1)
            let f1 = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 1)
            let f2 = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 2)
            let f3 = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 3)
            print("AapTransport: NAV unknown type=\(message.type) size=\(message.payload.count) road='\(road ?? "")' f1=\(f1.map(String.init) ?? "-") f2=\(f2.map(String.init) ?? "-") f3=\(f3.map(String.init) ?? "-")")
        }
    }

    private func navSideName(_ value: UInt64) -> String {
        switch value {
        case 1: return "LEFT"
        case 2: return "RIGHT"
        case 3: return "UNSPECIFIED"
        default: return "UNKNOWN"
        }
    }

    private func navEventName(_ value: UInt64) -> String {
        switch value {
        case 0: return "UNKNOWN"
        case 1: return "DEPART"
        case 2: return "NAME_CHANGE"
        case 3: return "SLIGHT_TURN"
        case 4: return "TURN"
        case 5: return "SHARP_TURN"
        case 6: return "UTURN"
        case 7: return "ON_RAMP"
        case 8: return "OFF_RAMP"
        case 9: return "FORK"
        case 10: return "MERGE"
        case 11: return "ROUNDABOUT_ENTER"
        case 12: return "ROUNDABOUT_EXIT"
        case 13: return "ROUNDABOUT_ENTER_EXIT"
        case 14: return "STRAIGHT"
        case 16: return "FERRY_BOAT"
        case 17: return "FERRY_TRAIN"
        case 18: return "DESTINATION"
        default: return "UNKNOWN"
        }
    }

    private func handleControlMessage(_ message: AapMessage) {
        switch message.type {
        case AapMessageType.VERSION_RESPONSE.rawValue:
            print("AapTransport: Version response received")
            delayedVersionStartWorkItem?.cancel()
            delayedVersionStartWorkItem = nil
            versionRetryWorkItem?.cancel()
            versionRetryWorkItem = nil
            setState(.versionSent)
            setState(.tlsHandshaking)
            beginTlsHandshake()

        case AapMessageType.MESSAGE_ENCAPSULATED_SSL.rawValue:
            if state == .tlsHandshaking {
                continueTlsHandshake(with: message.payload)
            }

        case AapMessageType.AUTH_COMPLETE.rawValue:
            print("AapTransport: Auth complete received")
            if state == .authenticating {
                setState(.authenticatingComplete)
                setState(.binding)
            }

        case AapMessageType.SERVICE_DISCOVERY_REQUEST.rawValue:
            print("AapTransport: Service discovery request received")
            sendServiceDiscoveryResponse()

        case AapMessageType.CHANNEL_OPEN_REQUEST.rawValue:
            print("AapTransport: Channel open request received")
            sendChannelOpenResponse(on: message.channel)
            if state == .authenticating {
                setState(.authenticatingComplete)
                setState(.binding)
            }
            if state == .binding || state == .authenticatingComplete {
                setState(.running)
            }

        case AapMessageType.AUDIO_FOCUS_REQUEST.rawValue:
            sendAudioFocusNotification(for: message, on: message.channel)

        case AapMessageType.AUDIO_FOCUS_RESPONSE.rawValue:
            // Host acknowledgement for previously sent focus notification.
            break

        case AapMessageType.CAR_CONNECTED_DEVICES_REQUEST.rawValue:
            print("AapTransport: Car connected devices request received")
            sendCarConnectedDevicesResponse(on: message.channel, unsolicited: false)

        case AapMessageType.USER_SWITCH_REQUEST.rawValue:
            print("AapTransport: User switch request received")
            sendUserSwitchResponse(on: message.channel)

        case AapMessageType.PING_REQUEST.rawValue:
            sendPingResponse(for: message, on: message.channel)

        case AapMessageType.NAV_FOCUS_REQUEST.rawValue:
            sendNavFocusNotification(on: message.channel)

        case AapMessageType.BYEBYE_REQUEST.rawValue:
            sendByebyeResponse(on: message.channel)

        case AapMessageType.CHANNEL_OPEN_RESPONSE.rawValue:
            print("AapTransport: Channel open response received")
            setState(.running)

        default:
            print("AapTransport: Unknown control message type: \(message.type)")
        }
    }

    private func handleSensorMessage(_ message: AapMessage) {
        // Sensors.SensorsMsgType.SENSOR_STARTREQUEST = 0x8001
        if message.type == 0x8001 {
            if let sensorType = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 1) {
                if sensorType == 10 {
                    // Compatibility mode: do not enable NIGHT sensor on iPad host.
                    // Some third-party navigation apps become unstable when map color
                    // mode is driven by host-side night sensor updates.
                    print("AapTransport: Ignoring NIGHT sensor start request for compatibility")
                } else {
                    startedSensors.insert(sensorType)
                }

                if sensorType == 1 {
                    let shouldUseIpadGps = ProjectionSettings.gpsSource == .ipad
                    delegate?.aapTransport(self, didRequestLocationUpdates: shouldUseIpadGps)
                }
            }
            sendSensorStartResponse(on: message.channel)
            return
        }

        print("AapTransport: Unhandled sensor message type=\(message.type)")
    }

    private func handleInputMessage(_ message: AapMessage) {
        // Input.MsgType.BINDINGREQUEST = 0x8002
        if message.type == 0x8002 {
            sendInputBindingResponse(on: message.channel)
            return
        }

        print("AapTransport: Unhandled input message type=\(message.type)")
    }


    private func sendServiceDiscoveryResponse() {
        let payload = buildMinimalServiceDiscoveryResponsePayload()
        let message = AapMessage(
            channel: Channel.ID_CTR,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.SERVICE_DISCOVERY_RESPONSE.rawValue,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent service discovery response (\(payload.count) bytes)")
    }

    private func sendChannelOpenResponse(on channel: UInt8) {
        let payload = Data([0x08, 0x00]) // status = STATUS_SUCCESS
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.CHANNEL_OPEN_RESPONSE.rawValue,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent channel open response on channel \(Channel.name(for: channel))")

        if channel == Channel.ID_SEN {
            sendDrivingStatusUnrestricted(on: channel)
        }
    }

    private func sendAudioFocusNotification(for request: AapMessage, on channel: UInt8) {
        // Control.AudioFocusRequestType: 1=GAIN,2=GAIN_TRANSIENT,3=GAIN_TRANSIENT_MAY_DUCK,4=RELEASE
        let requestType = ProtoWire.extractFirstVarint(from: request.payload, fieldNumber: 1) ?? 1
        let focusState: UInt64
        switch requestType {
        case 4:
            focusState = 3 // STATE_LOSS
        case 2:
            focusState = 2 // STATE_GAIN_TRANSIENT
        case 3:
            focusState = 7 // STATE_GAIN_TRANSIENT_GUIDANCE_ONLY
        default:
            focusState = 1 // STATE_GAIN
        }

        let payload = ProtoWire.fieldVarint(1, value: focusState)
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.AUDIO_FOCUS_NOTIFICATION.rawValue,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Audio focus requestType=\(requestType) -> focusState=\(focusState)")
    }

    private func sendSensorStartResponse(on channel: UInt8) {
        // Sensors.SensorResponse { status = STATUS_SUCCESS }
        let payload = Data([0x08, 0x00])
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: 0x8002,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent sensor start response")
    }

    private func sendInputBindingResponse(on channel: UInt8) {
        // Input.BindingResponse { status = STATUS_SUCCESS }
        let payload = Data([0x08, 0x00])
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: 0x8003,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent input binding response")
    }

    private func sendDrivingStatusUnrestricted(on channel: UInt8) {
        // Sensors.SensorBatch { driving_status { status = UNRESTRICTED(0) } }
        let drivingStatusData = ProtoWire.fieldVarint(1, value: 0)
        let sensorBatch = ProtoWire.fieldBytes(13, value: drivingStatusData)
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.NORMAL_MESSAGE,
            type: 0x8003,
            payload: sensorBatch
        )
        send(message: message)
        print("AapTransport: Sent driving status unrestricted")
    }

    private func sendVideoFocusNotification(on channel: UInt8, reason: String) {
        // Media.VideoFocusNotification { mode = VIDEO_FOCUS_PROJECTED(1), unsolicited = true }
        let payload = ProtoWire.fieldVarint(1, value: 1)
            + ProtoWire.fieldVarint(2, value: 1)
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: 0x8008,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent video focus notification reason=\(reason)")
    }

    private func sendCallAvailabilityStatus(on channel: UInt8) {
        // Control.CallAvailabilityStatus { call_available = true }
        let payload = ProtoWire.fieldVarint(1, value: 1)
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: 24,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent call availability status")
    }

    private func sendCarConnectedDevicesResponse(on channel: UInt8, unsolicited: Bool) {
        let device = buildConnectedDevice(name: "HeadunitPad", id: 1)
        var payload = Data()
        payload += ProtoWire.fieldBytes(1, value: device)
        payload += ProtoWire.fieldVarint(2, value: unsolicited ? 1 : 0)
        payload += ProtoWire.fieldVarint(3, value: 1) // final_list = true

        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.CAR_CONNECTED_DEVICES_RESPONSE.rawValue,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent car connected devices response (unsolicited=\(unsolicited))")
    }

    private func sendUserSwitchResponse(on channel: UInt8) {
        let selectedDevice = buildConnectedDevice(name: "HeadunitPad", id: 1)
        var payload = Data()
        payload += ProtoWire.fieldVarint(1, value: 0) // STATUS_OK
        payload += ProtoWire.fieldBytes(2, value: selectedDevice)

        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.USER_SWITCH_RESPONSE.rawValue,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent user switch response")
    }

    private func buildConnectedDevice(name: String, id: UInt64) -> Data {
        return ProtoWire.fieldString(1, value: name)
            + ProtoWire.fieldVarint(2, value: id)
    }

    private func sendPingResponse(for request: AapMessage, on channel: UInt8) {
        let timestamp = ProtoWire.extractFirstVarint(from: request.payload, fieldNumber: 1) ?? UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let payload = ProtoWire.fieldVarint(1, value: timestamp)
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.PING_RESPONSE.rawValue,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent ping response")
    }

    private func sendNavFocusNotification(on channel: UInt8) {
        let payload = ProtoWire.fieldVarint(1, value: 2) // NAV_FOCUS_2
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.NAV_FOCUS_NOTIFICATION.rawValue,
            payload: payload
        )
        send(message: message)
        print("AapTransport: Sent navigation focus notification")
    }

    private func sendByebyeResponse(on channel: UInt8) {
        let message = AapMessage(
            channel: channel,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.BYEBYE_RESPONSE.rawValue,
            payload: Data()
        )
        send(message: message)
        print("AapTransport: Sent byebye response")
    }

    private func buildMinimalServiceDiscoveryResponsePayload() -> Data {
        let sensorDrivingStatus = ProtoWire.fieldBytes(1, value: ProtoWire.fieldVarint(1, value: 13))
        let sensorLocation = ProtoWire.fieldBytes(1, value: ProtoWire.fieldVarint(1, value: 1))
        var sensorSource = sensorDrivingStatus
        if ProjectionSettings.gpsSource == .ipad {
            sensorSource += sensorLocation
        }
        let sensorService = ProtoWire.fieldVarint(1, value: UInt64(Channel.ID_SEN))
            + ProtoWire.fieldBytes(2, value: sensorSource)

        let videoConfig = ProtoWire.fieldVarint(1, value: UInt64(ProjectionSettings.effectiveVideoCodecResolutionValue))
            + ProtoWire.fieldVarint(2, value: UInt64(ProjectionSettings.effectiveFpsLimit.rawValue))
            + ProtoWire.fieldVarint(3, value: 0)
            + ProtoWire.fieldVarint(4, value: 0)
            + ProtoWire.fieldVarint(5, value: UInt64(ProjectionSettings.effectiveDpi))
            + ProtoWire.fieldVarint(10, value: 3)             // H264

        let videoSink = ProtoWire.fieldVarint(1, value: 3)    // MEDIA_CODEC_VIDEO_H264_BP
            + ProtoWire.fieldVarint(2, value: 0)              // AudioStreamType.NONE
            + ProtoWire.fieldBytes(4, value: videoConfig)
            + ProtoWire.fieldVarint(5, value: 1)

        let videoService = ProtoWire.fieldVarint(1, value: UInt64(Channel.ID_VID))
            + ProtoWire.fieldBytes(3, value: videoSink)

        let touchConfig = ProtoWire.fieldVarint(1, value: UInt64(ProjectionSettings.effectiveVideoDimensions.width))
            + ProtoWire.fieldVarint(2, value: UInt64(ProjectionSettings.effectiveVideoDimensions.height))
        // Mirrors Android KeyCode.supported (distinct().sorted())
        let keycodes: [UInt64] = [
            1, 2, 3, 4, 5, 6,
            7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
            19, 20, 21, 22, 23,
            24, 25,
            61, 62, 66,
            79, 81, 84,
            85, 86, 87, 88,
            126, 127,
            209,
            224,
            264, 265, 267,
            268, 269, 270, 271,
            65536, 65537, 65538
        ]
        var inputSource = ProtoWire.fieldBytes(2, value: touchConfig)
        for keycode in keycodes {
            inputSource += ProtoWire.fieldVarint(1, value: keycode)
        }
        let inputService = ProtoWire.fieldVarint(1, value: UInt64(Channel.ID_INP))
            + ProtoWire.fieldBytes(4, value: inputSource)

        let pcmAudioConfig48kStereo = ProtoWire.fieldVarint(1, value: 48_000)
            + ProtoWire.fieldVarint(2, value: 16)
            + ProtoWire.fieldVarint(3, value: 2)

        let pcmAudioConfig16kMono = ProtoWire.fieldVarint(1, value: 16_000)
            + ProtoWire.fieldVarint(2, value: 16)
            + ProtoWire.fieldVarint(3, value: 1)

        let audioSinkSystem = ProtoWire.fieldVarint(1, value: 1)    // MEDIA_CODEC_AUDIO_PCM
            + ProtoWire.fieldVarint(2, value: 2)              // SYSTEM
            + ProtoWire.fieldBytes(3, value: pcmAudioConfig16kMono)
        let audioServiceSystem = ProtoWire.fieldVarint(1, value: UInt64(Channel.ID_AU2))
            + ProtoWire.fieldBytes(3, value: audioSinkSystem)

        let audioSinkMedia = ProtoWire.fieldVarint(1, value: 1)
            + ProtoWire.fieldVarint(2, value: 3)              // MEDIA
            + ProtoWire.fieldBytes(3, value: pcmAudioConfig48kStereo)
        let audioServiceMedia = ProtoWire.fieldVarint(1, value: UInt64(Channel.ID_AUD))
            + ProtoWire.fieldBytes(3, value: audioSinkMedia)

        let audioSinkSpeech = ProtoWire.fieldVarint(1, value: 1)
            + ProtoWire.fieldVarint(2, value: 1)              // SPEECH
            + ProtoWire.fieldBytes(3, value: pcmAudioConfig16kMono)
        let audioServiceSpeech = ProtoWire.fieldVarint(1, value: UInt64(Channel.ID_AU1))
            + ProtoWire.fieldBytes(3, value: audioSinkSpeech)

        let micSource = ProtoWire.fieldVarint(1, value: 1)
            + ProtoWire.fieldBytes(2, value:
                ProtoWire.fieldVarint(1, value: 16_000)
                + ProtoWire.fieldVarint(2, value: 16)
                + ProtoWire.fieldVarint(3, value: 1)
            )
        let micService = ProtoWire.fieldVarint(1, value: UInt64(Channel.ID_MIC))
            + ProtoWire.fieldBytes(5, value: micSource)

        let navService = ProtoWire.fieldVarint(1, value: UInt64(Channel.ID_NAV))
            + ProtoWire.fieldBytes(8, value:
                ProtoWire.fieldVarint(1, value: 1000) // minimum_interval_ms
                + ProtoWire.fieldVarint(2, value: 2)  // ImageCodesOnly
            )

        var payload = Data()
        payload += ProtoWire.fieldBytes(1, value: sensorService)
        payload += ProtoWire.fieldBytes(1, value: videoService)
        payload += ProtoWire.fieldBytes(1, value: inputService)
        payload += ProtoWire.fieldBytes(1, value: audioServiceSystem)
        payload += ProtoWire.fieldBytes(1, value: audioServiceMedia)
        payload += ProtoWire.fieldBytes(1, value: audioServiceSpeech)
        payload += ProtoWire.fieldBytes(1, value: micService)
        payload += ProtoWire.fieldBytes(1, value: navService)

        payload += ProtoWire.fieldString(2, value: "Google")
        payload += ProtoWire.fieldString(3, value: "Desktop Head Unit")
        payload += ProtoWire.fieldString(4, value: "2025")
        payload += ProtoWire.fieldString(5, value: "headlessunit-001")
        payload += ProtoWire.fieldVarint(6, value: 0) // DRIVER_POSITION_LEFT
        payload += ProtoWire.fieldString(7, value: "Google")
        payload += ProtoWire.fieldString(8, value: "Desktop Head Unit")
        payload += ProtoWire.fieldString(9, value: "1")
        payload += ProtoWire.fieldString(10, value: "0.1.0")
        payload += ProtoWire.fieldVarint(11, value: 0)
        payload += ProtoWire.fieldVarint(12, value: 0) // hide_projected_clock = false
        payload += ProtoWire.fieldString(14, value: "Headunit Revived")
        var headUnitInfo = Data()
        headUnitInfo += ProtoWire.fieldString(1, value: "Google")
        headUnitInfo += ProtoWire.fieldString(2, value: "Desktop Head Unit")
        headUnitInfo += ProtoWire.fieldString(3, value: "Google")
        headUnitInfo += ProtoWire.fieldString(4, value: "Desktop Head Unit")
        headUnitInfo += ProtoWire.fieldString(5, value: "2025")
        headUnitInfo += ProtoWire.fieldString(6, value: "1")
        headUnitInfo += ProtoWire.fieldString(7, value: "headlessunit-001")
        headUnitInfo += ProtoWire.fieldString(8, value: "0.1.0")
        payload += ProtoWire.fieldBytes(17, value: headUnitInfo)

        return payload
    }


private enum ProtoWire {
    static func fieldVarint(_ fieldNumber: Int, value: UInt64) -> Data {
        var data = Data()
        data.append(contentsOf: encodeVarint(UInt64(fieldNumber << 3)))
        data.append(contentsOf: encodeVarint(value))
        return data
    }

    static func fieldBytes(_ fieldNumber: Int, value: Data) -> Data {
        var data = Data()
        data.append(contentsOf: encodeVarint(UInt64((fieldNumber << 3) | 2)))
        data.append(contentsOf: encodeVarint(UInt64(value.count)))
        data.append(value)
        return data
    }

    static func fieldString(_ fieldNumber: Int, value: String) -> Data {
        return fieldBytes(fieldNumber, value: Data(value.utf8))
    }

    static func extractFirstVarint(from payload: Data, fieldNumber: Int) -> UInt64? {
        let bytes = [UInt8](payload)
        var idx = 0
        while idx < bytes.count {
            guard let (key, next) = decodeVarint(bytes, start: idx) else { return nil }
            idx = next
            let wireType = Int(key & 0x07)
            let field = Int(key >> 3)

            if field == fieldNumber && wireType == 0 {
                guard let (value, end) = decodeVarint(bytes, start: idx) else { return nil }
                idx = end
                return value
            }

            switch wireType {
            case 0:
                guard let (_, end) = decodeVarint(bytes, start: idx) else { return nil }
                idx = end
            case 2:
                guard let (len, end) = decodeVarint(bytes, start: idx) else { return nil }
                idx = end + Int(len)
                if idx > bytes.count { return nil }
            default:
                return nil
            }
        }
        return nil
    }

    static func extractFirstString(from payload: Data, fieldNumber: Int) -> String? {
        let bytes = [UInt8](payload)
        var idx = 0
        while idx < bytes.count {
            guard let (key, next) = decodeVarint(bytes, start: idx) else { return nil }
            idx = next
            let wireType = Int(key & 0x07)
            let field = Int(key >> 3)

            if wireType == 2 {
                guard let (len, end) = decodeVarint(bytes, start: idx) else { return nil }
                idx = end
                let endIdx = idx + Int(len)
                guard endIdx <= bytes.count else { return nil }

                if field == fieldNumber {
                    let data = Data(bytes[idx..<endIdx])
                    return String(data: data, encoding: .utf8)
                }
                idx = endIdx
                continue
            }

            switch wireType {
            case 0:
                guard let (_, end) = decodeVarint(bytes, start: idx) else { return nil }
                idx = end
            default:
                return nil
            }
        }
        return nil
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8((v & 0x7f) | 0x80))
            v >>= 7
        }
        bytes.append(UInt8(v))
        return bytes
    }

    private static func decodeVarint(_ bytes: [UInt8], start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var idx = start

        while idx < bytes.count {
            let b = bytes[idx]
            value |= UInt64(b & 0x7f) << shift
            idx += 1
            if (b & 0x80) == 0 {
                return (value, idx)
            }
            shift += 7
            if shift > 63 {
                return nil
            }
        }

        return nil
    }
}
    private func handleVideoMessage(_ message: AapMessage) {
        switch message.type {
        case 0x8000: // Media.MsgType.MEDIA_MESSAGE_SETUP
            sendMediaConfig(on: message.channel)

        case 0x8001: // Media.MsgType.MEDIA_MESSAGE_START
            setMediaSessionId(fromStartPayload: message.payload, on: message.channel)

        case 0x8002: // Media.MsgType.MEDIA_MESSAGE_STOP
            break

        case 0, 1: // MEDIA_MESSAGE_DATA / MEDIA_MESSAGE_CODEC_CONFIG
            processVideoStreamPacket(message)
            sendMediaAck(on: message.channel)

        case AapMessageType.VIDEO_FRAME.rawValue:
            // Legacy fallback path.
            processVideoPayloadAsSingleFrame(message.payload)

        default:
            break
        }
    }

    private func processVideoStreamPacket(_ message: AapMessage) {
        let flags = message.flags
        let payload = message.payload
        let nowMs = uptimeMs()
        lastVideoPacketRxAtMs = nowMs

        if videoFirstFragmentAtMs > 0,
           nowMs > videoFirstFragmentAtMs,
           nowMs - videoFirstFragmentAtMs > videoAssemblyTimeoutMs,
           flags == 0x09 {
            print("AapTransport: Video assembly timeout \(nowMs - videoFirstFragmentAtMs)ms, dropping stale fragments")
            videoAssemblyBuffer.removeAll(keepingCapacity: true)
            videoFirstFragmentAtMs = 0
            requestVideoRecoveryIfNeeded(reason: "assembly-timeout", ignoreRecentVideoGuard: false)
        }

        switch flags {
        case 0x0b: // single fragment
            videoFirstFragmentAtMs = 0
            processVideoPayloadAsSingleFrame(payload)

        case 0x09: // first fragment
            videoFirstFragmentAtMs = nowMs
            videoAssemblyBuffer.removeAll(keepingCapacity: true)
            if let offset = findAnnexBStartOffset(in: payload) {
                videoAssemblyBuffer.append(payload.subdata(in: offset..<payload.count))
            } else {
                print("AapTransport: First video fragment missing Annex-B start code")
                requestVideoRecoveryIfNeeded(reason: "missing-start-code", ignoreRecentVideoGuard: false)
            }

        case 0x08: // middle fragment
            if videoFirstFragmentAtMs == 0 {
                print("AapTransport: Orphan middle video fragment received")
                requestVideoRecoveryIfNeeded(reason: "orphan-middle-fragment", ignoreRecentVideoGuard: false)
                return
            }
            if videoAssemblyBuffer.count + payload.count > maxVideoAssemblyBytes {
                print("AapTransport: Video assembly overflow on middle fragment, dropping")
                videoAssemblyBuffer.removeAll(keepingCapacity: true)
                videoFirstFragmentAtMs = 0
                requestVideoRecoveryIfNeeded(reason: "assembly-overflow-middle", ignoreRecentVideoGuard: false)
                return
            }
            videoAssemblyBuffer.append(payload)

        case 0x0a: // last fragment
            if videoAssemblyBuffer.count + payload.count > maxVideoAssemblyBytes {
                print("AapTransport: Video assembly overflow on final fragment, dropping")
                videoAssemblyBuffer.removeAll(keepingCapacity: true)
                videoFirstFragmentAtMs = 0
                requestVideoRecoveryIfNeeded(reason: "assembly-overflow-final", ignoreRecentVideoGuard: false)
                return
            }
            videoFirstFragmentAtMs = 0
            videoAssemblyBuffer.append(payload)
            if !videoAssemblyBuffer.isEmpty {
                delegate?.aapTransport(self, didReceiveVideoData: videoAssemblyBuffer)
            }
            videoAssemblyBuffer.removeAll(keepingCapacity: true)

        default:
            // Unknown media flag variant: best-effort pass through.
            processVideoPayloadAsSingleFrame(payload)
        }
    }

    private func processVideoPayloadAsSingleFrame(_ payload: Data) {
        lastVideoPacketRxAtMs = uptimeMs()
        if let offset = findAnnexBStartOffset(in: payload) {
            delegate?.aapTransport(self, didReceiveVideoData: payload.subdata(in: offset..<payload.count))
        }
    }

    private func findAnnexBStartOffset(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        if bytes.isEmpty { return nil }

        func hasStartCode(at i: Int) -> Bool {
            if i + 3 <= bytes.count,
               bytes[i] == 0x00,
               bytes[i + 1] == 0x00,
               bytes[i + 2] == 0x01 {
                return true
            }
            if i + 4 <= bytes.count,
               bytes[i] == 0x00,
               bytes[i + 1] == 0x00,
               bytes[i + 2] == 0x00,
               bytes[i + 3] == 0x01 {
                return true
            }
            return false
        }

        if bytes.count >= 8 && hasStartCode(at: 8) { return 8 }
        if hasStartCode(at: 0) { return 0 }

        var i = 0
        while i + 3 <= bytes.count {
            if hasStartCode(at: i) { return i }
            i += 1
        }
        return nil
    }

    private func handleAudioMessage(_ message: AapMessage) {
        switch message.type {
        case 0x8000: // Media.MsgType.MEDIA_MESSAGE_SETUP
            sendMediaConfig(on: message.channel)
            sendAudioFocusGainUnsolicited()

        case 0x8001: // Media.MsgType.MEDIA_MESSAGE_START
            setMediaSessionId(fromStartPayload: message.payload, on: message.channel)

        case 0x8002: // Media.MsgType.MEDIA_MESSAGE_STOP
            break

        case 0: // MEDIA_MESSAGE_DATA
            let payloadOffset = resolveAudioPayloadOffset(message.payload)
            if message.payload.count > payloadOffset {
                let pcm = message.payload.subdata(in: payloadOffset..<message.payload.count)
                delegate?.aapTransport(self, didReceiveAudioData: pcm, on: message.channel)
            }
            sendMediaAck(on: message.channel)

        case 1: // MEDIA_MESSAGE_CODEC_CONFIG
            // For declared PCM streams, config packets are not raw PCM payload.
            // Acknowledge but do not feed into playback.
            sendMediaAck(on: message.channel)

        case AapMessageType.AUDIO_FRAME.rawValue:
            // Legacy fallback path.
            let payloadOffset = resolveAudioPayloadOffset(message.payload)
            if message.payload.count > payloadOffset {
                let pcm = message.payload.subdata(in: payloadOffset..<message.payload.count)
                delegate?.aapTransport(self, didReceiveAudioData: pcm, on: message.channel)
            }

        default:
            print("AapTransport: Unhandled audio message type=\(message.type) on channel \(Channel.name(for: message.channel))")
        }
    }

    private func resolveAudioPayloadOffset(_ payload: Data) -> Int {
        // Two payload variants are observed in the wild:
        // 1) [8-byte timestamp][PCM]
        // 2) [2-byte media msg type][8-byte timestamp][PCM]
        // If we always assume one variant, the other produces severe static.
        if payload.count >= 10 {
            let typeCandidate = UInt16(payload[0]) << 8 | UInt16(payload[1])
            if isKnownMediaMsgType(typeCandidate) {
                return 10
            }
        }
        return 8
    }

    private func handleMicrophoneMessage(_ message: AapMessage) {
        switch message.type {
        case 0x8000: // Media.MsgType.MEDIA_MESSAGE_SETUP
            print("AapTransport: Microphone setup request received")
            sendMediaConfig(on: message.channel)

        case 0x8001: // Media.MsgType.MEDIA_MESSAGE_START
            print("AapTransport: Microphone start request received")
            setMediaSessionId(fromStartPayload: message.payload, on: message.channel)

        case 0x8002: // Media.MsgType.MEDIA_MESSAGE_STOP
            print("AapTransport: Microphone stop request received")
            delegate?.aapTransport(self, didRequestMicrophoneCapture: false)
            sendAudioFocusGainUnsolicited()

        case 0x8005: // Media.MsgType.MEDIA_MESSAGE_MICROPHONE_REQUEST
            let openValue = ProtoWire.extractFirstVarint(from: message.payload, fieldNumber: 1) ?? 0
            let shouldOpen = openValue != 0
            print("AapTransport: Microphone request open=\(shouldOpen)")
            delegate?.aapTransport(self, didRequestMicrophoneCapture: shouldOpen)
            if !shouldOpen {
                // Assistant flow ended. Proactively restore media focus to unstick playback.
                sendAudioFocusGainUnsolicited()
            }
            sendMicrophoneResponse(on: message.channel, status: 0)

        case 0x8006: // Media.MsgType.MEDIA_MESSAGE_MICROPHONE_RESPONSE
            break

        case 0x8004: // Media.MsgType.MEDIA_MESSAGE_ACK
            break

        default:
            print("AapTransport: Unhandled microphone message type=\(message.type)")
        }
    }

    private func sendMicrophoneResponse(on channel: UInt8, status: UInt64) {
        let sessionId = mediaSessionIds[channel] ?? 0
        let payload = ProtoWire.fieldVarint(1, value: status)
            + ProtoWire.fieldVarint(2, value: sessionId)

        let message = AapMessage(
            channel: channel,
            flags: AapFlags.NORMAL_MESSAGE,
            type: 0x8006,
            payload: payload
        )
        send(message: message)
    }

    private func setMediaSessionId(fromStartPayload payload: Data, on channel: UInt8) {
        // Media.Start { session_id = 1, configuration_index = 2 }
        if let sessionId = ProtoWire.extractFirstVarint(from: payload, fieldNumber: 1) {
            mediaSessionIds[channel] = sessionId
            print("AapTransport: Stored media session id \(sessionId) for channel \(Channel.name(for: channel))")
        }
    }

    private func sendMediaAck(on channel: UInt8) {
        let sessionId = mediaSessionIds[channel] ?? 0
        // Media.Ack { session_id = 1, ack = 1 }
        let payload = ProtoWire.fieldVarint(1, value: sessionId)
            + ProtoWire.fieldVarint(2, value: 1)

        let message = AapMessage(
            channel: channel,
            flags: AapFlags.NORMAL_MESSAGE,
            type: 0x8004,
            payload: payload
        )
        mediaAckQueue.async { [weak self] in
            guard let self = self else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            self.send(message: message)
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if elapsedMs > 25 {
                print("AapTransport: Slow media ACK on \(Channel.name(for: channel)) took \(elapsedMs)ms")
            }
        }
    }

    private func requestVideoRecoveryIfNeeded(reason: String, ignoreRecentVideoGuard: Bool) {
        guard state == .running || state == .binding || state == .authenticatingComplete else {
            return
        }

        let nowMs = uptimeMs()
        if !ignoreRecentVideoGuard,
           lastVideoPacketRxAtMs > 0,
           nowMs > lastVideoPacketRxAtMs,
           nowMs - lastVideoPacketRxAtMs < 4_000 {
            return
        }

        if nowMs > lastVideoRecoveryRequestAtMs,
           nowMs - lastVideoRecoveryRequestAtMs < minVideoRecoveryIntervalMs {
            return
        }

        lastVideoRecoveryRequestAtMs = nowMs
        print("AapTransport: Requesting video recovery, reason=\(reason)")
        sendVideoFocusNotification(on: Channel.ID_VID, reason: "recovery-\(reason)")
    }

    private func uptimeMs() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func sendMediaConfig(on channel: UInt8) {
        // Media.Config { status=HEADUNIT(2), max_unacked=30, configuration_indices=[0] }
        let payload = ProtoWire.fieldVarint(1, value: 2)
            + ProtoWire.fieldVarint(2, value: 30)
            + ProtoWire.fieldVarint(3, value: 0)

        let message = AapMessage(
            channel: channel,
            flags: AapFlags.NORMAL_MESSAGE,
            type: 0x8003,
            payload: payload
        )
        send(message: message)
        if !Channel.isAudio(channel) && channel != Channel.ID_MIC && channel != Channel.ID_VID {
            print("AapTransport: Sent media config on channel \(Channel.name(for: channel))")
        }
    }

    private func sendAudioFocusGainUnsolicited() {
        // Control.AudioFocusNotification { focus_state=STATE_GAIN(1), unsolicited=true }
        let payload = ProtoWire.fieldVarint(1, value: 1)
            + ProtoWire.fieldVarint(2, value: 1)

        let message = AapMessage(
            channel: Channel.ID_CTR,
            flags: AapFlags.CONTROL_MESSAGE,
            type: AapMessageType.AUDIO_FOCUS_NOTIFICATION.rawValue,
            payload: payload
        )
        send(message: message)
    }

    private func recordAapTrace(direction: String, channel: UInt8, flags: UInt8, type: UInt16, payloadSize: Int) {
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        let entry = AapTraceEntry(
            timestampMs: ts,
            direction: direction,
            channel: channel,
            flags: flags,
            type: type,
            payloadSize: payloadSize
        )
        aapTraceLock.lock()
        lastAapTrace.append(entry)
        if lastAapTrace.count > maxAapTraceEntries {
            lastAapTrace.removeFirst(lastAapTrace.count - maxAapTraceEntries)
        }
        aapTraceLock.unlock()
    }

    private func dumpRecentAapTrace(reason: String) {
        aapTraceLock.lock()
        let traceSnapshot = lastAapTrace
        aapTraceLock.unlock()

        guard !traceSnapshot.isEmpty else {
            print("AapTransport: No recent AAP trace before disconnect (\(reason))")
            return
        }

        print("AapTransport: Recent AAP trace before disconnect (\(reason)):")
        for (idx, entry) in traceSnapshot.enumerated() {
            print("  [\(idx + 1)] t=\(entry.timestampMs) \(entry.direction) ch=\(Channel.name(for: entry.channel))(\(entry.channel)) flags=0x\(String(format: "%02x", entry.flags)) type=\(entry.type) size=\(entry.payloadSize)")
        }
    }
}

extension AapTransport: TcpHandlerDelegate {
    func tcpHandlerDidConnect(_ handler: TcpHandler) {
        print("AapTransport: TCP connected, starting handshake")
        startHandshake()
    }

    func tcpHandler(_ handler: TcpHandler, didFailWithError error: Error) {
        print("AapTransport: TCP error: \(error)")
        dumpRecentAapTrace(reason: "tcp-error")
        setState(.error(error.localizedDescription))
        delegate?.aapTransportDidDisconnect(self)
    }

    func tcpHandler(_ handler: TcpHandler, didReceiveData data: Data) {
        processingQueue.async { [weak self] in
            self?.handleReceivedData(data)
        }
    }

    func tcpHandlerDidDisconnect(_ handler: TcpHandler) {
        print("AapTransport: TCP disconnected")
        dumpRecentAapTrace(reason: "tcp-disconnect")
        delayedVersionStartWorkItem?.cancel()
        delayedVersionStartWorkItem = nil
        versionRetryWorkItem?.cancel()
        versionRetryWorkItem = nil
        tlsHandler.releaseSessionOnly()
        delegate?.aapTransportDidDisconnect(self)
    }
}

enum TouchAction: UInt8 {
    case DOWN = 0
    case UP = 1
    case MOVE = 2
    case CANCEL = 3
    case POINTER_DOWN = 5
    case POINTER_UP = 6
}
