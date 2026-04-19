//
//  ConnectionManager.swift
//  HeadunitPad
//
//  Manages device discovery and connection lifecycle
//

import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case discovering
    case connecting
    case handshaking
    case running
    case error(String)

    var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .discovering:
            return "Scanning..."
        case .connecting:
            return "Connecting..."
        case .handshaking:
            return "Handshaking..."
        case .running:
            return "Connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

protocol ConnectionManagerDelegate: AnyObject {
    func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState)
    func connectionManager(_ manager: ConnectionManager, didDiscoverDevice device: DiscoveredDevice)
    func connectionManager(_ manager: ConnectionManager, didReceiveVideoData data: Data)
    func connectionManager(_ manager: ConnectionManager, didReceiveAudioData data: Data, on channel: UInt8)
}

class ConnectionManager {
    weak var delegate: ConnectionManagerDelegate?

    private let discovery = Discovery()
    private let tcpHandler = TcpHandler()
    private let microphoneCapture = MicrophoneCapture()
    private let locationCapture = LocationCapture()
    private var aapTransport: AapTransport?

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            print("ConnectionManager: state changed from \(oldValue.description) to \(state.description)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.connectionManager(self, didChangeState: self.state)
            }
        }
    }

    private(set) var discoveredDevices: [DiscoveredDevice] = []
    private(set) var connectedDevice: DiscoveredDevice?

    init() {
        discovery.delegate = self
        aapTransport = AapTransport(tcpHandler: tcpHandler)
        aapTransport?.delegate = self
        microphoneCapture.onPCMData = { [weak self] data in
            self?.aapTransport?.sendMicrophoneAudioData(data)
        }
        locationCapture.onLocation = { [weak self] location in
            self?.aapTransport?.sendLocationUpdate(location)
        }
    }

    func requestLocationPermissionIfNeeded() {
        guard ProjectionSettings.gpsSource == .ipad else { return }
        guard ProjectionSettings.supportsCellularIpad() else { return }
        locationCapture.requestPermissionIfNeeded()
    }

    func startDiscovery() {
        print("ConnectionManager: startDiscovery called")
        let canStart: Bool
        switch state {
        case .disconnected, .error:
            canStart = true
        default:
            canStart = false
        }

        guard canStart else {
            print("ConnectionManager: Cannot start discovery, current state: \(state.description)")
            return
        }

        discoveredDevices.removeAll()
        state = .discovering
        discovery.startScan()
    }

    func stopDiscovery() {
        print("ConnectionManager: stopDiscovery called")
        discovery.stopScan()
        if state == .discovering {
            state = .disconnected
        }
    }

    func connect(to device: DiscoveredDevice) {
        print("ConnectionManager: connect(to:) called with device: \(device.displayName)")
        let preparedConnection = discovery.takePreparedConnection(ip: device.ip, port: device.port)
        stopDiscovery()
        state = .connecting
        connectedDevice = device
        aapTransport?.configurePeer(host: device.ip, port: device.port)

        if let preparedConnection = preparedConnection {
            print("ConnectionManager: Using prepared connection from discovery for \(device.ip):\(device.port)")
            tcpHandler.adoptConnection(preparedConnection, host: device.ip, port: device.port)
        } else {
            print("ConnectionManager: Calling tcpHandler.connect(host: \(device.ip), port: \(device.port))")
            tcpHandler.connect(host: device.ip, port: device.port)
        }
    }

    func connect(to ip: String, port: UInt16 = 5277) {
        print("ConnectionManager: connect(to:port:) called with ip: \(ip), port: \(port)")
        let device = DiscoveredDevice(ip: ip, port: port, name: nil)
        connect(to: device)
    }

    func disconnect() {
        print("ConnectionManager: disconnect called")
        microphoneCapture.stop()
        locationCapture.stop()
        tcpHandler.disconnect()
        connectedDevice = nil
        state = .disconnected
    }

    func send(_ data: Data) {
        guard state == .running else { return }
        aapTransport?.send(message: AapMessage(channel: 0, flags: 0, type: 0, payload: data))
    }

    func sendTouchEvent(x: Int, y: Int, action: TouchAction) {
        guard state == .running else { return }
        aapTransport?.sendTouchEvent(x: x, y: y, action: action)
    }

    func sendTouchEvent(pointers: [(id: Int, x: Int, y: Int)], action: TouchAction, actionIndex: Int) {
        guard state == .running else { return }
        aapTransport?.sendTouchEvent(pointers: pointers, action: action, actionIndex: actionIndex)
    }

    func requestVideoRecovery() {
        guard state == .running else { return }
        aapTransport?.requestVideoRecovery()
    }

    func requestVideoRecoveryForNewDisplay() {
        guard state == .running else { return }
        aapTransport?.requestVideoRecoveryForNewDisplay()
    }
}

extension ConnectionManager: DiscoveryDelegate {
    func discoveryDidFindDevice(_ device: DiscoveredDevice) {
        print("ConnectionManager: discovered device: \(device.displayName)")
        discoveredDevices.append(device)
        delegate?.connectionManager(self, didDiscoverDevice: device)
    }

    func discoveryDidFinish() {
        print("ConnectionManager: discovery finished, found \(discoveredDevices.count) devices")
        if state == .discovering {
            state = .disconnected
        }
    }

    func discoveryDidFail(_ error: Error) {
        print("ConnectionManager: discovery failed with error: \(error.localizedDescription)")
        state = .error(error.localizedDescription)
    }
}

extension ConnectionManager: TcpHandlerDelegate {
    func tcpHandlerDidConnect(_ handler: TcpHandler) {
        print("ConnectionManager: TCP connection established")
        state = .handshaking
        aapTransport?.startHandshake()
    }

    func tcpHandler(_ handler: TcpHandler, didFailWithError error: Error) {
        print("ConnectionManager: TCP failed with error: \(error.localizedDescription)")
        state = .error(error.localizedDescription)
    }

    func tcpHandler(_ handler: TcpHandler, didReceiveData data: Data) {
    }

    func tcpHandlerDidDisconnect(_ handler: TcpHandler) {
        print("ConnectionManager: TCP disconnected")
        state = .disconnected
        connectedDevice = nil
    }
}

extension ConnectionManager: AapTransportDelegate {
    func aapTransport(_ transport: AapTransport, didRequestMicrophoneCapture isOpen: Bool) {
        if isOpen {
            microphoneCapture.start(sampleRate: 16_000, channels: 1)
        } else {
            microphoneCapture.stop()
        }
    }

    func aapTransport(_ transport: AapTransport, didRequestLocationUpdates isEnabled: Bool) {
        if isEnabled {
            locationCapture.start()
        } else {
            locationCapture.stop()
        }
    }

    func aapTransport(_ transport: AapTransport, didReceiveVideoData data: Data) {
        delegate?.connectionManager(self, didReceiveVideoData: data)
    }

    func aapTransport(_ transport: AapTransport, didReceiveAudioData data: Data, on channel: UInt8) {
        delegate?.connectionManager(self, didReceiveAudioData: data, on: channel)
    }

    func aapTransport(_ transport: AapTransport, didChangeState state: AapTransportState) {
        switch state {
        case .running:
            self.state = .running
        case .error(let msg):
            microphoneCapture.stop()
            locationCapture.stop()
            self.state = .error(msg)
        default:
            break
        }
    }

    func aapTransportDidDisconnect(_ transport: AapTransport) {
        microphoneCapture.stop()
        locationCapture.stop()
        state = .disconnected
        connectedDevice = nil
    }
}
