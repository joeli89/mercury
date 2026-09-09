import AVFoundation
import CoreVideo

/// Wraps an AVAssetWriter with one video track (from a pixel-buffer adaptor)
/// and, optionally, one audio track. All mutation happens on a private serial
/// queue so it is safe to call from the capture callbacks.
final class MovieWriter {
    private let queue = DispatchQueue(label: "com.pennywise.moviewriter")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var startPTS: CMTime = .zero
    private(set) var finished = false

    let outputURL: URL

    init(url: URL, width: Int, height: Int, fps: Int, hasAudio: Bool) throws {
        outputURL = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(width * height) * Double(fps) * 0.025),
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
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
            guard !self.finished, self.writer.status == .writing else { return }
            if !self.sessionStarted {
                self.writer.startSession(atSourceTime: pts)
                self.startPTS = pts
                self.sessionStarted = true
            }
            if self.videoInput.isReadyForMoreMediaData {
                self.adaptor.append(pixelBuffer, withPresentationTime: pts)
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
                audioInput.append(sampleBuffer)
            }
        }
    }

    func finish() async -> Result<URL, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, Error>, Never>) in
            queue.async {
                guard !self.finished else {
                    continuation.resume(returning: .success(self.outputURL)); return
                }
                self.finished = true
                if self.writer.status == .writing {
                    self.videoInput.markAsFinished()
                    self.audioInput?.markAsFinished()
                    self.writer.finishWriting {
                        if let error = self.writer.error {
                            continuation.resume(returning: .failure(error))
                        } else {
                            continuation.resume(returning: .success(self.outputURL))
                        }
                    }
                } else {
                    let err = self.writer.error ?? NSError(domain: "PennyWise", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Writer never started (status \(self.writer.status.rawValue))."])
                    continuation.resume(returning: .failure(err))
                }
            }
        }
    }
}
