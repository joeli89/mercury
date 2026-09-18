import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import AppKit

/// Composites each screen frame into the final video: an optional background
/// (solid / gradient / image) with the screen inset on top — rounded corners and
/// a drop shadow, Screen Studio-style — plus an optional webcam bubble overlay.
///
/// The output canvas is always a fixed 1920×1080 (Full HD) regardless of the
/// captured source dimensions, so every recording is the same size.  Content is
/// scaled to fit the padded canvas area (maintaining aspect ratio).
///
/// Everything that doesn't change frame-to-frame (background, shadow, rounded
/// mask, content placement) is computed once and cached.
final class VideoCompositor {
    // MARK: - Output canvas
    //
    // No background: the content IS the video — 1920 wide for landscape
    // sources, 1080 wide for portrait ones, height from the source's aspect.
    // Background + Full width: a fixed 1920×1080 presentation frame with the
    // content centred inside a margin.
    // Background + Hug: the frame wraps the content plus the margin.
    static let landscapeWidth = 1920
    static let portraitWidth  = 1080
    static let frameWidth  = 1920
    static let frameHeight = 1080
    static let marginFraction: CGFloat = 0.05   // of canvas width
    let canvasWidth: Int
    let canvasHeight: Int

    /// Canvas size for a source of the given pixel size.
    static func canvasSize(forSourceWidth w: Int, height h: Int,
                           hasBackground: Bool, fullWidth: Bool) -> (width: Int, height: Int) {
        guard w > 0, h > 0 else { return (frameWidth, frameHeight) }
        if hasBackground && fullWidth { return (frameWidth, frameHeight) }
        let cw = h > w ? portraitWidth : landscapeWidth
        let margin = hasBackground ? CGFloat(cw) * marginFraction : 0
        let contentW = CGFloat(cw) - 2 * margin
        let contentH = CGFloat(h) * contentW / CGFloat(w)
        var ch = Int((contentH + 2 * margin).rounded())
        if ch % 2 == 1 { ch += 1 }   // encoders want even dimensions
        return (cw, max(2, ch))
    }

    /// Corner radius of the inset screen content, as a fraction of its
    /// shorter side. 0.03 suits Mac windows; ~0.12 matches an iPhone screen.
    var contentCornerFraction: CGFloat = 0.03

    /// Glass bezel around the content (backgrounds only): width as a fraction
    /// of the content's shorter side, capped in pixels. Mirrors the live
    /// preview's Liquid Glass border.
    var bezelFraction: CGFloat = 0.033
    var bezelMaxWidth: CGFloat = 32

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

    /// Cached, size-dependent layers.
    private var layout: Layout?
    private struct Layout {
        let canvasWidth: Int
        let canvasHeight: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let contentTransform: CGAffineTransform  // maps source → inset content on canvas
        let contentRect: CGRect
        let mask: CIImage                        // white rounded rect at contentRect
        let backdrop: CIImage                    // background + shadow, full canvas
    }

    init(showCamera: Bool,
         background: BackgroundOption = BackgroundOption.presets[0],
         canvasWidth: Int,
         canvasHeight: Int) {
        self.showCamera = showCamera
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.background = background
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

        var srcW = CVPixelBufferGetWidth(src)
        var srcH = CVPixelBufferGetHeight(src)
        let cw = canvasWidth
        let ch = canvasHeight
        let frame = CGRect(x: 0, y: 0, width: cw, height: ch)

        guard let out = makePixelBuffer(width: cw, height: ch) else { return src }

        var base = CIImage(cvPixelBuffer: src)

        // Pre-scale sources larger than 2× the canvas. At extreme downscale
        // factors CIImage's rendering pipeline can misplace the content; a two-
        // step scale avoids that while preserving quality through supersampling.
        let maxSrc = max(cw, ch) * 2
        let srcMax = max(srcW, srcH)
        if srcMax > maxSrc {
            let ps = CGFloat(maxSrc) / CGFloat(srcMax)
            base = base.transformed(by: CGAffineTransform(scaleX: ps, y: ps))
            srcW = Int((CGFloat(srcW) * ps).rounded())
            srcH = Int((CGFloat(srcH) * ps).rounded())
        }

        var canvas: CIImage

        if hasBackground {
            let layout = layoutFor(canvasWidth: cw, canvasHeight: ch,
                                   sourceWidth: srcW, sourceHeight: srcH)
            // Inset + rounded screen content.
            let content = base
                .transformed(by: layout.contentTransform)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: layout.mask
                ])
            canvas = content.composited(over: layout.backdrop)
        } else {
            // No background: scale content to fill the canvas (letterboxed).
            let fitScale = min(CGFloat(cw) / CGFloat(srcW),
                               CGFloat(ch) / CGFloat(srcH))
            let scaledW = CGFloat(srcW) * fitScale
            let scaledH = CGFloat(srcH) * fitScale
            let dx = (CGFloat(cw) - scaledW) / 2
            let dy = (CGFloat(ch) - scaledH) / 2
            let t = CGAffineTransform(scaleX: fitScale, y: fitScale)
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
            canvas = base.transformed(by: t)
                .composited(over: CIImage(color: .black).cropped(to: frame))
        }

        if hasCamera, let cam {
            canvas = cameraOverlay(cam, frameWidth: cw).composited(over: canvas)
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

    private func layoutFor(canvasWidth cw: Int, canvasHeight ch: Int,
                           sourceWidth sw: Int, sourceHeight sh: Int) -> Layout {
        if let layout, layout.canvasWidth == cw, layout.canvasHeight == ch,
           layout.sourceWidth == sw, layout.sourceHeight == sh { return layout }

        let fw = CGFloat(cw), fh = CGFloat(ch)
        let srcW = CGFloat(sw), srcH = CGFloat(sh)
        let pad = Self.marginFraction * fw
        let availW = fw - 2 * pad
        let availH = fh - 2 * pad

        // Bezel width is derived from the content size at the *unbezelled* fit,
        // then the content is refitted inside (pad + bezel) so the bezel never
        // spills past the margin.
        let fit0 = min(availW / srcW, availH / srcH)
        let bezel = min(min(srcW, srcH) * fit0 * bezelFraction, bezelMaxWidth)

        // Scale source to fit within the padded area (maintain aspect ratio).
        let scale = min((availW - 2 * bezel) / srcW, (availH - 2 * bezel) / srcH)
        let contentW = srcW * scale
        let contentH = srcH * scale
        let originX = (fw - contentW) / 2
        let originY = (fh - contentH) / 2
        let contentRect = CGRect(x: originX, y: originY, width: contentW, height: contentH)

        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: originX, y: originY))

        let radius = min(contentW, contentH) * contentCornerFraction
        let mask = roundedRect(extent: contentRect, radius: radius, color: .white)

        // Background layer.
        let frame = CGRect(x: 0, y: 0, width: fw, height: fh)
        let bg = backgroundImage(in: frame)

        // Glass bezel geometry: a ring `bezel` wide around the content.
        let outerRect = contentRect.insetBy(dx: -bezel, dy: -bezel)
        let outerRadius = radius + bezel

        // Drop shadow: blurred black rounded rect, nudged down, behind the bezel.
        let blur = min(fw, fh) * 0.02
        var shadow = roundedRect(extent: outerRect, radius: outerRadius, color: .black)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35)
            ])
        shadow = shadow.transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.6))

        let glass = glassBezel(background: bg, frame: frame,
                               outer: outerRect, outerRadius: outerRadius,
                               inner: contentRect, innerRadius: radius)

        let backdrop = glass.composited(over: shadow.composited(over: bg)).cropped(to: frame)

        let layout = Layout(canvasWidth: cw, canvasHeight: ch,
                            sourceWidth: sw, sourceHeight: sh,
                            contentTransform: transform, contentRect: contentRect,
                            mask: mask, backdrop: backdrop)
        self.layout = layout
        return layout
    }

    /// A frosted ring between `inner` and `outer`: the background behind it,
    /// blurred and lifted, with a bright outer edge and a softer inner edge —
    /// a still-image stand-in for Liquid Glass.
    private func glassBezel(background bg: CIImage, frame: CGRect,
                            outer: CGRect, outerRadius: CGFloat,
                            inner: CGRect, innerRadius: CGFloat) -> CIImage {
        let bezelWidth = inner.minX - outer.minX
        guard bezelWidth > 0.5 else { return CIImage.empty() }

        // Ring mask: white outer rounded rect with the content cut out.
        let ringMask = roundedRect(extent: inner, radius: innerRadius, color: .black)
            .composited(over: roundedRect(extent: outer, radius: outerRadius, color: .white))

        // Frosted fill: blurred, slightly brighter, slightly desaturated background
        // with a white veil.
        let frosted = bg.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(12, bezelWidth * 1.2)])
            .cropped(to: frame)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.85,
                kCIInputBrightnessKey: 0.05,
                kCIInputContrastKey: 1.0
            ])
        let veil = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.22)).cropped(to: frame)
        let fill = veil.composited(over: frosted)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: ringMask
            ])

        // Edge highlights: ~1.5px bright line on the outer edge, softer on the inner.
        let line = max(1.5, bezelWidth * 0.06)
        let outerEdgeMask = roundedRect(extent: outer.insetBy(dx: line, dy: line),
                                        radius: max(0, outerRadius - line), color: .black)
            .composited(over: roundedRect(extent: outer, radius: outerRadius, color: .white))
        let innerEdgeMask = roundedRect(extent: inner, radius: innerRadius, color: .black)
            .composited(over: roundedRect(extent: inner.insetBy(dx: -line, dy: -line),
                                          radius: innerRadius + line, color: .white))
        let outerEdge = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.6)).cropped(to: frame)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: outerEdgeMask])
        let innerEdge = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.35)).cropped(to: frame)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: innerEdgeMask])

        return innerEdge.composited(over: outerEdge.composited(over: fill))
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
