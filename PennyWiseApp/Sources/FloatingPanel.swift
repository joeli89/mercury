import AppKit

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
