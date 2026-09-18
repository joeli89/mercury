import AVFoundation
import CoreVideo
import Darwin

/// Wraps an AVAssetWriter with one video track (from a pixel-buffer adaptor)
/// and, optionally, one audio track. All mutation happens on a private serial
/// queue so it is safe to call from the capture callbacks.
final class MovieWriter {
    private let queue = DispatchQueue(label: "com.mercury.moviewriter")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var startPTS: CMTime = .zero
    private(set) var finished = false
    private var videoFrames = 0
    private var droppedFrames = 0
    private var audioBuffers = 0
    private var loggedAppendFailure = false

    let outputURL: URL

    /// Encoder settings summary, for the log.
    private(set) var encoderSummary = ""

    /// - quality: 0…1 for the hardware encoder's constant-quality mode
    ///   (Apple silicon). Bits go where the picture changes, so static screen
    ///   content costs almost nothing. Benchmarked on real screen recordings:
    ///   0.55 ≈ VMAF 92, 0.65 ≈ 94, 0.75 ≈ 96 — all better than a 3 Mbps
    ///   stream re-encoded with x265, with no post-processing.
    /// - maxBitrate: ceiling (bits/s) so a chaotic screen can't balloon the file.
    init(url: URL, width: Int, height: Int, fps: Int, hasAudio: Bool,
         quality: Double, maxBitrate: Int) throws {
        outputURL = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        var compression: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: fps * 10,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: true
        ]
        if Self.supportsConstantQuality {
            compression[AVVideoQualityKey] = quality
            compression[AVVideoAverageBitRateKey] = maxBitrate   // acts as a ceiling alongside Quality
            encoderSummary = "HEVC constant quality \(quality) (ceiling \(maxBitrate / 1000) kbps), GOP \(fps * 10)"
        } else {
            // Intel: no constant-quality mode — pick a bitrate from the quality.
            let bitrate = Int(Double(width * height) * Double(fps) * (0.012 + 0.03 * quality))
            compression[AVVideoAverageBitRateKey] = min(bitrate, maxBitrate)
            encoderSummary = "HEVC \(min(bitrate, maxBitrate) / 1000) kbps (bitrate mode), GOP \(fps * 10)"
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attrs)
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        if hasAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            audioInput = input
        } else {
            audioInput = nil
        }
    }

    func prepare() {
        queue.sync {
            _ = writer.startWriting()
        }
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else {
                if !self.loggedAppendFailure {
                    self.loggedAppendFailure = true
                    AppLog.log("Writer:        frame arrived but writer not writing (status \(self.writer.status.rawValue), finished \(self.finished)) — \(Self.describe(self.writer.error))")
                }
                return
            }
            if !self.sessionStarted {
                self.writer.startSession(atSourceTime: pts)
                self.startPTS = pts
                self.sessionStarted = true
            }
            if self.videoInput.isReadyForMoreMediaData {
                if self.adaptor.append(pixelBuffer, withPresentationTime: pts) {
                    self.videoFrames += 1
                } else if !self.loggedAppendFailure {
                    self.loggedAppendFailure = true
                    AppLog.log("Writer:        video append FAILED (\(CVPixelBufferGetWidth(pixelBuffer))×\(CVPixelBufferGetHeight(pixelBuffer))) — \(Self.describe(self.writer.error))")
                }
            } else {
                self.droppedFrames += 1
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput else { return }
        queue.async {
            guard !self.finished, self.writer.status == .writing, self.sessionStarted else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts >= self.startPTS else { return }
            if audioInput.isReadyForMoreMediaData {
                if audioInput.append(sampleBuffer) { self.audioBuffers += 1 }
            }
        }
    }

    /// Abort writing and delete the output file (used to discard a recording).
    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                if self.writer.status == .writing {
                    self.writer.cancelWriting()
                }
                try? FileManager.default.removeItem(at: self.outputURL)
                continuation.resume()
            }
        }
    }

    /// Apple silicon's hardware encoder supports constant-quality mode; Intel's doesn't.
    static let supportsConstantQuality: Bool = {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        var vsize = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &vsize, nil, 0)
        return value == 1
    }()

    /// Full error text including the underlying error, for the log.
    private static func describe(_ error: Error?) -> String {
        guard let error else { return "no error" }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let reason = ns.localizedFailureReason { text += " — \(reason)" }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " [underlying \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)]"
        }
        return text
    }

    func finish() async -> Result<URL, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, Error>, Never>) in
            queue.async {
                guard !self.finished else {
                    continuation.resume(returning: .success(self.outputURL)); return
                }
                self.finished = true
                AppLog.log("Writer:        \(self.videoFrames) video frames, \(self.droppedFrames) dropped, \(self.audioBuffers) audio buffers, status \(self.writer.status.rawValue)")
                if self.writer.status == .writing {
                    self.videoInput.markAsFinished()
                    self.audioInput?.markAsFinished()
                    self.writer.finishWriting {
                        if let error = self.writer.error {
                            AppLog.log("Writer error:  \(Self.describe(error))")
                            continuation.resume(returning: .failure(error))
                        } else {
                            continuation.resume(returning: .success(self.outputURL))
                        }
                    }
                } else {
                    let err = self.writer.error ?? NSError(domain: "Mercury", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Writer never started (status \(self.writer.status.rawValue))."])
                    AppLog.log("Writer error:  \(Self.describe(err))")
                    continuation.resume(returning: .failure(err))
                }
            }
        }
    }
}
