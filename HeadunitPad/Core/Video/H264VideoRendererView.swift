import UIKit
import AVFoundation
import CoreMedia

final class H264VideoRendererView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }

    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var frameIndex: Int64 = 0
    private var notReadyStreak = 0
    private let processQueue = DispatchQueue(label: "com.headunitpad.video.process", qos: .userInteractive)
    private let frameQueueLock = NSLock()
    private var pendingFrames: [Data] = []
    private var isProcessingFrame = false
    private let maxPendingFrames = 4
    private var hasDecodedKeyframe = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    func reset() {
        frameQueueLock.lock()
        pendingFrames.removeAll()
        isProcessingFrame = false
        frameQueueLock.unlock()

        processQueue.async { [weak self] in
            guard let self = self else { return }
            self.frameIndex = 0
            self.sps = nil
            self.pps = nil
            self.formatDescription = nil
            self.hasDecodedKeyframe = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.notReadyStreak = 0
            self.displayLayer.flushAndRemoveImage()
        }
    }

    func enqueueAnnexBFrame(_ frame: Data) {
        guard !frame.isEmpty else { return }
        enqueueFrameForProcessing(frame)
    }

    private func enqueueFrameForProcessing(_ frame: Data) {
        frameQueueLock.lock()
        if pendingFrames.count >= maxPendingFrames {
            if let dropIndex = pendingFrames.firstIndex(where: { !containsIDRNal($0) }) {
                pendingFrames.remove(at: dropIndex)
            } else {
                pendingFrames.removeFirst()
            }
        }
        pendingFrames.append(frame)

        if isProcessingFrame {
            frameQueueLock.unlock()
            return
        }
        isProcessingFrame = true
        frameQueueLock.unlock()

        processQueue.async { [weak self] in
            self?.processFrameLoop()
        }
    }

    private func processFrameLoop() {
        while true {
            let nextFrame: Data?
            frameQueueLock.lock()
            if pendingFrames.isEmpty {
                isProcessingFrame = false
                frameQueueLock.unlock()
                return
            }
            nextFrame = pendingFrames.removeFirst()
            frameQueueLock.unlock()

            guard let frame = nextFrame else { continue }
            processSingleFrame(frame)
        }
    }

    private func processSingleFrame(_ frame: Data) {
        let nalUnits = splitAnnexBNALUnits(frame)
        guard !nalUnits.isEmpty else { return }

        let hasIDR = nalUnits.contains { nal in
            guard let header = nal.first else { return false }
            return (header & 0x1F) == 5
        }

        for nal in nalUnits {
            guard let header = nal.first else { continue }
            let nalType = header & 0x1F
            if nalType == 7 { sps = nal }
            if nalType == 8 { pps = nal }
        }

        if formatDescription == nil,
           let sps,
           let pps,
           let desc = createFormatDescription(sps: sps, pps: pps) {
            formatDescription = desc
        }

        guard let formatDescription else { return }

        // Drop predictive frames until first keyframe to avoid startup block artifacts.
        if !hasDecodedKeyframe {
            guard hasIDR else { return }
            hasDecodedKeyframe = true
        }

        let avccData = makeAVCCSample(from: nalUnits)
        guard !avccData.isEmpty else { return }
        guard let sampleBuffer = makeSampleBuffer(data: avccData, formatDescription: formatDescription) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if self.displayLayer.status == .failed {
                // Full reset helps recover from persistent AVSampleBufferDisplayLayer failures.
                self.displayLayer.flushAndRemoveImage()
                self.processQueue.async {
                    self.formatDescription = nil
                    self.frameIndex = 0
                    self.hasDecodedKeyframe = false
                }
                self.notReadyStreak = 0
                return
            }

            guard self.displayLayer.isReadyForMoreMediaData else {
                self.notReadyStreak += 1

                if self.notReadyStreak == 30 {
                    self.displayLayer.flush()
                } else if self.notReadyStreak >= 90 {
                    self.displayLayer.flushAndRemoveImage()
                    self.processQueue.async {
                        self.formatDescription = nil
                        self.frameIndex = 0
                        self.hasDecodedKeyframe = false
                    }
                    self.notReadyStreak = 0
                }
                return
            }

            self.notReadyStreak = 0
            self.displayLayer.enqueue(sampleBuffer)
        }
    }

    private func containsIDRNal(_ frame: Data) -> Bool {
        let nalUnits = splitAnnexBNALUnits(frame)
        for nal in nalUnits {
            guard let header = nal.first else { continue }
            let nalType = header & 0x1F
            if nalType == 5 {
                return true
            }
        }
        return false
    }

    private func createFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        return sps.withUnsafeBytes { spsPtr in
            return pps.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return nil
                }

                var formatDesc: CMFormatDescription?
                let parameterSetPointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let parameterSetSizes: [Int] = [sps.count, pps.count]

                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                guard status == noErr else { return nil }
                return formatDesc
            }
        }
    }

    private func makeAVCCSample(from nalUnits: [Data]) -> Data {
        var out = Data()
        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }

    private func makeSampleBuffer(data: Data, formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else { return nil }

        let copyStatus = data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copyStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
            decodeTimeStamp: .invalid
        )
        frameIndex += 1

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }

    private func splitAnnexBNALUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        func startCodeLength(at i: Int) -> Int {
            if i + 3 <= bytes.count,
               bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                return 3
            }
            if i + 4 <= bytes.count,
               bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                return 4
            }
            return 0
        }

        var starts: [(Int, Int)] = []
        var i = 0
        while i < bytes.count {
            let len = startCodeLength(at: i)
            if len > 0 {
                starts.append((i, len))
                i += len
            } else {
                i += 1
            }
        }

        guard !starts.isEmpty else { return [data] }

        var units: [Data] = []
        for idx in 0..<starts.count {
            let nalStart = starts[idx].0 + starts[idx].1
            let nalEnd = (idx + 1 < starts.count) ? starts[idx + 1].0 : bytes.count
            if nalStart < nalEnd {
                units.append(data.subdata(in: nalStart..<nalEnd))
            }
        }
        return units
    }
}
