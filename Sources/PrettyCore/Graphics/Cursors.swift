import Foundation
import CoreGraphics
import CoreImage

/// A rendered cursor sprite: image plus hotspot (pixels from top-left).
public struct CursorSprite {
    public var image: CIImage
    public var hotspot: CGPoint
    public var size: CGSize
    /// Pixels per cursor point this sprite was drawn at.
    public var scale: CGFloat
}

public final class CursorArt {
    public static let systemCursorDir = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors"

    static let pdfNames: [String: String] = [
        "pointer": "pointinghand", "hand": "pointinghand", "grab": "openhand", "grabbing": "closedhand",
        "crosshair": "cross", "notAllowed": "notallowed", "not-allowed": "notallowed", "copy": "copy", "move": "move",
        "ew-resize": "resizeeastwest", "col-resize": "resizeeastwest", "ns-resize": "resizenorthsouth", "row-resize": "resizenorthsouth",
        "nesw-resize": "resizenortheastsouthwest", "nwse-resize": "resizenorthwestsoutheast", "zoom-in": "zoomin", "zoom-out": "zoomout",
        "help": "help", "context-menu": "contextualmenu", "alias": "makealias",
    ]

    private var cache: [String: CursorSprite] = [:]
    private var pdfCache: [String: (CGPDFPage, CGPoint)] = [:]

    public init() {}

    /// Normalize CSS / NSCursor names to our kinds.
    public static func normalize(_ kind: String) -> String {
        switch kind.lowercased() {
        case "default", "auto", "arrow", "": return "arrow"
        case "pointer", "pointinghand", "hand", "link": return "pointer"
        case "text", "ibeam", "i-beam", "vertical-text": return "text"
        case "openhand": return "grab"
        case "closedhand": return "grabbing"
        default: return kind
        }
    }

    /// `pt`: output pixels per cursor point.
    public func sprite(kind rawKind: String, style: String, pt: CGFloat, shadow: Bool) -> CursorSprite {
        let kind = CursorArt.normalize(rawKind)
        let q = max(1, (pt * 4).rounded() / 4)
        let key = "\(kind)|\(style)|\(q)|\(shadow)"
        if let s = cache[key] { return s }
        let s: CursorSprite
        switch style {
        case "dot": s = circle(pt: q, diameter: 20, fill: RGBA(0.1, 0.1, 0.12, 0.62), ring: RGBA(1, 1, 1, 0.92), ringWidth: 2, shadow: shadow)
        case "touch": s = circle(pt: q, diameter: 40, fill: RGBA(1, 1, 1, 0.55), ring: RGBA(0, 0, 0, 0.22), ringWidth: 1.5, shadow: shadow)
        default:
            let inverted = style == "white"
            if kind == "text" { s = ibeam(pt: q, inverted: inverted, shadow: shadow) }
            else if kind != "arrow", let pdf = pdfSprite(kind, pt: q, inverted: inverted, shadow: shadow) { s = pdf }
            else { s = arrow(pt: q, inverted: inverted, shadow: shadow) }
        }
        cache[key] = s
        return s
    }

    // MARK: Procedural arrow (macOS pointer)

    private func arrow(pt k: CGFloat, inverted: Bool, shadow: Bool) -> CursorSprite {
        let pad: CGFloat = 4
        let w = Int(((13 + pad * 2) * k).rounded(.up)), h = Int(((20 + pad * 2) * k).rounded(.up))
        let pts: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15.6), CGPoint(x: 3.8, y: 12.1), CGPoint(x: 6.35, y: 17.9),
            CGPoint(x: 8.75, y: 16.85), CGPoint(x: 6.25, y: 11.15), CGPoint(x: 11.3, y: 11.15),
        ]
        let img = drawImage(width: w, height: h) { ctx in
            ctx.translateBy(x: (pad + 1) * k, y: (pad + 1) * k)
            ctx.scaleBy(x: k, y: k)
            let path = CGMutablePath(); path.addLines(between: pts); path.closeSubpath()
            ctx.saveGState()
            if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 1.0 * k), blur: 2.6 * k, color: CGColor(gray: 0, alpha: 0.42)) }
            ctx.addPath(path); ctx.setLineJoin(.round); ctx.setLineWidth(2.3)
            ctx.setStrokeColor(inverted ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)); ctx.strokePath()
            ctx.restoreGState()
            ctx.addPath(path); ctx.setLineJoin(.round); ctx.setLineWidth(2.3)
            ctx.setStrokeColor(inverted ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)); ctx.strokePath()
            ctx.addPath(path)
            ctx.setFillColor(inverted ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)); ctx.fillPath()
        }
        return CursorSprite(image: CIImage.from(img), hotspot: CGPoint(x: (pad + 1) * k, y: (pad + 1) * k),
                            size: CGSize(width: w, height: h), scale: k)
    }

    // MARK: I-beam

    private func ibeam(pt k: CGFloat, inverted: Bool, shadow: Bool) -> CursorSprite {
        let pad: CGFloat = 4
        let bw: CGFloat = 9, bh: CGFloat = 18
        let w = Int(((bw + pad * 2) * k).rounded(.up)), h = Int(((bh + pad * 2) * k).rounded(.up))
        let img = drawImage(width: w, height: h) { ctx in
            ctx.translateBy(x: pad * k, y: pad * k); ctx.scaleBy(x: k, y: k)
            let p = CGMutablePath()
            let cx = bw / 2
            p.move(to: CGPoint(x: 1, y: 0.5)); p.addQuadCurve(to: CGPoint(x: cx, y: 2.2), control: CGPoint(x: cx - 0.6, y: 0.5))
            p.addQuadCurve(to: CGPoint(x: bw - 1, y: 0.5), control: CGPoint(x: cx + 0.6, y: 0.5))
            p.move(to: CGPoint(x: cx, y: 2.2)); p.addLine(to: CGPoint(x: cx, y: bh - 2.2))
            p.move(to: CGPoint(x: 1, y: bh - 0.5)); p.addQuadCurve(to: CGPoint(x: cx, y: bh - 2.2), control: CGPoint(x: cx - 0.6, y: bh - 0.5))
            p.addQuadCurve(to: CGPoint(x: bw - 1, y: bh - 0.5), control: CGPoint(x: cx + 0.6, y: bh - 0.5))
            p.move(to: CGPoint(x: cx - 2.4, y: bh / 2)); p.addLine(to: CGPoint(x: cx + 2.4, y: bh / 2))
            ctx.setLineCap(.round)
            ctx.saveGState()
            if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 1 * k), blur: 2.2 * k, color: CGColor(gray: 0, alpha: 0.38)) }
            ctx.addPath(p); ctx.setLineWidth(3.1); ctx.setStrokeColor(inverted ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)); ctx.strokePath()
            ctx.restoreGState()
            ctx.addPath(p); ctx.setLineWidth(1.25); ctx.setStrokeColor(inverted ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)); ctx.strokePath()
        }
        return CursorSprite(image: CIImage.from(img), hotspot: CGPoint(x: (pad + bw / 2) * k, y: (pad + bh / 2) * k),
                            size: CGSize(width: w, height: h), scale: k)
    }

    // MARK: Circles (dot / touch)

    private func circle(pt k: CGFloat, diameter d: CGFloat, fill: RGBA, ring: RGBA, ringWidth: CGFloat, shadow: Bool) -> CursorSprite {
        let pad: CGFloat = 6
        let size = Int(((d + pad * 2) * k).rounded(.up))
        let img = drawImage(width: size, height: size) { ctx in
            let r = CGRect(x: pad * k, y: pad * k, width: d * k, height: d * k)
            ctx.saveGState()
            if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 1.5 * k), blur: 4 * k, color: CGColor(gray: 0, alpha: 0.3)) }
            ctx.setFillColor(fill.cg); ctx.fillEllipse(in: r)
            ctx.restoreGState()
            ctx.setStrokeColor(ring.cg); ctx.setLineWidth(ringWidth * k)
            ctx.strokeEllipse(in: r.insetBy(dx: ringWidth * k / 2, dy: ringWidth * k / 2))
        }
        let c = CGFloat(size) / 2
        return CursorSprite(image: CIImage.from(img), hotspot: CGPoint(x: c, y: c), size: CGSize(width: size, height: size), scale: k)
    }

    // MARK: System vector cursors

    private func pdfPage(_ name: String) -> (CGPDFPage, CGPoint)? {
        if let c = pdfCache[name] { return c }
        let fm = FileManager.default
        for dir in ["\(Self.systemCursorDir)/macos27/\(name)", "\(Self.systemCursorDir)/\(name)"] where fm.fileExists(atPath: dir + "/cursor.pdf") {
            guard let doc = CGPDFDocument(URL(fileURLWithPath: dir + "/cursor.pdf") as CFURL), let page = doc.page(at: 1) else { continue }
            var hot = CGPoint(x: 8, y: 8)
            if let plist = NSDictionary(contentsOfFile: dir + "/info.plist") {
                hot.x = (plist["hotx"] as? NSNumber)?.doubleValue ?? 8
                hot.y = (plist["hoty"] as? NSNumber)?.doubleValue ?? 8
            }
            pdfCache[name] = (page, hot)
            return (page, hot)
        }
        return nil
    }

    private func pdfSprite(_ kind: String, pt k: CGFloat, inverted: Bool, shadow: Bool) -> CursorSprite? {
        guard let name = Self.pdfNames[kind], let (page, hot) = pdfPage(name) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let pad: CGFloat = 4
        let w = Int(((box.width + pad * 2) * k).rounded(.up)), h = Int(((box.height + pad * 2) * k).rounded(.up))
        let img = drawImage(width: w, height: h) { ctx in
            ctx.saveGState()
            // PDF space is bottom-left; our context is top-left.
            ctx.translateBy(x: pad * k, y: (pad + box.height) * k)
            ctx.scaleBy(x: k, y: -k)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -1.0), blur: 2.4 * k, color: CGColor(gray: 0, alpha: 0.42)) }
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.drawPDFPage(page)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        var ci = CIImage.from(img)
        if inverted {
            // Swap black/white while keeping alpha (unpremultiply → invert → premultiply).
            ci = ci.unpremultiplyingAlpha().applyingFilter("CIColorInvert").premultiplyingAlpha()
        }
        return CursorSprite(image: ci, hotspot: CGPoint(x: (pad + hot.x) * k, y: (pad + hot.y) * k),
                            size: CGSize(width: w, height: h), scale: k)
    }
}

/// Pre-rendered click ripple animation frames.
public final class RippleArt {
    public static let steps = 28
    public static let canvas = 384
    private var cache: [String: CIImage] = [:]
    public init() {}

    /// Ripple frame for progress p (0-1). The canvas spans 2x the max radius.
    public func frame(progress p: Double, color: RGBA, style: String) -> CIImage {
        let step = Int((clamp(p, 0, 1) * Double(Self.steps - 1)).rounded())
        let key = "\(color.r),\(color.g),\(color.b)|\(style)|\(step)"
        if let c = cache[key] { return c }
        let q = Double(step) / Double(Self.steps - 1)
        let n = Self.canvas
        let img = drawImage(width: n, height: n) { ctx in
            let R = CGFloat(n) / 2 - 4
            let e = easeOutCubic(q)
            let r = R * CGFloat(0.22 + 0.78 * e)
            let fade = CGFloat(pow(1 - q, 1.5))
            let c = CGPoint(x: CGFloat(n) / 2, y: CGFloat(n) / 2)
            if style == "filled" {
                ctx.setFillColor(color.with(alpha: 0.38 * fade).cg)
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            let lw = R * CGFloat(0.11 * (1 - 0.55 * q))
            ctx.setStrokeColor(color.with(alpha: 0.92 * fade).cg); ctx.setLineWidth(lw)
            ctx.strokeEllipse(in: CGRect(x: c.x - r + lw / 2, y: c.y - r + lw / 2, width: r * 2 - lw, height: r * 2 - lw))
        }
        let ci = CIImage.from(img)
        cache[key] = ci
        return ci
    }
}
