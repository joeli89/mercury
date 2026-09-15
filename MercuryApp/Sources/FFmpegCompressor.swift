import Foundation

/// Post-recording compressor that shells out to FFmpeg for CRF-based HEVC
/// re-encoding — typically 4-10x smaller files than the AVAssetWriter output.
///
/// Tuned specifically for SCREEN CONTENT (flat UI, sharp text, long static
/// stretches). Uses libx265 in Main10 (10-bit) with a long GOP, extra B-frames,
/// edge-preserving in-loop filter settings, and edge-aware adaptive
/// quantization. In A/B benchmarks these settings roughly halve file size vs a
/// plain `libx265 -crf 26` encode at equivalent perceived quality (VMAF ~93),
/// while staying HEVC/hvc1 — hardware-decoded and QuickTime/Safari-compatible
/// on modern Macs.
final class FFmpegCompressor: @unchecked Sendable {

    /// Quality preset — maps to libx265 CRF values.
    /// Lower CRF = higher quality / bigger files. Screen recordings tolerate
    /// higher CRF values well because the content is mostly flat UI / text.
    enum Quality: String, CaseIterable, Identifiable {
        case low    = "Small"    // Aggressive — good enough for quick shares
        case medium = "Balanced" // Good quality, much smaller files (default)
        case high   = "Quality"  // Visually transparent

        var id: String { rawValue }

        /// libx265 CRF value (0 = lossless, 51 = worst). 28 is x265 default.
        var crf: Int {
            switch self {
            case .low:    return 32
            case .medium: return 28
            case .high:   return 24
            }
        }

        /// x265 speed preset — slower = better compression at same quality.
        /// `medium` is the sweet spot; the screen-content params do the heavy
        /// lifting, so a slower preset isn't needed.
        var preset: String {
            switch self {
            case .low:    return "medium"
            case .medium: return "medium"
            case .high:   return "slow"
            }
        }
    }

    /// Progress callback — fraction in 0…1.
    var onProgress: ((Double) -> Void)?

    private let quality: Quality
    private let fps: Int
    private var process: Process?

    init(quality: Quality = .medium, fps: Int = 60) {
        self.quality = quality
        self.fps = fps
    }

    /// One-line description of the encoder configuration (for logging).
    var settingsSummary: String {
        "libx265 crf=\(quality.crf) preset=\(quality.preset) 10-bit(yuv420p10le) [\(x265Params)]"
    }

    /// Screen-content-tuned x265 params.
    /// - Long GOP (10s) + closed GOP: screen frames are near-identical between
    ///   keyframes, so spreading keyframes far apart is a big size win while
    ///   keeping seeking sane.
    /// - `bframes=8`: B-frames are very efficient on static screen content.
    /// - `sao=0` + `strong-intra-smoothing=0`: both filters smear sharp text
    ///   edges; disabling them keeps text crisp.
    /// - `aq-mode=4`: variance + edge-aware bit allocation, good for UI/text.
    /// - `rect=0`: skip rectangular partitions — negligible quality change on
    ///   screen content, meaningfully faster.
    private var x265Params: String {
        let keyint = max(fps * 10, 120)
        let minKeyint = max(fps, 24)
        return [
            "keyint=\(keyint)",
            "min-keyint=\(minKeyint)",
            "bframes=8",
            "no-open-gop=1",
            "aq-mode=4",
            "sao=0",
            "strong-intra-smoothing=0",
            "rect=0"
        ].joined(separator: ":")
    }

    // MARK: - Public

    /// Compress `input` → `output`. The input file is left untouched (the
    /// caller owns it, typically a temp file it deletes afterwards).
    /// Returns `output` on success.
    @discardableResult
    func compress(_ input: URL, to output: URL) async throws -> URL {
        // Encode to a hidden sibling of `output` first, then move into place —
        // so a partial file never appears at the destination.
        let tmp = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent)-encoding.mp4")
        try? FileManager.default.removeItem(at: tmp)

        // Probe duration for progress calculation.
        let duration = try await probeDuration(of: input)

        let ffmpeg = ffmpegPath()

        // Build arguments — libx265 (Main10) with CRF + screen-content tuning.
        // CRF allocates bits only where needed; 10-bit encoding is ~5-10%
        // smaller even from an 8-bit source and removes banding in flat UI
        // gradients. HEVC Main10 / hvc1 is hardware-decoded on modern Macs.
        let args: [String] = [
            "-y",                                     // overwrite
            "-i", input.path,
            "-c:v", "libx265",
            "-crf", "\(quality.crf)",
            "-preset", quality.preset,
            "-x265-params", x265Params,
            "-pix_fmt", "yuv420p10le",                // 10-bit Main10
            "-tag:v", "hvc1",                         // QuickTime compatibility
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            "-progress", "pipe:1",                    // machine-readable progress
            tmp.path
        ]

        // Run FFmpeg.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        self.process = proc

        try proc.run()

        // Parse progress (stdout) on a background thread.
        let progressTask = Task.detached { [weak self, duration] in
            let handle = stdoutPipe.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                // Parse lines for "out_time_us=..." progress keys.
                if let str = String(data: buffer, encoding: .utf8) {
                    let lines = str.components(separatedBy: "\n")
                    // Keep the last incomplete line in the buffer.
                    buffer = (lines.last ?? "").data(using: .utf8) ?? Data()
                    for line in lines {
                        if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)),
                           duration > 0 {
                            let frac = min(1.0, max(0.0, (us / 1_000_000) / duration))
                            self?.onProgress?(frac)
                        }
                    }
                }
            }
        }

        // Drain stderr concurrently. This is essential: x265 logs to stderr and
        // if we let it accumulate until after the process exits, its 64KB pipe
        // buffer fills, FFmpeg blocks on write(), and the encode hangs forever
        // (progress frozen mid-way). Reading it continuously prevents that.
        let stderrBox = StderrBox()
        let stderrTask = Task.detached {
            let handle = stderrPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                stderrBox.append(chunk)
            }
        }

        // Wait for FFmpeg to exit (off the main thread).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }
        _ = await stderrTask.value
        progressTask.cancel()
        self.process = nil

        guard proc.terminationStatus == 0 else {
            let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""
            // Clean up temp file on failure.
            try? FileManager.default.removeItem(at: tmp)
            throw CompressorError.ffmpegFailed(code: Int(proc.terminationStatus), stderr: stderr)
        }

        // Move the finished encode into the destination.
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: tmp, to: output)

        onProgress?(1.0)
        return output
    }

    func cancel() {
        process?.terminate()
    }

    // MARK: - Helpers

    private func ffmpegPath() -> String {
        // Check common Homebrew locations, then fall back to PATH.
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "ffmpeg" // hope it's on PATH
    }

    /// Use ffprobe to get the duration in seconds.
    private func probeDuration(of url: URL) async throws -> Double {
        let probePath = ffmpegPath().replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: probePath)
        proc.arguments = [
            "-v", "quiet",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Double(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    // MARK: - Thread-safe stderr accumulator

    /// Collects stderr bytes from a background reader thread.
    private final class StderrBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    // MARK: - Errors

    enum CompressorError: LocalizedError {
        case ffmpegFailed(code: Int, stderr: String)

        var errorDescription: String? {
            switch self {
            case .ffmpegFailed(let code, let stderr):
                let snippet = stderr.suffix(200)
                return "FFmpeg exited with code \(code): …\(snippet)"
            }
        }
    }
}
