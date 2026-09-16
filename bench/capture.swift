// Records the main display to ProRes 422 HQ at 1920x1080 via ScreenCaptureKit
// (same capture path as Mercury). Used as the lossless-ish benchmark reference.
// Usage: swift bench/capture.swift <out.mov> <seconds>
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[2]) else {
    print("usage: swift capture.swift <out.mov> <seconds>"); exit(2)
}
let outURL = URL(fileURLWithPath: args[1])
let W = 1920, H = 1080, FPS = 60

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private var started = false
    private(set) var frames = 0

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: W,
            AVVideoHeightKey: H
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, CMSampleBufferGetImageBuffer(sb) != nil else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int,
           SCFrameStatus(rawValue: raw) != .complete {
            return
        }
        if !started {
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData, input.append(sb) { frames += 1 }
    }
}

do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let mainID = CGMainDisplayID()
    guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
        print("No display found."); exit(1)
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.width = W
    cfg.height = H
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(FPS))
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = true
    cfg.queueDepth = 8

    let recorder = try Recorder(url: outURL)
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "bench.capture"))
    try await stream.startCapture()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    try await stream.stopCapture()
    recorder.input.markAsFinished()
    await recorder.writer.finishWriting()
    if let err = recorder.writer.error { print("Writer error: \(err.localizedDescription)"); exit(1) }
    print("Captured \(recorder.frames) frames → \(outURL.path)")
    if recorder.frames == 0 { print("No frames — check Screen Recording permission for Terminal."); exit(1) }
} catch {
    print("Capture failed: \(error.localizedDescription)")
    print("If this is a permission error: System Settings → Privacy & Security → Screen Recording → enable Terminal, then restart Terminal.")
    exit(1)
}
