# Changelog

All notable changes to Mercury are documented here. Newest first.

## [Unreleased]

### Added
- **iPhone recording over USB** — new "iPhone" capture source (toolbar button + settings picker). Opts in via CoreMediaIO so a cabled, unlocked, trusted iPhone shows up as a capture device (same mechanism as QuickTime); records the phone's screen at native resolution with phone audio and/or the Mac mic, composited onto the usual 1920×1080 canvas with backgrounds and the webcam bubble. New `PhoneCaptureManager.swift`.
- **Source flyout** — one toolbar button for what to record. Hover it and a glass panel slides out beside the toolbar with Full Screen (per display), Window… and each connected iPhone; the active source is ticked. Replaces the separate Window and iPhone buttons (`SourceFlyoutController.swift`).
- **Live iPhone view** — selecting the iPhone source opens a floating, resizable live view of the phone screen (`PhonePreviewController.swift`), usable for live demos and screen-sharing, not just recording.
- **Canvas follows the source** — the output is 1920 wide for landscape sources and 1080 wide for portrait ones (iPhone), with the height set by the source's own aspect ratio. Background **None** = full width, edge to edge; any background = "hug", a fixed 5% margin around the content. Replaces the Padding S/M/L and Orientation settings. iPhone content gets iPhone-style rounded corners.

### Changed
- **Recording quality, no FFmpeg needed** — the hardware HEVC encoder now runs in constant-quality mode (Apple silicon) with 10 s keyframes and B-frames, replacing the fixed ~3 Mbps stream + x265 pass. Benchmarked on a real screen recording: Balanced (0.65) scores VMAF 94 at ~730 MB/h, better than the old pipeline's 88 at 360 MB/h, with zero wait after stop. Settings: one **Quality** picker (Small / Balanced / High) replaces Frame rate + compression quality; High records at 60 fps. FFmpeg becomes an optional "Extra compression" toggle shown only when it's installed, off by default; when used it now copies audio instead of re-encoding it. Intel Macs fall back to bitrate mode automatically.
- **Renamed PennyWise → Mercury** — app name, target/scheme, `MercuryApp/` folder, entitlements, bundle ID (`com.mercury.Mercury`), log path (`~/Library/Logs/Mercury/`). New bundle ID means Screen Recording / Camera / Mic must be re-granted once.
- **Native window selection** — window capture now uses the system content picker (`SCContentSharingPicker`), so you click the window you want to record with hover highlighting, just like Loom / Screen Studio / macOS sharing. Replaces the buried dropdown.
- Record button now surfaces errors (a small status card appears next to the pill) and, on missing Screen Recording permission, opens the relevant System Settings pane instead of silently doing nothing.
- Pressing record in Window mode with no window chosen now auto-presents the picker.
- **Floating toolbar UI** — replaced the full settings window with a minimalist dark vertical pill that floats above all windows. Record/stop, elapsed timer, window picker, settings (popover), and reveal-last-recording buttons. Draggable, stays on all Spaces.
- Switched video codec from H.264 to HEVC (H.265) for much smaller output files at the same quality.
- Reduced video bitrate formula (`width*height*fps*0.12` → `0.025`) — was producing ~43 Mbps on Retina displays, now ~9 Mbps.
- Default resolution is now 1x (logical) instead of Retina. A "Resolution" picker lets the user opt into full Retina capture when needed.

### Added
- **Backgrounds (Screen Studio-style)** — composite the recording onto a solid, gradient, or custom-image background, with the screen inset behind rounded corners and a drop shadow. Preset swatch grid + S/M/L padding + "Image…" picker in the settings. New `Background.swift`; `VideoCompositor` rewritten to render background → shadow → rounded screen → camera bubble (static layers cached for performance).
- `WindowPicker` — async wrapper around `SCContentSharingPicker` for native click-to-select window capture.
- `FloatingPanel` — borderless `NSPanel` subclass (always-on-top, non-activating, joins all Spaces).
- `ToolbarView` — SwiftUI vertical toolbar hosted inside the floating panel.
- Window capture mode — choose between recording a full display or a single window via a "Capture" segmented picker.
- Resolution picker in the Output section (1x / Retina).
- Project scaffolding: `Mercury/` root with `main.md`, `changelog.md`, `memory.md`.
- `MercuryApp/` macOS app scaffold (XcodeGen `project.yml`, entitlements, Info.plist).
- v1 recording pipeline (builds & launches):
  - `ScreenCaptureManager` — single `SCStream` for screen video + system audio + microphone.
  - `CameraCaptureManager` — webcam frames via `AVCaptureSession`.
  - `VideoCompositor` — CoreImage webcam bubble overlay (bottom-right, mirrored) onto each screen frame.
  - `AudioMixer` — sums mic + system audio into one 48 kHz stereo track via a latency-buffered timeline.
  - `MovieWriter` — `AVAssetWriter` HEVC/AAC MP4 output.
  - `RecordingController` + SwiftUI `ContentView` — device pickers, toggles, output folder, Start/Stop, elapsed timer.
  - `Permissions` — Screen Recording / Camera / Microphone requests.
