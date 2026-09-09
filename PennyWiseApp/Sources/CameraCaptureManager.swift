import AVFoundation

/// Captures webcam frames. The session can run continuously (to drive a live
/// self-view preview) while `onFrame` is only wired to the compositor during
/// recording. The same session also backs an `AVCaptureVideoPreviewLayer`.
final class CameraCaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.pennywise.camera")

    /// Frame sink — set by the recorder while recording, cleared otherwise.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private(set) var isRunning = false
    private var currentDeviceID: String?

    static func availableCameras() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    /// Starts (or restarts, if the device changed) the capture session.
    func start(deviceID: String?) throws {
        // Already running the requested device — nothing to do.
        if isRunning && deviceID == currentDeviceID { return }
        if isRunning { stop() }

        let device: AVCaptureDevice?
        if let deviceID, let d = AVCaptureDevice(uniqueID: deviceID) {
            device = d
        } else {
            device = Self.availableCameras().first ?? AVCaptureDevice.default(for: .video)
        }
        guard let device else { throw NSError(domain: "PennyWise", code: -10,
            userInfo: [NSLocalizedDescriptionKey: "No camera available."]) }

        session.beginConfiguration()
        session.sessionPreset = .high
        // Remove any prior inputs (device switch).
        for input in session.inputs { session.removeInput(input) }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }

        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()

        currentDeviceID = deviceID
        isRunning = true
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        isRunning = false
        currentDeviceID = nil
        onFrame = nil
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(px)
    }
}
