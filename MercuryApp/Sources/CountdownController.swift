import AppKit
import SwiftUI

/// Shows a Loom-style 3-2-1 countdown in a centered floating panel before
/// recording starts. Because capture begins only after `run()` returns, the
/// countdown itself is never part of the recording.
@MainActor
final class CountdownController {
    private var panel: NSPanel?
    private let model = CountdownModel()

    /// Seconds per number.
    var tick: Double = 0.8

    /// Runs the countdown from `start` down to 1, then resolves.
    func run(from start: Int = 3) async {
        ensurePanel()
        for n in stride(from: start, through: 1, by: -1) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                model.number = n
            }
            panel?.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
        }
        hide()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Setup

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: CountdownRoot(model: model))
        let side: CGFloat = 300
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vis.midX - side / 2, y: vis.midY - side / 2))
        }
        self.panel = panel
    }
}

// MARK: - View

final class CountdownModel: ObservableObject {
    @Published var number: Int = 3
}

private struct CountdownRoot: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        ZStack {
            numberCircle
                .id(model.number)
                .transition(.scale(scale: 1.4).combined(with: .opacity))
        }
        .frame(width: 300, height: 300)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var numberCircle: some View {
        let label = Text("\(model.number)")
            .font(.system(size: 110, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 190, height: 190)

        if #available(macOS 26.0, *) {
            // Apple Liquid Glass — frosted, dynamic, with built-in lighting.
            label
                .glassEffect(.regular, in: .circle)
                .shadow(color: .black.opacity(0.28), radius: 30, y: 10)
        } else {
            label
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 10)
        }
    }
}
