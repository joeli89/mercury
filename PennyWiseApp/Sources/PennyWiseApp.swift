import SwiftUI

@main
struct PennyWiseApp: App {
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

        let hosting = NSHostingView(rootView: toolbarView)
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)

        let panel = FloatingPanel(contentView: hosting)
        // Size to fit the SwiftUI content, then position right-centre of the screen.
        let size = hosting.fittingSize
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            let origin = NSPoint(x: vis.maxX - size.width - 16,
                                 y: vis.midY - size.height / 2)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        self.panel = panel

        // Give the tooltip controller references so it can convert
        // SwiftUI-global coordinates to screen coordinates via AppKit.
        tooltipController.hostPanel = panel
        tooltipController.hostView = hosting
        statusController.hostPanel = panel
    }

    /// Keep the app running even when all windows close (the panel is our UI).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
