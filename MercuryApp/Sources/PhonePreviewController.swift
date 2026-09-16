import AppKit
import AVFoundation
import SwiftUI

/// Floating, resizable live view of the connected iPhone's screen. Shown
/// whenever the iPhone capture source is selected, so the phone can be used
/// for live demos (screen-share this window) as well as recordings.
/// Fed with the same BGRA frames the recording uses (via
/// `AVSampleBufferDisplayLayer`), so colours match the recorded output —
/// `AVCaptureVideoPreviewLayer` misreads the phone stream's colour range and
/// looks washed out.
@MainActor
final class PhonePreviewController {
    private var panel: NSPanel?
    private var previewView: PhonePreviewView?

    /// Default size of the phone image in points (iPhone 16 Pro proportions).
    var defaultSize = NSSize(width: 360, height: 780)
    /// Width of the Liquid Glass border around the phone image.
    static let border: CGFloat = 12

    func show(manager: PhoneCaptureManager) {
        ensurePanel()
        previewView?.attach(manager: manager)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        previewView?.detach()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func ensurePanel() {
        guard panel == nil else { return }

        let view = PhonePreviewView(frame: NSRect(origin: .zero, size: defaultSize))
        self.previewView = view

        let b = Self.border
        let outer = NSSize(width: defaultSize.width + 2 * b, height: defaultSize.height + 2 * b)
        let hosting = NSHostingView(rootView: PhonePreviewFrame(preview: view))

        // Borderless so AppKit never draws a window frame / key outline around
        // the glass; `.resizable` keeps edge-drag resizing.
        let panel = PhonePreviewPanel(
            contentRect: NSRect(origin: .zero, size: outer),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = outer
        panel.minSize = NSSize(width: 180 + 2 * b, height: 390 + 2 * b)
        panel.contentView = hosting

        // Centre-left of the main screen (the toolbar lives on the right).
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vis.minX + 48, y: vis.midY - outer.height / 2))
        }
        self.panel = panel
    }
}

/// Never becomes key, so clicking it can't draw a focus outline or steal
/// focus from the app being demoed.
final class PhonePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Liquid Glass frame around the live phone image — the glass ring reads as
/// a bezel and picks up whatever is behind the window.
struct PhonePreviewFrame: View {
    let preview: PhonePreviewView

    var body: some View {
        GeometryReader { geo in
            let b = PhonePreviewController.border
            let innerW = max(1, geo.size.width - 2 * b)
            let innerRadius = innerW * 0.12
            PhonePreviewSurface(view: preview)
                .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
                .padding(b)
                .liquidGlass(in: RoundedRectangle(cornerRadius: innerRadius + b, style: .continuous))
        }
    }
}

/// Hosts the AppKit preview view inside SwiftUI.
struct PhonePreviewSurface: NSViewRepresentable {
    let view: PhonePreviewView
    func makeNSView(context: Context) -> PhonePreviewView { view }
    func updateNSView(_ nsView: PhonePreviewView, context: Context) {}
}

/// The live phone image (rounded like a phone screen); the glass bezel is
/// drawn by `PhonePreviewFrame` around it.
final class PhonePreviewView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private weak var manager: PhoneCaptureManager?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(manager: PhoneCaptureManager) {
        self.manager = manager
        let renderer = displayLayer.sampleBufferRenderer
        manager.onPreviewFrame = { sb in
            // Show each frame as it arrives rather than scheduling by timestamp.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sb)
        }
    }

    func detach() {
        manager?.onPreviewFrame = nil
        manager = nil
        displayLayer.sampleBufferRenderer.flush()
    }

    override func layout() {
        super.layout()
        let radius = bounds.width * 0.12
        layer?.cornerRadius = radius
        displayLayer.frame = bounds
        displayLayer.cornerRadius = radius
        displayLayer.masksToBounds = true
    }
}
