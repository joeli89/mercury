@preconcurrency import ScreenCaptureKit

/// Async wrapper around the system content-sharing picker (`SCContentSharingPicker`).
/// This is the native macOS experience — the user hovers over and clicks the
/// window they want to record, exactly like Loom / Screen Studio / macOS sharing.
@MainActor
final class WindowPicker: NSObject, SCContentSharingPickerObserver {
    private let picker = SCContentSharingPicker.shared
    private var continuation: CheckedContinuation<SCContentFilter?, Never>?

    /// Presents the native picker and returns the chosen filter, or nil if the
    /// user cancelled / it failed to start.
    func pickWindow() async -> SCContentFilter? {
        guard continuation == nil else { return nil }

        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        if let bundleID = Bundle.main.bundleIdentifier {
            config.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true

        let filter = await withCheckedContinuation { (cont: CheckedContinuation<SCContentFilter?, Never>) in
            self.continuation = cont
            picker.present()
        }

        picker.isActive = false
        picker.remove(self)
        return filter
    }

    /// Best-effort human-readable name for a picked filter (macOS 15.2+).
    static func displayName(for filter: SCContentFilter) -> String {
        if #available(macOS 15.2, *) {
            if let w = filter.includedWindows.first {
                let app = w.owningApplication?.applicationName ?? ""
                let title = w.title ?? ""
                let label = [app, title].filter { !$0.isEmpty }.joined(separator: " — ")
                if !label.isEmpty { return label }
            }
        }
        return "Selected window"
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        continuation?.resume(returning: filter)
        continuation = nil
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        continuation?.resume(returning: nil)
        continuation = nil
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
