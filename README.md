# PennyWise

A simple, fully-local macOS screen recorder. Capture your screen (or a single
window) with an optional webcam bubble, microphone narration, and system audio,
then get a clean, compressed MP4 out. Nothing touches the cloud — recordings are
written straight to a folder you choose.

Think of it as a lightweight, local-first alternative to Screen Studio for demos
and screen recordings, with Screen Studio-style backgrounds and padding.

---

## Requirements

| Tool | Version | Notes |
|------|---------|-------|
| macOS | **15.0+** | Developed and tested on macOS 26 (Tahoe). Liquid Glass toolbar chrome only appears on macOS 26+. |
| Xcode | **16+** | 26.x recommended. Ships the Swift toolchain and the macOS 15+ SDK. |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | latest | The `.xcodeproj` is **generated** from `project.yml`, not hand-edited. |
| [FFmpeg](https://ffmpeg.org/) | latest | Runtime dependency for post-recording HEVC compression. |
| An Apple Developer account | — | Any free or paid team works; you'll set your own signing team (see below). |

Install the CLI dependencies with Homebrew:

```bash
brew install xcodegen ffmpeg
```

FFmpeg is discovered at runtime from `/opt/homebrew/bin/ffmpeg` or
`/usr/local/bin/ffmpeg` (falling back to `$PATH`). If it's missing, recording
still works but the final compression step is skipped.

---

## Setup & run

```bash
git clone <this-repo>
cd PennyWise/PennyWiseApp

# 1. Point signing at YOUR team (see "Code signing" below), then:
xcodegen generate        # produces PennyWise.xcodeproj from project.yml
open PennyWise.xcodeproj

# 2. In Xcode: select the "PennyWise" scheme and Build & Run (⌘R)
```

Or build entirely from the command line:

```bash
cd PennyWiseApp
xcodegen generate
xcodebuild -project PennyWise.xcodeproj -scheme PennyWise -configuration Debug build
# The .app is under ~/Library/Developer/Xcode/DerivedData/PennyWise-*/Build/Products/Debug/
```

The app has **no main window** — it launches as a floating vertical toolbar
placed on the screen where your mouse currently is.

### Code signing

`project.yml` pins a specific signing team so that macOS privacy grants persist
across rebuilds:

```yaml
DEVELOPMENT_TEAM: "43HHN9A4KG"   # <-- change this to YOUR team ID
CODE_SIGN_STYLE: Manual
CODE_SIGN_IDENTITY: "Apple Development"
```

Before generating the project, replace `DEVELOPMENT_TEAM` with your own team ID
(Xcode → Settings → Accounts, or `security find-identity -v -p codesigning`),
then re-run `xcodegen generate`.

> **Why a stable identity matters:** ad-hoc signing changes the binary's cdhash
> on every rebuild, which silently invalidates the Screen Recording / Camera /
> Mic TCC grants — the toggle shows "on" in System Settings but
> `CGPreflightScreenCaptureAccess()` returns false. A stable Apple Development
> identity keeps the grants sticking across rebuilds.

### First-run permissions

On first launch, grant these in **System Settings → Privacy & Security**:

- **Screen Recording** (required)
- **Camera** (only if you use the webcam bubble)
- **Microphone** (only if you record narration)

macOS reads the Screen Recording grant **at launch only** — after granting,
quit and relaunch the app.

If permissions get stuck, reset them and relaunch:

```bash
tccutil reset ScreenCapture com.pennywise.PennyWise
tccutil reset Camera        com.pennywise.PennyWise
tccutil reset Microphone    com.pennywise.PennyWise
```

---

## How it works

| Concern | Implementation |
|---------|----------------|
| Screen + system audio + mic | ScreenCaptureKit — a single `SCStream` delivers `.screen`, `.audio`, and `.microphone` |
| Window selection | Native `SCContentSharingPicker` (`WindowPicker.swift`); the picker grants access to the chosen window |
| Webcam | AVFoundation `AVCaptureSession` |
| Compositing | CoreImage — each screen frame is scaled/centered onto a fixed **1920×1080** canvas with an optional background, rounded corners, shadow, and webcam bubble baked in (`VideoCompositor.swift`) |
| Encoding | `AVAssetWriter` → HEVC (H.265) / AAC `.mp4` (`MovieWriter.swift`) |
| Post-compression | Shells out to FFmpeg (`libx265`) for a much smaller final file (`FFmpegCompressor.swift`) |
| Toolbar UI | SwiftUI in a borderless floating `NSPanel`; Liquid Glass chrome on macOS 26 (`ToolbarView.swift`, `FloatingPanel.swift`, `Glass.swift`) |
| Project definition | XcodeGen (`project.yml`) |

All output is fixed at **1920×1080** regardless of source dimensions; content is
scaled to fit and centered on the canvas.

### Source layout (`PennyWiseApp/Sources/`)

```
PennyWiseApp.swift        App entry point + AppDelegate; creates the floating panel
FloatingPanel.swift       Borderless always-on-top NSPanel + auto-sizing hosting view
ToolbarView.swift         The vertical toolbar UI (record, window, camera, mic, bg, settings)
ContentView.swift         Settings popover UI
RecordingController.swift Orchestrates capture → compositing → writing → compression
ScreenCaptureManager.swift SCStream setup and frame/audio delivery
CameraCaptureManager.swift Webcam AVCaptureSession
CameraPreviewController.swift Live webcam preview
VideoCompositor.swift     CoreImage compositing onto the fixed 1920×1080 canvas
MovieWriter.swift         AVAssetWriter (HEVC/AAC) wrapper
AudioMixer.swift          Mixes mic + system audio
FFmpegCompressor.swift    Post-recording libx265 compression
Background.swift          Background presets (Wise tapestries, Tahoe wallpapers, custom image)
Permissions.swift         TCC permission helpers
CountdownController.swift  3-2-1 countdown before capture
StatusController.swift / TooltipController.swift  Floating status + tooltip panels
WindowPicker.swift        SCContentSharingPicker wrapper
Glass.swift               Liquid Glass / material background helper
AppLog.swift              Lightweight file logger (~/Library/Logs/PennyWise/PennyWise.log)
Tapestries/               Bundled background images
```

### Logs

Runtime logs are written to `~/Library/Logs/PennyWise/PennyWise.log` — useful for
diagnosing capture, compositing, and compression issues.

---

## Privacy

Everything is local. Recordings are written to a folder you choose on disk. There
is no network or cloud component.
