# Mercury

A simple, fully-local macOS screen recorder — record your screen with a webcam overlay plus microphone and system audio, and get a clean MP4 out. Nothing touches the cloud.

Think of it as a lightweight, local-first alternative to Screen Studio for demos and screen recordings.

## Status

v1 in development: reliable "plain" recording (screen + webcam bubble + mic + system audio → MP4). Screen Studio-style effects (auto-zoom on click, cursor smoothing, backgrounds, editing timeline) are intentionally out of scope for v1.

## Repository layout

```
Mercury/
├── main.md          # This file — project overview
├── changelog.md     # Human-readable history of notable changes
├── memory.md        # Working notes, decisions, gotchas, environment facts
└── MercuryApp/    # The actual macOS app (Swift + SwiftUI + Xcode project)
```

## The app (MercuryApp)

- **Language / UI:** Swift 6 + SwiftUI
- **Deployment target:** macOS 15+ (developed on macOS 26)
- **Screen + system audio + mic:** ScreenCaptureKit (single `SCStream` delivers `.screen`, `.audio`, `.microphone`)
- **Webcam:** AVFoundation `AVCaptureSession`
- **Compositing:** CoreImage (webcam drawn as a rounded overlay onto each screen frame)
- **Encoding:** AVAssetWriter → HEVC (H.265) / AAC in an `.mp4`
- **Project generation:** XcodeGen (`project.yml`)

### Build & run

```bash
cd MercuryApp
xcodegen generate      # produces Mercury.xcodeproj
open Mercury.xcodeproj
# Build & Run in Xcode (⌘R)
```

On first run, grant **Screen Recording**, **Camera**, and **Microphone** permissions in System Settings > Privacy & Security.

## Privacy

Everything is local. Recordings are written to a folder you choose on disk. There is no network/cloud component.
