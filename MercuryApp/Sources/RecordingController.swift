import SwiftUI
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum CaptureSource: String, CaseIterable, Identifiable {
    case display = "Display"
    case window = "Window"
    case phone = "iPhone"
    var id: String { rawValue }
}

/// Output canvas orientation. Auto = portrait for iPhone, landscape otherwise.
enum OutputOrientation: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case landscape = "Landscape"
    case portrait = "Portrait"
    var id: String { rawValue }
}

enum CaptureScale: String, CaseIterable, Identifiable {
    case one     = "1x"
    case oneHalf = "1.5x"
    case two     = "2x"

    var id: String { rawValue }
    var factor: CGFloat {
        switch self {
        case .one:     return 1.0
        case .oneHalf: return 1.5
        case .two:     return 2.0
        }
    }
}

@MainActor
final class RecordingController: ObservableObject {
    // Device / config state
    @Published var displays: [SCDisplay] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    /// USB-connected iPhones/iPads (exposed via CoreMediaIO, see PhoneCaptureManager).
    @Published var phones: [AVCaptureDevice] = []
    @Published var selectedPhoneID: String? { didSet { if selectedPhoneID != oldValue { Task { await syncPhonePreview() } } } }

    @Published var captureSource: CaptureSource = .display { didSet { if captureSource != oldValue { Task { await syncPhonePreview() } } } }
    @Published var outputOrientation: OutputOrientation = .auto
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedCameraID: String? { didSet { if selectedCameraID != oldValue { Task { await syncCameraPreview() } } } }
    @Published var selectedMicID: String?

    // Window selection (via the native system picker).
    private var pickedWindowFilter: SCContentFilter?
    @Published var pickedWindowName: String?

    /// Camera is off by default — turning it on shows a live self-view so the
    /// user can see they're being filmed (Loom-style).
    @Published var enableCamera = false { didSet { if enableCamera != oldValue { Task { await syncCameraPreview() } } } }
    @Published var enableSystemAudio = true
    @Published var enableMicrophone = true
    /// Fraction of the frame width used for the camera bubble (0.10 = S, 0.13 = M, 0.20 = L).
    @Published var cameraWidthFraction: CGFloat = 0.13

    @Published var fps = 60
    @Published var captureScale: CaptureScale = .oneHalf

    // FFmpeg post-compression
    @Published var compressOutput = true
    @Published var compressionQuality: FFmpegCompressor.Quality = .medium
    @Published var isCompressing = false
    @Published var compressionProgress: Double = 0

    // Background compositing (Screen Studio-style)
    @Published var background: BackgroundOption = BackgroundOption.presets[4]  // Mint
    @Published var backgroundPadding: BackgroundPadding = .medium
    @Published var outputFolder: URL = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser

    // Runtime state
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var status = "Ready."
    @Published var lastOutputURL: URL?

    private var screen: ScreenCaptureManager?
    /// Persistent camera session — runs whenever the camera is enabled (for the
    /// live preview) and also feeds the compositor while recording.
    private let cameraManager = CameraCaptureManager()
    /// USB iPhone screen capture (only runs while recording in iPhone mode).
    private let phoneManager = PhoneCaptureManager()
    /// Floating self-view preview (set by AppDelegate).
    weak var cameraPreview: CameraPreviewController?
    /// Floating live view of the iPhone screen (set by AppDelegate).
    weak var phonePreview: PhonePreviewController?
    private var compositor: VideoCompositor?
    private var mixer: AudioMixer?
    private var writer: MovieWriter?
    private var timer: Timer?
    private var startDate: Date?
    private var activeCompressor: FFmpegCompressor?
    /// Where the finished file should end up (compression may route through temp).
    private var pendingFinalURL: URL?
    private let countdown = CountdownController()

    /// True while the 3-2-1 countdown is showing (before capture begins).
    @Published var isCountingDown = false

    init() {
        phoneManager.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.refreshPhones() }
        }
        phoneManager.onDisconnected = { [weak self] in
            Task { @MainActor in
                self?.handleUnexpectedStop(NSError(domain: "Mercury", code: -22,
                    userInfo: [NSLocalizedDescriptionKey: "iPhone was disconnected."]))
            }
        }
    }

    var selectedPhone: AVCaptureDevice? {
        phones.first { $0.uniqueID == selectedPhoneID }
    }

    /// The canvas the recording is rendered onto.
    var canvasSize: (width: Int, height: Int) {
        let portrait: Bool
        switch outputOrientation {
        case .auto:      portrait = captureSource == .phone
        case .landscape: portrait = false
        case .portrait:  portrait = true
        }
        return portrait
            ? (VideoCompositor.defaultCanvasHeight, VideoCompositor.defaultCanvasWidth)
            : (VideoCompositor.defaultCanvasWidth, VideoCompositor.defaultCanvasHeight)
    }

    // MARK: - Device discovery

    func refreshDevices() async {
        Permissions.ensureScreenRecording()
        _ = await Permissions.ensureCamera()
        _ = await Permissions.ensureMicrophone()

        cameras = CameraCaptureManager.availableCameras()
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices

        if selectedCameraID == nil { selectedCameraID = cameras.first?.uniqueID }
        if selectedMicID == nil { selectedMicID = microphones.first?.uniqueID }

        PhoneCaptureManager.enableScreenCaptureDevices()
        refreshPhones()
        // Phones take a few seconds to show up after the CoreMediaIO opt-in.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.refreshPhones()
        }

        do {
            displays = try await ScreenCaptureManager.availableDisplays()
            if selectedDisplayID == nil { selectedDisplayID = displays.first?.displayID }
        } catch {
            status = "Could not list displays. Grant Screen Recording permission."
        }
    }

    /// Re-list connected phones and keep the selection valid.
    func refreshPhones() {
        phones = PhoneCaptureManager.availablePhones()
        if selectedPhone == nil { selectedPhoneID = phones.first?.uniqueID }
    }

    /// Toolbar action: switch to iPhone capture (or back to the display).
    func togglePhoneSource() {
        if captureSource == .phone {
            captureSource = .display
            status = "Ready."
            return
        }
        refreshPhones()
        captureSource = .phone
        if let phone = selectedPhone {
            status = "Ready — \(phone.localizedName) selected."
        } else {
            status = "No iPhone found. Connect it with a cable, unlock it, and tap Trust."
        }
    }

    // MARK: - iPhone preview

    /// Runs the phone session (video only) and shows the floating live view
    /// whenever the iPhone source is selected; tears it down otherwise.
    /// Not called while recording — `stop()` re-syncs afterwards.
    func syncPhonePreview() async {
        guard !isRecording else { return }
        guard captureSource == .phone, let phone = selectedPhone else {
            phonePreview?.hide()
            phoneManager.stop()
            return
        }
        guard await Permissions.ensureCamera() else {
            status = "Grant Camera permission to capture the iPhone."
            return
        }
        do {
            try phoneManager.start(deviceID: phone.uniqueID, includePhoneAudio: false,
                                   includeMic: false, micDeviceID: nil)
            phonePreview?.show(manager: phoneManager)
        } catch {
            status = "iPhone error: \(error.localizedDescription)"
        }
    }

    // MARK: - Camera preview

    /// Starts/stops the persistent camera session + floating self-view to match
    /// `enableCamera`. Called whenever the toggle or selected device changes.
    func syncCameraPreview() async {
        guard enableCamera, !cameras.isEmpty else {
            cameraPreview?.hide()
            // Keep the session alive while recording even if toggled — but
            // toggling off during recording isn't allowed (UI is disabled), so
            // it's safe to stop here.
            if !isRecording { cameraManager.stop() }
            return
        }

        guard await Permissions.ensureCamera() else {
            enableCamera = false
            status = "Grant Camera permission to use the webcam."
            return
        }

        do {
            try cameraManager.start(deviceID: selectedCameraID)
            cameraPreview?.show(session: cameraManager.session)
        } catch {
            status = "Camera error: \(error.localizedDescription)"
            enableCamera = false
        }
    }

    // MARK: - Window picker

    /// Presents the native system picker so the user can click the window to
    /// record (Loom / Screen Studio-style). Returns true if a window was chosen.
    @discardableResult
    func chooseWindow() async -> Bool {
        let picker = WindowPicker()
        guard let filter = await picker.pickWindow() else { return false }
        pickedWindowFilter = filter
        pickedWindowName = WindowPicker.displayName(for: filter)
        captureSource = .window
        status = "Ready — \(pickedWindowName ?? "window") selected."
        return true
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Recording

    func start() async {
        guard !isRecording, !isCountingDown else { return }

        // In window mode, make sure we have a window chosen; present the native
        // picker if not (this is the click-to-select flow).
        if captureSource == .window && pickedWindowFilter == nil {
            let chose = await chooseWindow()
            guard chose else { status = "Ready."; return }
        }

        if captureSource == .phone {
            refreshPhones()
            guard selectedPhone != nil else {
                status = "No iPhone found. Connect it with a cable, unlock it, and tap Trust."
                return
            }
            // USB device capture goes through AVFoundation, which is gated by
            // the Camera permission rather than Screen Recording.
            _ = await Permissions.ensureCamera()
        } else {
            guard Permissions.ensureScreenRecording() else {
                status = "Grant Screen Recording permission, then try again."
                openScreenRecordingSettings()
                return
            }
        }

        let selectedDisplay = displays.first(where: { $0.displayID == selectedDisplayID }) ?? displays.first
        if captureSource == .display && selectedDisplay == nil {
            status = "No display available."
            return
        }

        let useCamera = enableCamera && !cameras.isEmpty
        let useMic = enableMicrophone
        let useSystemAudio = enableSystemAudio
        let hasAudio = useMic || useSystemAudio

        if useCamera { _ = await Permissions.ensureCamera() }
        if useMic { _ = await Permissions.ensureMicrophone() }

        var width: Int
        var height: Int
        switch captureSource {
        case .display:
            let scale = captureScale.factor
            let display = selectedDisplay!
            let logicalW = CGFloat(display.width)
            let logicalH = CGFloat(display.height)
            // Clamp to native pixel dimensions so we never upscale.
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let maxW = mode?.pixelWidth ?? display.width
            let maxH = mode?.pixelHeight ?? display.height
            width  = min(maxW, max(2, Int((logicalW * scale).rounded())))
            height = min(maxH, max(2, Int((logicalH * scale).rounded())))
        case .window:
            // Capture at the window's logical dimensions (1× points).
            // SCStream reliably fills the buffer at this size, regardless
            // of the display's pixel density. Asking for non-native sizes
            // (e.g. 2× on a 1× display) can leave empty padding in the
            // buffer, causing the content to appear off-center on the
            // fixed 1920×1080 canvas. Quality is excellent: a typical
            // wide window (~3400 pts) provides ~2× supersampling.
            let rect = pickedWindowFilter!.contentRect
            width  = max(2, Int(rect.width.rounded()))
            height = max(2, Int(rect.height.rounded()))
        case .phone:
            // The phone streams at its native resolution; we learn the size
            // from the first frame (logged below).
            width = 0
            height = 0
        }

        // Loom-style 3-2-1 countdown before capture begins (so it isn't
        // recorded). Bail out if the user isn't recording anymore.
        isCountingDown = true
        status = "Get ready…"
        await countdown.run(from: 3)
        isCountingDown = false

        // When compressing, record the raw file to a temp location so the
        // output folder only ever contains the finished (compressed) file.
        let filename = Self.newFilename()
        let finalURL = outputFolder.appendingPathComponent(filename)
        let url = compressOutput
            ? FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            : finalURL
        pendingFinalURL = finalURL

        // ── Log the recording settings ────────────────────────────────────
        let sourceDesc: String
        switch captureSource {
        case .display:
            sourceDesc = "Display \(selectedDisplay!.displayID) (\(selectedDisplay!.width)×\(selectedDisplay!.height))"
        case .window:
            sourceDesc = "Window \"\(pickedWindowName ?? "?")\""
        case .phone:
            sourceDesc = "iPhone \"\(selectedPhone?.localizedName ?? "?")\" (USB)"
        }
        let captureDesc = captureSource == .phone
            ? "native phone resolution @ device rate"
            : "\(width)×\(height) @ \(fps)fps  (scale \(captureScale.rawValue))"
        AppLog.log("""

        ════════ Mercury recording ════════
        \(AppLog.timestamp())
        File:          \(url.lastPathComponent)
        Source:        \(sourceDesc)
        Capture:       \(captureDesc)
        Output:        \(canvasSize.width)×\(canvasSize.height) (\(outputOrientation.rawValue))
        Camera:        \(useCamera ? "on (size \(String(format: "%.2f", cameraWidthFraction)))" : "off")
        Microphone:    \(useMic ? "on" : "off")
        \(captureSource == .phone ? "iPhone audio: " : "System audio: ") \(useSystemAudio ? "on" : "off")
        Background:    \(background.name) (padding \(backgroundPadding.rawValue))
        Compression:   \(compressOutput ? compressionQuality.rawValue : "off")
        """)

        do {
            let canvas = canvasSize
            let writer = try MovieWriter(url: url,
                                       width: canvas.width,
                                       height: canvas.height,
                                       fps: fps, hasAudio: hasAudio)
            writer.prepare()
            self.writer = writer

            let compositor = VideoCompositor(showCamera: useCamera,
                                             background: background,
                                             padding: backgroundPadding,
                                             canvasWidth: canvas.width,
                                             canvasHeight: canvas.height)
            compositor.cameraWidthFraction = cameraWidthFraction
            if captureSource == .phone { compositor.contentCornerFraction = 0.12 }
            self.compositor = compositor

            if hasAudio {
                let mixer = AudioMixer { [weak writer] sb in writer?.appendAudio(sb) }
                self.mixer = mixer
            }

            if useCamera {
                // Camera session is already running for the live preview; just
                // route its frames into the compositor for the duration.
                try cameraManager.start(deviceID: selectedCameraID)
                cameraManager.onFrame = { [weak compositor] px in
                    compositor?.updateCamera(px)
                }
            }

            let videoSink: (CMSampleBuffer) -> Void = { [weak self] sb in
                guard let self, let compositor = self.compositor, let writer = self.writer else { return }
                guard let src = CMSampleBufferGetImageBuffer(sb) else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let out = compositor.composite(src)
                writer.appendVideo(out, at: pts)
            }

            switch captureSource {
            case .display, .window:
                let screen = ScreenCaptureManager()
                screen.onVideo = videoSink
                screen.onSystemAudio = { [weak self] sb in self?.mixer?.append(sb, from: .system) }
                screen.onMic = { [weak self] sb in self?.mixer?.append(sb, from: .mic) }
                screen.onStopped = { [weak self] error in
                    Task { @MainActor in self?.handleUnexpectedStop(error) }
                }
                self.screen = screen

                if captureSource == .display {
                    try await screen.start(display: selectedDisplay!, width: width, height: height,
                                           fps: fps,
                                           captureSystemAudio: useSystemAudio,
                                           captureMic: useMic,
                                           micDeviceID: selectedMicID)
                } else {
                    try await screen.start(filter: pickedWindowFilter!, width: width, height: height,
                                           fps: fps,
                                           captureSystemAudio: useSystemAudio,
                                           captureMic: useMic,
                                           micDeviceID: selectedMicID)
                }

            case .phone:
                var loggedFormat = false
                phoneManager.onVideo = { sb in
                    if !loggedFormat, let px = CMSampleBufferGetImageBuffer(sb) {
                        loggedFormat = true
                        AppLog.log("iPhone frame:  \(CVPixelBufferGetWidth(px))×\(CVPixelBufferGetHeight(px))")
                    }
                    videoSink(sb)
                }
                // The phone session delivers phone audio + mic already mixed.
                phoneManager.onAudio = { [weak self] sb in self?.mixer?.append(sb, from: .system) }
                try phoneManager.start(deviceID: selectedPhoneID,
                                       includePhoneAudio: useSystemAudio,
                                       includeMic: useMic,
                                       micDeviceID: selectedMicID)
            }

            isRecording = true
            startDate = Date()
            elapsed = 0
            status = "Recording…"
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
        } catch {
            status = "Failed to start: \(error.localizedDescription)"
            await teardown()
        }
    }

    /// Stop capture and discard the recording without saving or compressing.
    func cancel() async {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate(); timer = nil

        await screen?.stop()
        phoneManager.onVideo = nil
        phoneManager.onAudio = nil
        cameraManager.onFrame = nil
        if !enableCamera { cameraManager.stop() }
        mixer?.finish()

        // Abort the writer and delete its file (temp or output).
        await writer?.cancel()
        await teardown()

        status = "Recording discarded."
        AppLog.log("Discarded:     recording cancelled by user\n═════════════════════════════════════")
        await syncPhonePreview()
    }

    func stop() async {
        guard isRecording else { return }
        status = "Finishing…"
        isRecording = false
        timer?.invalidate(); timer = nil

        await screen?.stop()
        phoneManager.onVideo = nil
        phoneManager.onAudio = nil
        // Stop feeding the compositor, but keep the camera session + self-view
        // running if the camera is still enabled.
        cameraManager.onFrame = nil
        if !enableCamera { cameraManager.stop() }
        mixer?.finish()

        let result = await writer?.finish()
        await teardown()
        await syncPhonePreview()   // drop the mic from the phone session, keep the live view

        switch result {
        case .success(let url):
            let rawSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            AppLog.log("Raw file:      \(AppLog.size(rawSize)) written")
            let finalURL = pendingFinalURL ?? url
            if compressOutput {
                await compressFile(url, to: finalURL, rawSize: rawSize)
            } else {
                lastOutputURL = url
                status = "Saved to \(url.lastPathComponent)"
                AppLog.log("Compression:   off — final \(AppLog.size(rawSize))\n═════════════════════════════════════")
                Self.revealInFinder(url)
            }
        case .failure(let error):
            status = "Save failed: \(error.localizedDescription)"
            AppLog.log("Save FAILED:    \(error.localizedDescription)\n═════════════════════════════════════")
        case .none:
            status = "Stopped."
        }
    }

    private func compressFile(_ input: URL, to output: URL, rawSize: Int) async {
        isCompressing = true
        compressionProgress = 0
        status = "Compressing… 0%"

        let compressor = FFmpegCompressor(quality: compressionQuality, fps: fps)
        self.activeCompressor = compressor
        compressor.onProgress = { [weak self] frac in
            Task { @MainActor in
                self?.compressionProgress = frac
                self?.status = "Compressing… \(Int(frac * 100))%"
            }
        }
        AppLog.log("Encoder:       \(compressor.settingsSummary)")

        let t0 = Date()
        do {
            let result = try await Task.detached {
                try await compressor.compress(input, to: output)
            }.value

            // Remove the temp raw file (if it was routed through temp).
            if input != output { try? FileManager.default.removeItem(at: input) }

            let encodeSeconds = Date().timeIntervalSince(t0)
            let compressedSize = (try? FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int) ?? 0
            let ratioPct = rawSize > 0 ? Double(compressedSize) / Double(rawSize) * 100 : 0
            let saved = max(0, rawSize - compressedSize)
            lastOutputURL = result
            status = "Saved \(result.lastPathComponent) — \(AppLog.size(compressedSize)) (\(String(format: "%.0f%%", ratioPct)) of original)"
            AppLog.log("""
            Compressed:    \(AppLog.size(compressedSize)) (\(String(format: "%.1f%%", ratioPct)) of raw, saved \(AppLog.size(saved)))
            Encode time:   \(String(format: "%.1fs", encodeSeconds))
            ═════════════════════════════════════
            """)
            Self.revealInFinder(result)
        } catch {
            // On failure, salvage the raw recording by moving it to the output.
            if input != output { try? FileManager.default.moveItem(at: input, to: output) }
            lastOutputURL = FileManager.default.fileExists(atPath: output.path) ? output : input
            status = "Compression failed (kept raw): \(error.localizedDescription)"
            AppLog.log("Compression FAILED: \(error.localizedDescription)\n═════════════════════════════════════")
        }

        activeCompressor = nil
        isCompressing = false
        compressionProgress = 0
    }

    private func handleUnexpectedStop(_ error: Error) {
        guard isRecording else { return }
        status = "Capture stopped: \(error.localizedDescription)"
        Task { await stop() }
    }

    private func teardown() async {
        screen = nil; compositor = nil; mixer = nil; writer = nil
        startDate = nil
    }

    // MARK: - Helpers

    /// Reveal the most recent recording in Finder (or the output folder if the
    /// file is gone / not yet recorded).
    func revealLastRecording() {
        if let url = lastOutputURL, FileManager.default.fileExists(atPath: url.path) {
            Self.revealInFinder(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
            if let finder = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder").first {
                finder.activate(options: [.activateAllWindows])
            }
        }
    }

    /// Reveal a file in Finder and bring Finder to the front. `activateFileViewerSelecting`
    /// alone can leave the Finder window behind since Mercury is a
    /// non-activating panel app, so we explicitly activate Finder too.
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder").first {
            finder.activate(options: [.activateAllWindows])
        }
    }

    static func newFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Mercury-\(f.string(from: Date())).mp4"
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            background = .custom(url)
        }
    }

    var elapsedString: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
