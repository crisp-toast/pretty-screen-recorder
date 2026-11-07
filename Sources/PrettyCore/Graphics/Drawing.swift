import Foundation
import CoreGraphics
import CoreImage
import CoreText
import AppKit

public let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draw into a premultiplied RGBA bitmap with a TOP-LEFT origin (y grows downward),
/// which matches how layouts are expressed everywhere else in Pretty Studio.
public func drawImage(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
    guard width > 0, height > 0,
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    body(ctx)
    return ctx.makeImage()
}

extension CIImage {
    public static func from(_ cg: CGImage?) -> CIImage {
        guard let cg else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    /// Place an image (whose extent starts at 0,0) so it fills `rect` given in TOP-LEFT stage coords.
    public func placed(in rect: CGRect, stageHeight: CGFloat) -> CIImage {
        let e = extent
        guard e.width > 0, e.height > 0 else { return self }
        let sx = rect.width / e.width, sy = rect.height / e.height
        let y = stageHeight - rect.maxY
        return transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: y)))
    }

    /// Fade to opacity `a`. CIColorMatrix works on UNpremultiplied color, so only alpha is
    /// scaled; the premultiplied result then scales correctly.
    public func opacity(_ a: CGFloat) -> CIImage {
        if a >= 0.999 { return self }
        if a <= 0.001 { return CIImage.empty() }
        return applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }

    public func over(_ bottom: CIImage) -> CIImage { composited(over: bottom) }
}

// MARK: - Paths

/// Apple-style continuous ("squircle") rounded rectangle. `smoothing` 0 gives a plain arc corner.
public func continuousRoundedRect(_ r: CGRect, radius: CGFloat, smoothing: CGFloat = 0.6) -> CGPath {
    let rad = min(radius, min(r.width, r.height) / 2)
    if rad <= 0.5 { return CGPath(rect: r, transform: nil) }
    if smoothing <= 0.01 { return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
    // Each corner spans p = (1 + smoothing) * rad along both edges, joined by one cubic
    // whose control points sit on the edges: continuous curvature, like Apple's squircles.
    let p = min((1 + smoothing) * rad, min(r.width, r.height) / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + p, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX - p, y: r.minY))
    addSmoothCorner(path, from: CGPoint(x: r.maxX - p, y: r.minY), corner: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX, y: r.minY + p))
    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - p))
    addSmoothCorner(path, from: CGPoint(x: r.maxX, y: r.maxY - p), corner: CGPoint(x: r.maxX, y: r.maxY), to: CGPoint(x: r.maxX - p, y: r.maxY))
    path.addLine(to: CGPoint(x: r.minX + p, y: r.maxY))
    addSmoothCorner(path, from: CGPoint(x: r.minX + p, y: r.maxY), corner: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.minX, y: r.maxY - p))
    path.addLine(to: CGPoint(x: r.minX, y: r.minY + p))
    addSmoothCorner(path, from: CGPoint(x: r.minX, y: r.minY + p), corner: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX + p, y: r.minY))
    path.closeSubpath()
    return path
}

/// A corner made of one cubic whose control points sit along the edges — gives a
/// continuous-curvature look close to Apple's squircles.
private func addSmoothCorner(_ path: CGMutablePath, from a: CGPoint, corner c: CGPoint, to b: CGPoint) {
    let t: CGFloat = 0.82
    let c1 = CGPoint(x: a.x + (c.x - a.x) * t, y: a.y + (c.y - a.y) * t)
    let c2 = CGPoint(x: b.x + (c.x - b.x) * t, y: b.y + (c.y - b.y) * t)
    path.addCurve(to: b, control1: c1, control2: c2)
}

public func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    continuousRoundedRect(r, radius: radius, smoothing: 0.6)
}

// MARK: - Fonts & text

public enum FontWeight: String {
    case regular, medium, semibold, bold, heavy, black
    public var ns: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

public enum Fonts {
    private static var registered = Set<String>()

    /// Resolve a font: a file path (registered on the fly), an installed font name, or the system font.
    public static func font(name: String?, size: CGFloat, weight: FontWeight = .regular, rounded: Bool = false, mono: Bool = false) -> CTFont {
        if let name, !name.isEmpty {
            if name.hasPrefix("/") || name.hasSuffix(".ttf") || name.hasSuffix(".otf") {
                let url = URL(fileURLWithPath: name)
                if !registered.contains(url.path) {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                    registered.insert(url.path)
                }
                if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = descs.first {
                    // Prefer a face whose weight matches.
                    let base = CTFontCreateWithFontDescriptor(d, size, nil)
                    return weighted(base, weight: weight, size: size)
                }
            } else {
                let f = CTFontCreateWithName(name as CFString, size, nil)
                return weighted(f, weight: weight, size: size)
            }
        }
        if mono { return NSFont.monospacedSystemFont(ofSize: size, weight: weight.ns) as CTFont }
        var f = NSFont.systemFont(ofSize: size, weight: weight.ns)
        if rounded, let d = f.fontDescriptor.withDesign(.rounded), let rf = NSFont(descriptor: d, size: size) { f = rf }
        return f as CTFont
    }

    private static func weighted(_ font: CTFont, weight: FontWeight, size: CGFloat) -> CTFont {
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight.ns.rawValue]
        let attrs: [CFString: Any] = [kCTFontTraitsAttribute: traits]
        let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font), attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(d, size, nil)
    }
}

public struct TextStyle {
    public var font: CTFont
    public var color: RGBA
    public var alignment: CTTextAlignment = .center
    public var lineHeight: CGFloat = 1.12
    public var tracking: CGFloat = 0
    public var shadow: (blur: CGFloat, alpha: CGFloat, dy: CGFloat)? = nil
    public init(font: CTFont, color: RGBA, alignment: CTTextAlignment = .center) {
        self.font = font; self.color = color; self.alignment = alignment
    }
}

public func attributed(_ text: String, _ style: TextStyle) -> NSAttributedString {
    var align = style.alignment
    let lh = CTFontGetSize(style.font) * style.lineHeight
    var minLH = lh, maxLH = lh
    let para = withUnsafeMutablePointer(to: &align) { ap in
        withUnsafeMutablePointer(to: &minLH) { mp in
            withUnsafeMutablePointer(to: &maxLH) { xp -> CTParagraphStyle in
                let settings: [CTParagraphStyleSetting] = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ap),
                    CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: mp),
                    CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: xp),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): style.font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cg,
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        NSAttributedString.Key(kCTKernAttributeName as String): style.tracking,
    ]
    return NSAttributedString(string: text, attributes: attrs)
}

/// Measure text laid out within maxWidth.
public func measureText(_ text: String, _ style: TextStyle, maxWidth: CGFloat) -> CGSize {
    let fs = CTFramesetterCreateWithAttributedString(attributed(text, style))
    let s = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                        CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
    return CGSize(width: ceil(s.width), height: ceil(s.height))
}

/// Draw text into a top-left-origin context inside `rect`.
public func drawText(_ ctx: CGContext, _ text: String, _ style: TextStyle, in rect: CGRect) {
    ctx.saveGState()
    if let sh = style.shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: -sh.dy), blur: sh.blur, color: CGColor(gray: 0, alpha: sh.alpha))
    }
    // CoreText draws in a bottom-left coordinate system; flip locally.
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    let fs = CTFramesetterCreateWithAttributedString(attributed(text, style))
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), transform: nil)
    let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, ctx)
    ctx.restoreGState()
}

/// Single-line text rendering helper; returns the drawn width.
@discardableResult
public func drawLine(_ ctx: CGContext, _ text: String, font: CTFont, color: RGBA, at origin: CGPoint, centeredIn width: CGFloat? = nil) -> CGFloat {
    let attr = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cg,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
    let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
    ctx.saveGState()
    var x = origin.x
    if let width { x = origin.x + (width - w) / 2 }
    // origin.y is the vertical CENTER of the line in top-left space.
    ctx.translateBy(x: x, y: origin.y + (asc - desc) / 2)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    return w
}

public func lineWidth(_ text: String, font: CTFont) -> CGFloat {
    let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let line = CTLineCreateWithAttributedString(attr)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

// MARK: - Image IO

public func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw fail("cannot write \(url.path)") }
}

public func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.88) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        throw fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw fail("cannot write \(url.path)") }
}

public func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary)
}
