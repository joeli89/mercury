# Memory / Working Notes

Persistent context for working on Mercury: decisions, gotchas, and environment facts. Append as you learn.

## Environment (verified 2026-08-28)
- macOS 26.6.1 (build 25G76)
- Xcode 26.2 (17C52)
- Swift 6.2.3
- XcodeGen installed at `/opt/homebrew/bin/xcodegen`
- Homebrew at `/opt/homebrew/bin/brew`

## Key decisions
- **Deployment target macOS 15+**: needed so a single `SCStream` can capture the microphone (`SCStreamConfiguration.captureMicrophone`, `SCStreamOutputType.microphone`) alongside screen video and system audio. Simplifies audio handling since all audio arrives in a consistent 48 kHz format.
- **Non-sandboxed for local dev** to avoid extra TCC friction with Screen Recording. Camera/mic still require Info.plist usage strings + user grant.
- **XcodeGen** owns the project definition (`project.yml`) — the `.xcodeproj` is generated, not hand-edited. Regenerate with `xcodegen generate`.
- **Real-time compositing** of webcam onto screen frames via CoreImage so the output is a single MP4 with the bubble baked in.
- **Audio mixing**: sum mic + system PCM into one AAC track. Fallback if timing is fiddly = two separate audio tracks.
- **HEVC over H.264**: HEVC gives ~50% better compression for screen content with hardware encode on all Apple Silicon. Bitrate multiplier `0.025` (was `0.12`) tuned for screen recordings.
- **Default 1x resolution**: captures at logical display size (not Retina pixel size) by default — 4x fewer pixels. User can toggle to Retina if they need pixel-perfect output.

## Gotchas
- **Code signing & TCC**: builds are signed with the Apple Development identity (Team `Z9F537W27X`), set manually in `project.yml` (`CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: "Apple Development"`). This is deliberate — ad-hoc signing changes the binary cdhash every rebuild, which invalidates the Screen Recording / Camera / Mic TCC grants (Settings shows the toggle "on" but `CGPreflightScreenCaptureAccess()` returns false). A stable signing identity makes the grants persist across rebuilds.
- macOS only reads Screen Recording permission at **launch** — after granting, quit & relaunch the app.
- If permissions ever get stuck, reset with `tccutil reset ScreenCapture com.mercury.Mercury` then relaunch.
- Window selection uses the native `SCContentSharingPicker` (see `WindowPicker.swift`) — the picker's selection itself grants access to that window's content.
- Anchor all AVAssetWriter inputs (screen video + audio) to one session start time (host clock) to keep A/V in sync across the three async sources.
- Reuse a `CVPixelBufferPool` for compositing; cap capture fps (30/60) to keep per-frame CoreImage work affordable at high resolution.

## Out of scope (v1)
Auto-zoom on click, smooth cursor animation, backgrounds/padding, editing timeline. Keep the raw capture pipeline modular so these can be layered on later.
