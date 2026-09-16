import AppKit
import AVFoundation

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

    /// Default size in points (iPhone 16 Pro logical size, scaled down a bit).
    var defaultSize = NSSize(width: 360, height: 780)

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

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = defaultSize
        panel.minSize = NSSize(width: 180, height: 390)
        panel.contentView = view

        // Centre-left of the main screen (the toolbar lives on the right).
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vis.minX + 48,
                                         y: vis.midY - defaultSize.height / 2))
        }
        self.panel = panel
    }
}

/// Rounded-rect preview with a thin bezel, like a phone.
final class PhonePreviewView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let bezel = CAShapeLayer()
    private weak var manager: PhoneCaptureManager?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)

        bezel.fillColor = NSColor.clear.cgColor
        bezel.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        bezel.lineWidth = 2
        layer?.addSublayer(bezel)
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
        let inset = bezel.lineWidth / 2
        bezel.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                            cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
        bezel.frame = bounds
    }
}
