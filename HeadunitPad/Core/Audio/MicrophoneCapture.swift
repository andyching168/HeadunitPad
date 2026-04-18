import Foundation
import AVFoundation

final class MicrophoneCapture {
    var onPCMData: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "com.headunitpad.audio.mic.processing", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var isCapturing = false

    func start(sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) {
        guard !isCapturing else { return }

        configureAudioSession(sampleRate: sampleRate, channels: channels)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) else {
            print("MicrophoneCapture: Failed to create target audio format")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("MicrophoneCapture: Failed to create audio converter")
            return
        }

        self.converter = converter
        self.outputFormat = targetFormat

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
            print("MicrophoneCapture: Started")
        } catch {
            print("MicrophoneCapture: Failed to start engine: \(error)")
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            self.outputFormat = nil
        }
    }

    func stop() {
        guard isCapturing else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        converter = nil
        outputFormat = nil
        isCapturing = false
        print("MicrophoneCapture: Stopped")
    }

    private func configureAudioSession(sampleRate: Double, channels: AVAudioChannelCount) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(sampleRate)
            try session.setPreferredInputNumberOfChannels(Int(channels))
            try session.setActive(true)
        } catch {
            print("MicrophoneCapture: Failed to configure session: \(error)")
        }
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter, let outputFormat = outputFormat else { return }

        processingQueue.async { [weak self] in
            guard let self = self else { return }

            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = max(Int(Double(buffer.frameLength) * ratio) + 32, 256)

            guard let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(capacity)
            ) else {
                return
            }

            var consumed = false
            var conversionError: NSError?

            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .error {
                if let conversionError = conversionError {
                    print("MicrophoneCapture: Conversion error: \(conversionError)")
                }
                return
            }

            guard converted.frameLength > 0 else { return }
            guard let channelData = converted.floatChannelData else { return }

            let frameCount = Int(converted.frameLength)
            let source = channelData[0]
            var pcm = Data(count: frameCount * MemoryLayout<Int16>.size)
            pcm.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for i in 0..<frameCount {
                    let sample = max(-1.0, min(1.0, source[i]))
                    out[i] = Int16(sample * 32767.0)
                }
            }

            if pcm.count > 64 {
                self.onPCMData?(pcm)
            }
        }
    }
}
