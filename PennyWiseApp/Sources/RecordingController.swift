import SwiftUI
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum CaptureSource: String, CaseIterable, Identifiable {
    case display = "Display"
    case window = "Window"
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

    @Published var captureSource: CaptureSource = .display
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
    /// Floating self-view preview (set by AppDelegate).
    weak var cameraPreview: CameraPreviewController?
    private var compositor: VideoCompositor?
    private var mixer: AudioMixer?
    private var writer: MovieWriter?
    private var timer: Timer?
    private var startDate: Date?
    private var activeCompressor: FFmpegCompressor?

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

        do {
            displays = try await ScreenCaptureManager.availableDisplays()
            if selectedDisplayID == nil { selectedDisplayID = displays.first?.displayID }
        } catch {
            status = "Could not list displays. Grant Screen Recording permission."
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
        guard !isRecording else { return }

        // In window mode, make sure we have a window chosen; present the native
        // picker if not (this is the click-to-select flow).
        if captureSource == .window && pickedWindowFilter == nil {
            let chose = await chooseWindow()
            guard chose else { status = "Ready."; return }
        }

        guard Permissions.ensureScreenRecording() else {
            status = "Grant Screen Recording permission, then try again."
            openScreenRecordingSettings()
            return
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

        let width: Int
        let height: Int
        let scale = captureScale.factor
        switch captureSource {
        case .display:
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
            let rect = pickedWindowFilter!.contentRect
            let nativeScale = CGFloat(pickedWindowFilter!.pointPixelScale)
            let maxW = Int((rect.width * nativeScale).rounded())
            let maxH = Int((rect.height * nativeScale).rounded())
            width  = min(maxW, max(2, Int((rect.width * scale).rounded())))
            height = min(maxH, max(2, Int((rect.height * scale).rounded())))
        }

        let url = outputFolder.appendingPathComponent(Self.newFilename())

        do {
            let writer = try MovieWriter(url: url, width: width, height: height, fps: fps, hasAudio: hasAudio)
            writer.prepare()
            self.writer = writer

            let compositor = VideoCompositor(showCamera: useCamera,
                                             background: background,
                                             padding: backgroundPadding)
            compositor.cameraWidthFraction = cameraWidthFraction
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

            let screen = ScreenCaptureManager()
            screen.onVideo = { [weak self] sb in
                guard let self, let compositor = self.compositor, let writer = self.writer else { return }
                guard let src = CMSampleBufferGetImageBuffer(sb) else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let out = compositor.composite(src)
                writer.appendVideo(out, at: pts)
            }
            screen.onSystemAudio = { [weak self] sb in self?.mixer?.append(sb, from: .system) }
            screen.onMic = { [weak self] sb in self?.mixer?.append(sb, from: .mic) }
            screen.onStopped = { [weak self] error in
                Task { @MainActor in self?.handleUnexpectedStop(error) }
            }
            self.screen = screen

            switch captureSource {
            case .display:
                try await screen.start(display: selectedDisplay!, width: width, height: height,
                                       fps: fps,
                                       captureSystemAudio: useSystemAudio,
                                       captureMic: useMic,
                                       micDeviceID: selectedMicID)
            case .window:
                try await screen.start(filter: pickedWindowFilter!, width: width, height: height,
                                       fps: fps,
                                       captureSystemAudio: useSystemAudio,
                                       captureMic: useMic,
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

    func stop() async {
        guard isRecording else { return }
        status = "Finishing…"
        isRecording = false
        timer?.invalidate(); timer = nil

        await screen?.stop()
        // Stop feeding the compositor, but keep the camera session + self-view
        // running if the camera is still enabled.
        cameraManager.onFrame = nil
        if !enableCamera { cameraManager.stop() }
        mixer?.finish()

        let result = await writer?.finish()
        await teardown()

        switch result {
        case .success(let url):
            if compressOutput {
                await compressFile(url)
            } else {
                lastOutputURL = url
                status = "Saved to \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failure(let error):
            status = "Save failed: \(error.localizedDescription)"
        case .none:
            status = "Stopped."
        }
    }

    private func compressFile(_ url: URL) async {
        isCompressing = true
        compressionProgress = 0

        let rawSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        status = "Compressing… 0%"

        let compressor = FFmpegCompressor(quality: compressionQuality, fps: fps)
        self.activeCompressor = compressor
        compressor.onProgress = { [weak self] frac in
            Task { @MainActor in
                self?.compressionProgress = frac
                self?.status = "Compressing… \(Int(frac * 100))%"
            }
        }

        do {
            let output = try await Task.detached {
                try await compressor.compress(url)
            }.value

            let compressedSize = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
            let ratio = rawSize > 0 ? String(format: "%.0f%%", Double(compressedSize) / Double(rawSize) * 100) : "?"
            let sizeMB = String(format: "%.1f MB", Double(compressedSize) / 1_048_576)
            lastOutputURL = output
            status = "Saved \(output.lastPathComponent) — \(sizeMB) (\(ratio) of original)"
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            lastOutputURL = url
            status = "Compression failed: \(error.localizedDescription)"
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

    static func newFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "PennyWise-\(f.string(from: Date())).mp4"
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
