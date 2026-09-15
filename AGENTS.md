# AGENTS.md

Instructions for AI coding agents working in this repository. Keep these rules
in mind for every change. See `README.md` for the human-oriented overview.

## What this is

Mercury is a fully-local macOS screen recorder (SwiftUI + AppKit). It captures
screen/window + webcam + mic + system audio, composites onto a fixed 1920×1080
canvas, and writes a compressed HEVC `.mp4`. No network/cloud component.

- Language: Swift 5 (toolchain from Xcode 26)
- UI: SwiftUI hosted in a borderless floating `NSPanel`
- Deployment target: macOS 15.0 (developed on macOS 26)
- App is non-sandboxed (`ENABLE_APP_SANDBOX: NO`) for local TCC simplicity

## Project structure

- App target lives in `MercuryApp/`
- Swift sources in `MercuryApp/Sources/` (all `.swift` files are flat here)
- Bundled background images in `MercuryApp/Sources/Tapestries/`
- `MercuryApp/project.yml` is the source of truth for the Xcode project

## Build & verify

Run all commands from `MercuryApp/`.

```bash
# Regenerate the Xcode project (required after editing project.yml or adding files)
xcodegen generate

# Build (this is the primary verification step — treat build success as the gate)
xcodebuild -project Mercury.xcodeproj -scheme Mercury -configuration Debug build

# Built app path:
# ~/Library/Developer/Xcode/DerivedData/Mercury-*/Build/Products/Debug/Mercury.app

# Launch the built app:
open ~/Library/Developer/Xcode/DerivedData/Mercury-*/Build/Products/Debug/Mercury.app

# Kill a running instance before relaunching:
pkill -x Mercury
```

There is **no automated test suite**. Verify changes by (1) a clean build and
(2) launching and exercising the affected flow. Runtime logs go to
`~/Library/Logs/Mercury/Mercury.log` (via `AppLog.swift`) — grep it to
confirm capture/compositing/compression behavior.

## Prerequisites (already installed on the dev machine)

- Xcode 26+, `xcodegen` and `ffmpeg` on `PATH` (Homebrew: `brew install xcodegen ffmpeg`)
- FFmpeg is a runtime dependency for post-recording compression; resolved from
  `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, then `PATH`.

## Rules & conventions

- **Never hand-edit `Mercury.xcodeproj`.** It is generated. Edit `project.yml`
  and run `xcodegen generate`.
- **After adding/removing/renaming a source file, run `xcodegen generate`** so
  it's picked up by the target.
- Do not change code signing to work around build issues. `DEVELOPMENT_TEAM`,
  `CODE_SIGN_STYLE: Manual`, and `CODE_SIGN_IDENTITY: "Apple Development"` are
  deliberate — a stable identity keeps Screen Recording / Camera / Mic TCC
  grants alive across rebuilds. A different developer sets their own team ID.
- Match existing code style: compact Swift, SwiftUI-first, no new dependencies
  without discussion.
- Do not add comments unless they add real value; preserve existing ones.
- Keep everything local — never introduce network calls, telemetry, or cloud
  uploads.

## Gotchas

- macOS reads the Screen Recording grant **at launch only**. After granting,
  quit and relaunch. Reset stuck grants with
  `tccutil reset ScreenCapture com.mercury.Mercury` (also `Camera`, `Microphone`).
- The output canvas is always 1920×1080 (`VideoCompositor.canvasWidth/Height`);
  source frames are scaled to fit and centered. `MovieWriter` is initialized
  with these fixed dimensions, not the capture size.
- For window capture, capture at the window's **1× logical** size — requesting
  non-native (e.g. Retina-scaled) dimensions can make SCStream leave empty
  padding in the buffer, throwing off centering.
- The toolbar is a borderless `NSPanel` with no main window. It sizes via
  `AutoSizingHostingView` (`sizingOptions = [.intrinsicContentSize]`) and is
  positioned on the screen containing the mouse cursor. Resize the window
  asynchronously (never during a CoreAnimation commit — that crashes on macOS 26).
- Liquid Glass (`Glass.swift`) uses no forced tint; foreground content uses
  adaptive `.primary`/`.secondary` colors so icons stay legible on any backdrop.

## Key files

- `MercuryApp/Sources/RecordingController.swift` — orchestrates the pipeline
- `MercuryApp/Sources/ScreenCaptureManager.swift` — SCStream capture
- `MercuryApp/Sources/VideoCompositor.swift` — CoreImage compositing / canvas
- `MercuryApp/Sources/MovieWriter.swift` — AVAssetWriter (HEVC/AAC)
- `MercuryApp/Sources/FFmpegCompressor.swift` — libx265 post-compression
- `MercuryApp/Sources/MercuryApp.swift` — app entry + floating panel setup
- `MercuryApp/project.yml` — XcodeGen project definition
