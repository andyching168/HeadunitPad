import Foundation
import AVFoundation

final class PCMAudioPlayer {
    private struct Stream {
        let format: AVAudioFormat
        let player: AVAudioPlayerNode
    }

    private let engine = AVAudioEngine()
    private var streams: [UInt8: Stream] = [:]
    private var sessionConfigured = false
    private let audioQueue = DispatchQueue(label: "com.headunitpad.audio.player", qos: .userInitiated)

    func reset() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            streams.values.forEach { $0.player.stop() }
            streams.removeAll()
            engine.stop()
            engine.reset()
            sessionConfigured = false
        }
    }

    func playPCM(_ data: Data, on channel: UInt8) {
        guard !data.isEmpty else { return }
        audioQueue.async { [weak self] in
            guard let self = self, !data.isEmpty else { return }
            self.ensureSessionConfigured()
            guard let stream = self.ensureStream(for: channel) else { return }
            guard self.startEngineIfNeeded() else { return }
            guard let buffer = self.makePCMBuffer(from: data, format: stream.format) else { return }
            stream.player.scheduleBuffer(buffer, completionHandler: nil)
            if !stream.player.isPlaying {
                stream.player.play()
            }
        }
    }

    private func ensureSessionConfigured() {
        if !sessionConfigured {
            let session = AVAudioSession.sharedInstance()
            do {
                // .defaultToSpeaker is only valid with .playAndRecord.
                // For playback-only audio, keep a legal option set.
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                print("PCMAudioPlayer: Failed to configure audio session: \(error)")
            }
            sessionConfigured = true
        }
    }

    private func startEngineIfNeeded() -> Bool {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("PCMAudioPlayer: Failed to start AVAudioEngine: \(error)")
                return false
            }
        }
        return true
    }

    private func ensureStream(for channel: UInt8) -> Stream? {
        if let existing = streams[channel] { return existing }

        let (sampleRate, outputChannels): (Double, AVAudioChannelCount)
        switch channel {
        case 6:
            sampleRate = 48_000
            outputChannels = 2
        case 4, 5:
            sampleRate = 16_000
            // AU1/AU2 source is mono by protocol; we upmix to stereo for output.
            outputChannels = 2
        default:
            sampleRate = 48_000
            outputChannels = 2
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: outputChannels, interleaved: false) else {
            return nil
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let stream = Stream(format: format, player: player)
        streams[channel] = stream
        return stream
    }

    private func makePCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let outputChannels = Int(format.channelCount)
        guard outputChannels > 0 else { return nil }

        let inputChannels: Int
        if format.sampleRate == 16_000 {
            inputChannels = 1
        } else {
            inputChannels = 2
        }

        let bytesPerSample = 2
        let bytesPerFrame = inputChannels * bytesPerSample
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else { return nil }

        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            if inputChannels == 1 {
                let left = channelData[0]
                let right = outputChannels > 1 ? channelData[1] : nil
                for i in 0..<frameCount {
                    let s = Float(samples[i]) / 32768.0
                    left[i] = s
                    right?[i] = s
                }
            } else {
                let left = channelData[0]
                let right = outputChannels > 1 ? channelData[1] : channelData[0]
                for i in 0..<frameCount {
                    let base = i * inputChannels
                    left[i] = Float(samples[base]) / 32768.0
                    right[i] = Float(samples[base + 1]) / 32768.0
                }
            }
        }

        return buffer
    }
}
