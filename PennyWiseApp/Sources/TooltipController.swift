import AppKit
import SwiftUI

// MARK: - Tooltip bubble (SwiftUI content inside the floating tooltip panel)

struct TooltipBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThickMaterial,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .preferredColorScheme(.dark)
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

    /// Show a tooltip for a button whose frame is expressed in SwiftUI's
    /// `.global` coordinate space (relative to the hosting view, Y↓).
    func show(text: String, buttonGlobalFrame: CGRect) {
        guard let hostView, let window = hostView.window else { return }

        ensurePanelExists()

        // Update label
        hostingView?.rootView = TooltipBubble(text: text)

        // Measure tooltip after content update
        let size = measureTooltip(text: text)

        // ── Coordinate conversion (robust, via AppKit) ────────────────────
        // NSHostingView is flipped (top-left origin, Y↓), matching SwiftUI's
        // `.global` space — so the rect maps straight into hostView coords.
        // Convert view → window → screen with AppKit, which correctly handles
        // the view's actual geometry within the window.
        let inView = buttonGlobalFrame
        let inWindow = hostView.convert(inView, to: nil)      // view → window
        let buttonScreen = window.convertToScreen(inWindow)   // window → screen

        // ── Side selection ───────────────────────────────────────────────
        // Put the tooltip on whichever side has room. Prefer the right, but if
        // it wouldn't fit (toolbar docked near the right edge) flip to the
        // left. If neither side fits, pick the side with more room.
        let screen     = window.screen?.visibleFrame ?? hostPanel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8
        let spaceRight = screen.maxX - buttonScreen.maxX
        let spaceLeft  = buttonScreen.minX - screen.minX
        let fitsRight  = spaceRight >= size.width + gap
        let fitsLeft   = spaceLeft  >= size.width + gap
        let showOnRight = fitsRight || (!fitsLeft && spaceRight >= spaceLeft)

        var x = showOnRight
            ? buttonScreen.maxX + gap
            : buttonScreen.minX - size.width - gap
        var y = buttonScreen.midY - size.height / 2

        // Clamp fully on-screen on both axes.
        x = min(max(x, screen.minX + 2), screen.maxX - size.width - 2)
        y = min(max(y, screen.minY + 2), screen.maxY - size.height - 2)

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
