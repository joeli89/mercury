import AppKit
import SwiftUI

/// The status message bubble content (matches the toolbar styling).
struct StatusBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(3)
            .frame(maxWidth: 200, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Shows the status message in a floating panel anchored beside the toolbar,
/// flipping to the left when the toolbar is docked near the right screen edge —
/// so the message is never clipped (unlike an in-HStack card).
@MainActor
final class StatusController: ObservableObject {
    /// The toolbar panel we anchor to (set by AppDelegate).
    weak var hostPanel: NSPanel?

    private var panel: NSPanel?
    private var hosting: NSHostingView<StatusBubble>?
    private var autoHideTask: Task<Void, Never>?

    /// Auto-dismiss the message this many seconds after the last update.
    var autoHideAfter: TimeInterval = 5

    func show(_ text: String) {
        guard let host = hostPanel else { return }
        ensurePanel()
        hosting?.rootView = StatusBubble(text: text)

        let size = hosting?.fittingSize ?? CGSize(width: 180, height: 44)
        panel?.setContentSize(size)

        let hf = host.frame
        let screen = host.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8

        // Right of the toolbar by default; flip left if it wouldn't fit.
        var x = hf.maxX + gap
        if x + size.width > screen.maxX - 4 { x = hf.minX - size.width - gap }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)

        // Align the top of the bubble with the top of the toolbar.
        var y = hf.maxY - size.height
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)

        panel?.setFrameOrigin(NSPoint(x: x, y: y))
        panel?.orderFrontRegardless()

        // Reset the auto-dismiss timer on every update, so rapidly-updating
        // messages (e.g. "Compressing… X%") stay visible and the final message
        // fades a few seconds after the last change.
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            let delay = self?.autoHideAfter ?? 5
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            self?.panel?.orderOut(nil)
        }
    }

    func hide() {
        autoHideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: StatusBubble(text: ""))
        self.hosting = hosting
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
    }
}
