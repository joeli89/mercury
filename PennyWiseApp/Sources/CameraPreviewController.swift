import AppKit
import AVFoundation

/// A floating, draggable circular self-view that shows the live webcam feed —
/// so the user always knows the camera is capturing them (Loom-style).
/// Backed by an `AVCaptureVideoPreviewLayer` on the shared capture session, so
/// it's GPU-efficient and needs no per-frame CPU work.
@MainActor
final class CameraPreviewController {
    private var panel: NSPanel?
    private var previewView: CameraPreviewView?

    /// Diameter of the circular bubble in points.
    var diameter: CGFloat = 160

    /// Show the preview for a given capture session. Idempotent.
    func show(session: AVCaptureSession) {
        ensurePanel()
        previewView?.attach(session: session)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        previewView?.detach()
    }

    // MARK: - Setup

    private func ensurePanel() {
        guard panel == nil else { return }

        let view = CameraPreviewView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        self.previewView = view

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        // Default position: lower-left of the main screen (typical self-view spot).
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vis.minX + 32, y: vis.minY + 32))
        }
        self.panel = panel
    }
}

// MARK: - Preview view (circular, mirrored)

/// NSView hosting an AVCaptureVideoPreviewLayer, masked to a circle with a ring.
final class CameraPreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let ring = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        previewLayer.videoGravity = .resizeAspectFill
        // Mirror like a selfie so it matches the composited recording.
        if previewLayer.connection?.isVideoMirroringSupported == true {
            previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
            previewLayer.connection?.isVideoMirrored = true
        }
        layer?.addSublayer(previewLayer)

        // White ring around the bubble.
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 3
        layer?.addSublayer(ring)

        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(session: AVCaptureSession) {
        previewLayer.session = session
        if previewLayer.connection?.isVideoMirroringSupported == true {
            previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
            previewLayer.connection?.isVideoMirrored = true
        }
    }

    func detach() {
        previewLayer.session = nil
    }

    override func layout() {
        super.layout()
        let d = min(bounds.width, bounds.height)
        // Circular mask.
        layer?.cornerRadius = d / 2
        previewLayer.frame = bounds
        previewLayer.cornerRadius = d / 2
        previewLayer.masksToBounds = true
        // Ring path, inset by half the line width so it isn't clipped.
        let inset = ring.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        ring.path = CGPath(ellipseIn: rect, transform: nil)
        ring.frame = bounds
    }
}
