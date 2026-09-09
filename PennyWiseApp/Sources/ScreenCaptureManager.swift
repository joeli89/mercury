import ScreenCaptureKit
import AVFoundation

/// Drives a single SCStream that delivers screen video, system audio, and the
/// microphone, forwarding each to the supplied callbacks.
final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "com.pennywise.capture.video")
    private let audioQueue = DispatchQueue(label: "com.pennywise.capture.audio")

    var onVideo: ((CMSampleBuffer) -> Void)?
    var onSystemAudio: ((CMSampleBuffer) -> Void)?
    var onMic: ((CMSampleBuffer) -> Void)?
    var onStopped: ((Error) -> Void)?

    static func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays
    }

    func start(display: SCDisplay,
               width: Int,
               height: Int,
               fps: Int,
               captureSystemAudio: Bool,
               captureMic: Bool,
               micDeviceID: String?) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        try await startCapture(filter: filter, width: width, height: height, fps: fps,
                               captureSystemAudio: captureSystemAudio, captureMic: captureMic,
                               micDeviceID: micDeviceID)
    }

    /// Start capture from a filter produced by the system content picker
    /// (`SCContentSharingPicker`), e.g. a single window the user clicked.
    func start(filter: SCContentFilter,
               width: Int,
               height: Int,
               fps: Int,
               captureSystemAudio: Bool,
               captureMic: Bool,
               micDeviceID: String?) async throws {
        try await startCapture(filter: filter, width: width, height: height, fps: fps,
                               captureSystemAudio: captureSystemAudio, captureMic: captureMic,
                               micDeviceID: micDeviceID)
    }

    private func startCapture(filter: SCContentFilter,
                              width: Int,
                              height: Int,
                              fps: Int,
                              captureSystemAudio: Bool,
                              captureMic: Bool,
                              micDeviceID: String?) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = true

        if captureSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
        }
        if captureMic {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = micDeviceID
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if captureMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil, isComplete(sampleBuffer) else { return }
            onVideo?(sampleBuffer)
        case .audio:
            onSystemAudio?(sampleBuffer)
        case .microphone:
            onMic?(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return true }
        return status == .complete
    }
}
