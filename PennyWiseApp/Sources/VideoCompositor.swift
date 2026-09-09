import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import AppKit

/// Composites each screen frame into the final video: an optional background
/// (solid / gradient / image) with the screen inset on top — rounded corners and
/// a drop shadow, Screen Studio-style — plus an optional webcam bubble overlay.
///
/// Everything that doesn't change frame-to-frame (background, shadow, rounded
/// mask, content placement) is computed once and cached.
final class VideoCompositor {
    private let ciContext: CIContext
    private let lock = NSLock()
    private var latestCamera: CIImage?

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    // Camera bubble
    var cameraWidthFraction: CGFloat = 0.13
    var margin: CGFloat = 48
    var mirrorCamera = true
    let showCamera: Bool

    // Background
    private let background: BackgroundOption
    private let paddingFraction: CGFloat

    /// Cached, size-dependent layers.
    private var layout: Layout?
    private struct Layout {
        let width: Int
        let height: Int
        let contentTransform: CGAffineTransform  // maps full-frame screen → inset content
        let contentRect: CGRect
        let mask: CIImage                        // white rounded rect at contentRect
        let backdrop: CIImage                    // background + shadow, full frame
    }

    init(showCamera: Bool,
         background: BackgroundOption = BackgroundOption.presets[0],
         padding: BackgroundPadding = .medium) {
        self.showCamera = showCamera
        self.background = background
        self.paddingFraction = padding.fraction
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device)
        } else {
            ciContext = CIContext()
        }
    }

    func updateCamera(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        lock.lock(); latestCamera = image; lock.unlock()
    }

    func composite(_ src: CVPixelBuffer) -> CVPixelBuffer {
        lock.lock(); let cam = latestCamera; lock.unlock()
        let hasCamera = showCamera && cam != nil
        let hasBackground = !background.isNone

        // Nothing to do → pass the source straight through.
        guard hasCamera || hasBackground else { return src }

        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        guard let out = makePixelBuffer(width: w, height: h) else { return src }

        let base = CIImage(cvPixelBuffer: src)
        var canvas: CIImage

        if hasBackground {
            let layout = layoutFor(width: w, height: h)
            // Inset + rounded screen content.
            let content = base
                .transformed(by: layout.contentTransform)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: layout.mask
                ])
            canvas = content.composited(over: layout.backdrop)
        } else {
            canvas = base
        }

        if hasCamera, let cam {
            canvas = cameraOverlay(cam, frameWidth: w).composited(over: canvas)
        }

        canvas = canvas.cropped(to: frame)
        ciContext.render(canvas, to: out, bounds: frame,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
    }

    // MARK: - Camera bubble

    var cameraCornerRadius: CGFloat = 0.18  // fraction of bubble size

    private func cameraOverlay(_ cam: CIImage, frameWidth w: Int) -> CIImage {
        let camExtent = cam.extent
        guard camExtent.width > 0, camExtent.height > 0 else { return cam }

        // 1. Center-crop to a square.
        let side = min(camExtent.width, camExtent.height)
        let cropRect = CGRect(
            x: camExtent.midX - side / 2,
            y: camExtent.midY - side / 2,
            width: side, height: side
        )
        var camImage = cam.cropped(to: cropRect)

        // 2. Scale to target size.
        let targetSize = CGFloat(w) * cameraWidthFraction
        let scale = targetSize / side
        camImage = camImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // 3. Mirror horizontally (selfie-style).
        if mirrorCamera {
            let e = camImage.extent
            camImage = camImage
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: e.width + 2 * e.minX, y: 0))
        }

        // 4. Rounded-corner mask.
        let e = camImage.extent
        let radius = e.width * cameraCornerRadius
        let mask = roundedRect(extent: e, radius: radius, color: .white)
        camImage = camImage.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])

        // 5. Position in the bottom-right corner.
        let tx = CGFloat(w) - e.width - margin
        let ty = margin
        return camImage.transformed(by: CGAffineTransform(translationX: tx - e.minX, y: ty - e.minY))
    }

    // MARK: - Layout / static layers

    private func layoutFor(width w: Int, height h: Int) -> Layout {
        if let layout, layout.width == w, layout.height == h { return layout }

        let fw = CGFloat(w), fh = CGFloat(h)
        let pad = paddingFraction * min(fw, fh)
        // Contain the screen (same aspect as the frame) inside the padded rect.
        let scale = min((fw - 2 * pad) / fw, (fh - 2 * pad) / fh)
        let contentW = fw * scale
        let contentH = fh * scale
        let originX = (fw - contentW) / 2
        let originY = (fh - contentH) / 2
        let contentRect = CGRect(x: originX, y: originY, width: contentW, height: contentH)

        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: originX, y: originY))

        let radius = min(contentW, contentH) * 0.03
        let mask = roundedRect(extent: contentRect, radius: radius, color: .white)

        // Background layer.
        let frame = CGRect(x: 0, y: 0, width: fw, height: fh)
        let bg = backgroundImage(in: frame)

        // Drop shadow: blurred black rounded rect, nudged down, behind the content.
        let blur = min(fw, fh) * 0.02
        var shadow = roundedRect(extent: contentRect, radius: radius, color: .black)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35)
            ])
        shadow = shadow.transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.6))

        let backdrop = shadow.composited(over: bg).cropped(to: frame)

        let layout = Layout(width: w, height: h, contentTransform: transform,
                            contentRect: contentRect, mask: mask, backdrop: backdrop)
        self.layout = layout
        return layout
    }

    private func backgroundImage(in frame: CGRect) -> CIImage {
        switch background.style {
        case .none:
            return CIImage(color: .black).cropped(to: frame)
        case .solid(let hex):
            return CIImage(color: .fromHex(hex)).cropped(to: frame)
        case .gradient(let a, let b):
            let f = CIFilter.linearGradient()
            f.point0 = CGPoint(x: frame.minX, y: frame.maxY)   // top-left
            f.color0 = .fromHex(a)
            f.point1 = CGPoint(x: frame.maxX, y: frame.minY)   // bottom-right
            f.color1 = .fromHex(b)
            return (f.outputImage ?? CIImage(color: .fromHex(a))).cropped(to: frame)
        case .image(let url):
            guard let img = CIImage(contentsOf: url) else {
                return CIImage(color: .fromHex("2B2B2E")).cropped(to: frame)
            }
            // Aspect-fill into the frame, centered.
            let s = max(frame.width / img.extent.width, frame.height / img.extent.height)
            let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let dx = frame.midX - scaled.extent.midX
            let dy = frame.midY - scaled.extent.midY
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: frame)
        }
    }

    private func roundedRect(extent: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = extent
        f.radius = Float(radius)
        f.color = color
        return f.outputImage ?? CIImage(color: color).cropped(to: extent)
    }

    // MARK: - Output buffers

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
            pool = newPool
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
