import AppKit
import SwiftUI

/// Hosts the toolbar SwiftUI content and resizes its panel to fit — but does so
/// *asynchronously*, off the display cycle. `NSHostingView`'s built-in window
/// auto-sizing (`sizingOptions`) mutates the window during the CoreAnimation
/// commit and crashes on macOS 26 when the content changes size (record dot →
/// compressing ring, discard/reveal buttons appearing). Disabling it and
/// resizing ourselves on the next runloop tick avoids that.
final class AutoSizingHostingView<Content: View>: NSHostingView<Content> {
    /// Called (on the main thread) with the content's desired size after layout.
    var onContentResize: ((CGSize) -> Void)?

    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []   // don't let SwiftUI drive the window size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = fittingSize
        guard size.width > 0, size.height > 0 else { return }
        onContentResize?(size)
    }
}

/// A borderless, always-on-top, non-activating panel used for the recording
/// toolbar. Draggable by its background, stays above all other windows, and
/// joins every Space / fullscreen tile so it's always reachable.
final class FloatingPanel: NSPanel {
    init(contentView view: NSView) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .floating
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = view
    }

    /// Accept mouse events even when the app isn't active.
    override var canBecomeKey: Bool { true }
}
