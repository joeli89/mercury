import AppKit
import SwiftUI

// MARK: - Tooltip bubble (SwiftUI content inside the floating tooltip panel)

struct TooltipBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Tooltip controller

/// Manages a lightweight borderless NSPanel that renders tooltip labels.
/// Using a *separate* window means the tooltip is never clipped by the main
/// toolbar panel, can appear on either side depending on screen position, and
/// aligns vertically with whichever button is hovered.
@MainActor
final class TooltipController: ObservableObject {

    /// The toolbar's hosting NSView — used to convert SwiftUI `.global`
    /// (view-relative, top-left origin) coordinates to screen coordinates via
    /// AppKit, which is robust regardless of the panel's size/layout.
    weak var hostView: NSView?
    /// Kept for the fallback screen lookup.
    weak var hostPanel: NSPanel?

    private var tooltipPanel: NSPanel?
    private var hostingView: NSHostingView<TooltipBubble>?

    // MARK: Public API

    /// Show a tooltip next to the mouse cursor. The `buttonGlobalFrame` is no
    /// longer needed for positioning — anchoring to the cursor avoids all
    /// view→window→screen coordinate conversion, which was the source of the
    /// off-screen bug.
    func show(text: String, buttonGlobalFrame: CGRect = .zero) {
        ensurePanelExists()

        // Update label + measure.
        hostingView?.rootView = TooltipBubble(text: text)
        let size = measureTooltip(text: text)

        // Cursor position is already in screen coordinates (bottom-left origin).
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) }
                      ?? NSScreen.main)?.visibleFrame ?? .zero

        // ── Side selection ───────────────────────────────────────────────
        // Place to the RIGHT of the cursor by default; flip LEFT when the
        // toolbar is docked near the right edge and it wouldn't fit.
        let gap: CGFloat = 16
        var x = mouse.x + gap
        if x + size.width > screen.maxX - 4 {
            x = mouse.x - size.width - gap
        }
        // Vertically center on the cursor.
        var y = mouse.y - size.height / 2

        // Clamp fully on-screen on both axes.
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)

        tooltipPanel?.setContentSize(size)
        tooltipPanel?.setFrameOrigin(NSPoint(x: x, y: y))
        tooltipPanel?.orderFrontRegardless()
    }

    func hide() {
        tooltipPanel?.orderOut(nil)
    }

    // MARK: Private

    private func ensurePanelExists() {
        guard tooltipPanel == nil else { return }

        let hosting = NSHostingView(rootView: TooltipBubble(text: ""))
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)
        self.hostingView = hosting

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating          // same level as the toolbar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true  // clicks pass through
        panel.contentView = hosting
        self.tooltipPanel = panel
    }

    /// Measures tooltip size using NSFont so we don't need another layout pass.
    private func measureTooltip(text: String) -> CGSize {
        let font  = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs = [NSAttributedString.Key.font: font]
        let ts    = (text as NSString).size(withAttributes: attrs)
        // horizontal: 10+10 padding; vertical: 6+6 padding; +4 safety margin each axis
        return CGSize(width: ceil(ts.width) + 24, height: ceil(ts.height) + 16)
    }
}
