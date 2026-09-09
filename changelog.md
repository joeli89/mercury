# Changelog

All notable changes to PennyWise are documented here. Newest first.

## [Unreleased]

### Changed
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
- Project scaffolding: `PennyWise/` root with `main.md`, `changelog.md`, `memory.md`.
- `PennyWiseApp/` macOS app scaffold (XcodeGen `project.yml`, entitlements, Info.plist).
- v1 recording pipeline (builds & launches):
  - `ScreenCaptureManager` — single `SCStream` for screen video + system audio + microphone.
  - `CameraCaptureManager` — webcam frames via `AVCaptureSession`.
  - `VideoCompositor` — CoreImage webcam bubble overlay (bottom-right, mirrored) onto each screen frame.
  - `AudioMixer` — sums mic + system audio into one 48 kHz stereo track via a latency-buffered timeline.
  - `MovieWriter` — `AVAssetWriter` HEVC/AAC MP4 output.
  - `RecordingController` + SwiftUI `ContentView` — device pickers, toggles, output folder, Start/Stop, elapsed timer.
  - `Permissions` — Screen Recording / Camera / Microphone requests.
