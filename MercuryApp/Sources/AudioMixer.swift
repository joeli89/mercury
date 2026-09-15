import AVFoundation

/// Mixes microphone + system audio into a single 48 kHz stereo track.
///
/// Incoming buffers (which may have different formats/rates) are converted to a
/// canonical interleaved Float32 format, summed into a timeline accumulator, and
/// emitted as ready-to-write CMSampleBuffers. A small latency window lets the two
/// sources' samples line up before a region is flushed.
///
/// All methods must be called from a single serial queue (the capture audio queue).
final class AudioMixer {
    enum Source { case system, mic }

    private let sampleRate: Double = 48000
    private let channels = 2
    private let latencyFrames: Int
    private let onMixedBuffer: (CMSampleBuffer) -> Void

    private let canonicalFormat: AVAudioFormat
    private var canonicalFormatDesc: CMAudioFormatDescription?
    private var converters: [String: AVAudioConverter] = [:]

    private var sessionStart: CMTime?
    private var baseIndex = 0            // absolute frame index of accumulator[0]
    private var acc: [Float] = []       // interleaved stereo
    private var highestWritten = 0      // absolute frame index one past last written sample

    init(latency: Double = 0.2, onMixedBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.latencyFrames = Int(latency * 48000)
        self.onMixedBuffer = onMixedBuffer
        self.canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48000, channels: 2, interleaved: true)!
        var asbd = canonicalFormat.streamDescription.pointee
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &canonicalFormatDesc)
    }

    func append(_ sampleBuffer: CMSampleBuffer, from _: Source) {
        guard let (startIndex, samples) = canonicalSamples(from: sampleBuffer) else { return }
        let frames = samples.count / channels
        guard frames > 0 else { return }

        var local = startIndex - baseIndex
        var offsetInSamples = 0
        if local < 0 {
            // Part of this buffer predates what we've already flushed — drop that part.
            let dropFrames = -local
            if dropFrames >= frames { return }
            offsetInSamples = dropFrames * channels
            local = 0
        }

        let neededFrames = local + (frames - offsetInSamples / channels)
        if acc.count < neededFrames * channels {
            acc.append(contentsOf: repeatElement(0, count: neededFrames * channels - acc.count))
        }

        var s = offsetInSamples
        var d = local * channels
        while s < samples.count {
            acc[d] += samples[s]
            s += 1; d += 1
        }
        highestWritten = max(highestWritten, baseIndex + neededFrames)
        flush(force: false)
    }

    func finish() {
        flush(force: true)
    }

    private func flush(force: Bool) {
        let flushUntil = force ? highestWritten : (highestWritten - latencyFrames)
        let framesToFlush = flushUntil - baseIndex
        guard framesToFlush > 0, let sessionStart else { return }

        let count = framesToFlush * channels
        let chunk = Array(acc[0..<count])
        if let sb = makeSampleBuffer(interleaved: chunk, frameIndex: baseIndex, sessionStart: sessionStart) {
            onMixedBuffer(sb)
        }
        acc.removeFirst(count)
        baseIndex = flushUntil
    }

    // MARK: - Conversion

    private func canonicalSamples(from sb: CMSampleBuffer) -> (startIndex: Int, samples: [Float])? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
        let numFrames = CMSampleBufferGetNumSamples(sb)
        guard numFrames > 0,
              let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(numFrames))
        else { return nil }
        srcBuf.frameLength = AVAudioFrameCount(numFrames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0,
                        frameCount: Int32(numFrames), into: srcBuf.mutableAudioBufferList)
        guard status == noErr else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if sessionStart == nil { sessionStart = pts }
        let startIndex = Int((pts - sessionStart!).seconds * sampleRate + 0.5)

        // Fast path: already canonical.
        if srcFormat.commonFormat == .pcmFormatFloat32,
           srcFormat.sampleRate == sampleRate,
           srcFormat.channelCount == UInt32(channels),
           srcFormat.isInterleaved {
            return (startIndex, readInterleaved(srcBuf))
        }

        let key = "\(srcFormat.sampleRate)-\(srcFormat.channelCount)-\(srcFormat.commonFormat.rawValue)-\(srcFormat.isInterleaved)"
        let converter: AVAudioConverter
        if let c = converters[key] {
            converter = c
        } else {
            guard let c = AVAudioConverter(from: srcFormat, to: canonicalFormat) else { return nil }
            converters[key] = c
            converter = c
        }

        let ratio = sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(numFrames) * ratio + 32)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: outCapacity) else { return nil }

        var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        if convError != nil { return nil }
        return (startIndex, readInterleaved(outBuf))
    }

    private func readInterleaved(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let total = frames * channels
        guard let abl = buffer.audioBufferList.pointee.mBuffers.mData else { return [] }
        let ptr = abl.bindMemory(to: Float.self, capacity: total)
        return Array(UnsafeBufferPointer(start: ptr, count: total))
    }

    // MARK: - Output buffer

    private func makeSampleBuffer(interleaved floats: [Float], frameIndex: Int, sessionStart: CMTime) -> CMSampleBuffer? {
        guard let fmtDesc = canonicalFormatDesc, !floats.isEmpty else { return nil }
        let numFrames = floats.count / channels
        let dataSize = floats.count * MemoryLayout<Float>.size
        let pts = sessionStart + CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(sampleRate))

        var blockBuffer: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                    blockLength: dataSize, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                    offsetToData: 0, dataLength: dataSize, flags: 0, blockBufferOut: &blockBuffer)
        guard st == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        st = floats.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: dataSize)
        }
        guard st == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let err = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: fmtDesc,
            sampleCount: numFrames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard err == noErr else { return nil }
        return sampleBuffer
    }
}
