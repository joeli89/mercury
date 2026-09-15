import Foundation
import AppKit
import os

/// Lightweight logging for recording sessions. Writes human-readable blocks to
/// a log file (easy to `tail -f` or open) and also mirrors to the unified log.
///
/// Log file: ~/Library/Logs/Mercury/Mercury.log
enum AppLog {
    private static let logger = Logger(subsystem: "com.mercury.Mercury", category: "recording")

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mercury", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Mercury.log")
    }()

    private static let queue = DispatchQueue(label: "com.mercury.applog")

    /// Append a line (or multi-line block) to the log file + unified log.
    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        queue.async {
            guard let data = (message + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Reveal the log file in Finder.
    static func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - Formatting helpers

    /// Human-readable byte size, e.g. "24.3 MB".
    static func size(_ bytes: Int) -> String {
        guard bytes > 0 else { return "—" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
