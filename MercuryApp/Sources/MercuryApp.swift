import SwiftUI

@main
struct MercuryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No visible window — the floating toolbar is created by AppDelegate.
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = RecordingController()
    let tooltipController = TooltipController()
    let statusController = StatusController()
    let cameraPreview = CameraPreviewController()
    private var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.cameraPreview = cameraPreview

        let toolbarView = ToolbarView()
            .environmentObject(controller)
            .environmentObject(tooltipController)
            .environmentObject(statusController)

        let hosting = AutoSizingHostingView(rootView: AnyView(toolbarView))
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)

        let panel = FloatingPanel(contentView: hosting)
        self.panel = panel

        // Force a layout pass so `fittingSize` reflects the real content, then
        // size + position the panel *synchronously* at right-centre of the
        // screen. Doing this up front guarantees the panel is visible on launch
        // regardless of when the async resize callback fires. A sane default is
        // used if the content hasn't measured yet.
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 20 || size.height < 20 { size = CGSize(width: 64, height: 420) }
        positionPanel(panel, size: size, anchorTopRight: false)
        panel.orderFrontRegardless()

        // Keep the panel fitted as content changes (record dot → compressing
        // ring, discard/reveal buttons appearing). Runs asynchronously so we
        // never mutate the window during a display cycle (crashes on macOS 26).
        // Anchors the top-right corner so the pill grows/shrinks downward while
        // staying flush against the right edge of the screen.
        hosting.onContentResize = { [weak self, weak panel] newSize in
            guard let self, let panel,
                  panel.contentView?.frame.size != newSize,
                  newSize.width >= 20, newSize.height >= 20 else { return }
            DispatchQueue.main.async {
                self.positionPanel(panel, size: newSize, anchorTopRight: true)
            }
        }

        // Give the tooltip controller references so it can convert
        // SwiftUI-global coordinates to screen coordinates via AppKit.
        tooltipController.hostPanel = panel
        tooltipController.hostView = hosting
        statusController.hostPanel = panel
    }

    /// Sizes `panel` to `size` and positions it against the right edge of the
    /// main screen, always clamped fully within the visible frame so it can
    /// never end up off-screen. When `anchorTopRight` is true the panel's
    /// existing top-right corner is preserved (used when content resizes);
    /// otherwise it's placed at right-centre (used for the initial placement).
    private func positionPanel(_ panel: FloatingPanel, size: CGSize, anchorTopRight: Bool) {
        let screen: NSScreen?
        if anchorTopRight {
            // Content resize: stay on whichever screen the panel is already on.
            let c = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            screen = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) }
                ?? NSScreen.main
        } else {
            // Initial placement: use the screen the mouse is on (where the user
            // is actively working) rather than NSScreen.main, which may be a
            // different monitor in a multi-display setup.
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                ?? NSScreen.main ?? NSScreen.screens.first
        }
        let vis = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let topRightY: CGFloat = anchorTopRight ? panel.frame.maxY
                                                : vis.midY + size.height / 2
        panel.setContentSize(size)

        var x = vis.maxX - size.width - 16
        var y = topRightY - size.height
        // Clamp fully on-screen.
        x = min(max(x, vis.minX), vis.maxX - size.width)
        y = min(max(y, vis.minY), vis.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Keep the app running even when all windows close (the panel is our UI).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
