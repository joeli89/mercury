import AVFoundation
import CoreMediaIO

/// Captures a USB-connected iPhone/iPad screen (plus its audio) the way
/// QuickTime does. macOS hides these devices until the process opts in via
/// CoreMediaIO; after that the phone appears as an `AVCaptureDevice` with
/// muxed (video + audio) media and behaves like any other capture device.
///
/// The Mac microphone can be added to the same session; macOS mixes all audio
/// inputs into the single audio data output, so the mixer sees one stream.
final class PhoneCaptureManager: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoQueue = DispatchQueue(label: "com.mercury.phone.video")
    private let audioQueue = DispatchQueue(label: "com.mercury.phone.audio")

    var onVideo: ((CMSampleBuffer) -> Void)?
    /// Every video frame, for the live preview (independent of recording).
    var onPreviewFrame: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// A device was plugged in / unplugged (delivered on the main queue).
    var onDevicesChanged: (() -> Void)?
    /// The device being recorded was unplugged (main queue).
    var onDisconnected: (() -> Void)?

    private(set) var isRunning = false
    private(set) var currentDeviceID: String?
    private var observers: [NSObjectProtocol] = []
    private static var optedIn = false

    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] _ in
            self?.onDevicesChanged?()
        })
        observers.append(nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if self.isRunning, let device = note.object as? AVCaptureDevice, device.uniqueID == self.currentDeviceID {
                self.onDisconnected?()
            }
            self.onDevicesChanged?()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Discovery

    /// Ask CoreMediaIO to expose USB-connected iOS devices as capture devices.
    /// Devices take a few seconds to appear afterwards. Setting the property
    /// repeatedly can stop devices appearing, so it's only ever set once.
    static func enableScreenCaptureDevices() {
        guard !optedIn else { return }
        optedIn = true
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &allow)
        AppLog.log("iPhone capture: CoreMediaIO opt-in status \(status)")
        // Connection notifications only start arriving after a first enumeration.
        _ = availablePhones()
    }

    static func availablePhones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed,
                                         position: .unspecified).devices
    }

    // MARK: - Capture

    /// Starts capturing the phone's screen. `includePhoneAudio` records what the
    /// phone is playing; `includeMic` adds the Mac microphone to the same mix.
    /// Safe to call while already running: the session is reconfigured in
    /// place (e.g. to add/remove audio when a recording starts/stops) so a
    /// preview layer attached to `session` keeps showing frames.
    func start(deviceID: String?, includePhoneAudio: Bool, includeMic: Bool, micDeviceID: String?) throws {

        let phone: AVCaptureDevice?
        if let deviceID, let d = AVCaptureDevice(uniqueID: deviceID) {
            phone = d
        } else {
            phone = Self.availablePhones().first
        }
        guard let phone else {
            throw NSError(domain: "Mercury", code: -20, userInfo: [NSLocalizedDescriptionKey:
                "No iPhone found. Connect it with a cable, unlock it, and tap Trust."])
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let phoneInput: AVCaptureDeviceInput
        let existing = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.uniqueID == phone.uniqueID }
        if isRunning, let existing {
            // Same phone already streaming (live view): keep its input and the
            // video output untouched so the preview layer's connection survives,
            // and only rebuild the audio wiring.
            phoneInput = existing
            for input in session.inputs where input !== existing { session.removeInput(input) }
            if session.outputs.contains(where: { $0 === audioOutput }) { session.removeOutput(audioOutput) }
        } else {
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }

            phoneInput = try AVCaptureDeviceInput(device: phone)
            guard session.canAddInput(phoneInput) else {
                throw NSError(domain: "Mercury", code: -21, userInfo: [NSLocalizedDescriptionKey:
                    "Couldn't open \(phone.localizedName). Unlock the phone and try again."])
            }
            session.addInput(phoneInput)

            // Video: auto-connects to the phone's video port.
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }

        // Audio: connect only the ports we want (phone audio and/or Mac mic).
        var audioPorts: [AVCaptureInput.Port] = []
        if includePhoneAudio {
            audioPorts += phoneInput.ports.filter { $0.mediaType == .audio }
        }
        if includeMic {
            let mic = micDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
            if let mic, let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
                session.addInput(micInput)
                audioPorts += micInput.ports.filter { $0.mediaType == .audio }
            }
        }
        if !audioPorts.isEmpty {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            session.addOutputWithNoConnections(audioOutput)
            let connection = AVCaptureConnection(inputPorts: audioPorts, output: audioOutput)
            if session.canAddConnection(connection) { session.addConnection(connection) }
        }

        currentDeviceID = phone.uniqueID
        isRunning = true
        AppLog.log("iPhone capture: \(phone.localizedName) video\(includePhoneAudio ? " + phone audio" : "")\(includeMic ? " + mic" : "") (audio ports: \(audioPorts.count))")
        videoQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        currentDeviceID = nil
        onVideo = nil
        onAudio = nil
        videoQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Sample delivery (video + audio share this delegate method)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            onPreviewFrame?(sampleBuffer)
            onVideo?(sampleBuffer)
        } else if output === audioOutput {
            onAudio?(sampleBuffer)
        }
    }
}
