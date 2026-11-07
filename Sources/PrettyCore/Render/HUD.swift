import Foundation
import CoreGraphics
import CoreImage
import CoreText

/// Screen-space overlays drawn after the camera (they don't zoom): text, captions,
/// keystrokes, logos. Everything is rasterized once with CoreText and cached.
public final class HUD {
    let W: CGFloat, H: CGFloat, S: CGFloat
    let portrait: Bool
    let darkBackground: Bool
    let brand: BrandSpec
    let baseURL: URL?
    /// Where the recording sits at rest; top/bottom text centers in the free band around it.
    public var contentRest: CGRect?
    /// Text-safe area (fractions top, bottom, left, right).
    public var safe: [Double] = [0, 0, 0, 0]

    /// Keep a text block (center p, size sz) inside the safe area when it fits.
    func clampSafe(_ p: CGPoint, _ sz: CGSize) -> CGPoint {
        guard safe.count == 4, safe.contains(where: { $0 > 0 }) else { return p }
        let top = CGFloat(safe[0]) * H, bottom = H - CGFloat(safe[1]) * H
        let left = CGFloat(safe[2]) * W, right = W - CGFloat(safe[3]) * W
        var q = p
        if bottom - top >= sz.height { q.y = clamp(q.y, top + sz.height / 2, bottom - sz.height / 2) }
        if right - left >= sz.width { q.x = clamp(q.x, left + sz.width / 2, right - sz.width / 2) }
        return q
    }
    private var cache: [String: CIImage] = [:]

    public init(output: CGSize, darkBackground: Bool, brand: BrandSpec, baseURL: URL?) {
        W = output.width; H = output.height; S = min(W, H)
        portrait = H / W > 1.3
        self.darkBackground = darkBackground
        self.brand = brand
        self.baseURL = baseURL
    }

    // MARK: Text overlays

    struct StyleDef { var size: CGFloat; var weight: FontWeight; var pill: Bool; var tracking: CGFloat; var upper: Bool; var alpha: CGFloat }
    func styleDef(_ name: String) -> StyleDef {
        switch name {
        case "subtitle": return StyleDef(size: 0.04, weight: .medium, pill: false, tracking: 0, upper: false, alpha: 0.86)
        case "kicker": return StyleDef(size: 0.026, weight: .bold, pill: false, tracking: 0.12, upper: true, alpha: 0.75)
        case "caption": return StyleDef(size: 0.036, weight: .semibold, pill: true, tracking: 0, upper: false, alpha: 1)
        case "label": return StyleDef(size: 0.03, weight: .semibold, pill: true, tracking: 0, upper: false, alpha: 1)
        case "hero": return StyleDef(size: 0.095, weight: .heavy, pill: false, tracking: -0.025, upper: false, alpha: 1)
        default: return StyleDef(size: 0.068, weight: .bold, pill: false, tracking: -0.018, upper: false, alpha: 1)
        }
    }

    func textImage(_ o: Overlay, text: String) -> CIImage {
        let key = "t|\(o.style)|\(o.size)|\(o.color)|\(o.fill ?? "")|\(o.font ?? brand.font ?? "")|\(o.weight ?? "")|\(o.maxWidth)|\(text)"
        if let c = cache[key] { return c }
        let d = styleDef(o.style)
        let size = S * d.size * CGFloat(o.size)
        let weight = o.weight.flatMap(FontWeight.init(rawValue:)) ?? d.weight
        let font = Fonts.font(name: o.font ?? brand.font, size: size, weight: weight, rounded: false)
        let fillColor: RGBA? = {
            if let f = o.fill { return RGBA.parse(f, brand: brand.colors) }
            if d.pill { return o.style == "label" ? (RGBA.parse("brand:0", brand: brand.colors) ?? RGBA.hex("#3B82F6")) : RGBA(0.08, 0.08, 0.1, 0.78) }
            return nil
        }()
        var color: RGBA
        if o.color == "auto" {
            if let f = fillColor { color = f.luminance > 0.6 && f.a > 0.5 ? RGBA.hex("#111114") : RGBA(1, 1, 1) }
            else { color = darkBackground ? RGBA(1, 1, 1) : RGBA.hex("#111114") }
        } else { color = RGBA.parse(o.color, brand: brand.colors) ?? RGBA(1, 1, 1) }
        color = color.with(alpha: color.a * d.alpha)
        var style = TextStyle(font: font, color: color, alignment: .center)
        style.tracking = d.tracking * size
        style.lineHeight = o.style == "title" || o.style == "hero" ? 1.06 : 1.18
        if fillColor == nil && darkBackground && o.color == "auto" { style.shadow = (blur: size * 0.25, alpha: 0.25, dy: size * 0.04) }
        let str = d.upper ? text.uppercased() : text
        let maxW = W * CGFloat(o.maxWidth)
        let ts = measureText(str, style, maxWidth: maxW)
        let padX = fillColor != nil ? size * 0.75 : size * 0.3, padY = fillColor != nil ? size * 0.42 : size * 0.3
        let iw = Int(ts.width + padX * 2 + 2), ih = Int(ts.height + padY * 2 + 2)
        let cg = drawImage(width: iw, height: ih) { ctx in
            if let f = fillColor {
                let r = CGRect(x: 0.5, y: 0.5, width: CGFloat(iw) - 1, height: CGFloat(ih) - 1)
                ctx.addPath(roundedRect(r, min(r.height / 2, size * 0.9)))
                ctx.setFillColor(f.cg); ctx.fillPath()
            }
            drawText(ctx, str, style, in: CGRect(x: padX, y: padY, width: ts.width + 1, height: ts.height + 1))
        }
        let img = CIImage.from(cg)
        cache[key] = img
        return img
    }

    /// Anchor point (center of the text block) in top-left output coords.
    func anchor(_ o: Overlay, size: CGSize) -> CGPoint {
        if let x = o.x, let y = o.y { return CGPoint(x: x * W, y: y * H) }
        let topY = portrait ? 0.14 * H : 0.075 * H
        let botY = portrait ? 0.8 * H : 0.925 * H
        let pos = o.position
        var p = CGPoint(x: W / 2, y: H / 2)
        // Text in the band around the device sits in the middle of the band's usable part
        // (between the platform's safe edge and the device), with equal air above and below.
        let safeTop = CGFloat(safe.count == 4 ? safe[0] : 0) * H, safeBottom = H - CGFloat(safe.count == 4 ? safe[1] : 0) * H
        if pos.hasPrefix("top") {
            p.y = topY + size.height / 2
            if let r = contentRest, r.minY - safeTop >= size.height + 0.025 * H { p.y = (max(safeTop, 0.02 * H) + r.minY) / 2 }
        }
        if pos.hasPrefix("bottom") {
            p.y = botY - size.height / 2
            if let r = contentRest, safeBottom - r.maxY >= size.height + 0.025 * H { p.y = (r.maxY + min(safeBottom, H - 0.02 * H)) / 2 }
        }
        if pos.hasSuffix("left") { p.x = 0.06 * W + size.width / 2 }
        if pos.hasSuffix("right") { p.x = 0.94 * W - size.width / 2 }
        if let x = o.x { p.x = x * W }
        if let y = o.y { p.y = y * H }
        return clampSafe(p, size)
    }

    /// Render one text/image overlay at time `t` (seconds into the overlay's own time base).
    /// Overlays whose text would sit on top of the recording get a readable pill (decided once).
    private var pillDecision: [String: Bool] = [:]

    public func overlay(_ o: Overlay, t: Double, contentRect: CGRect? = nil) -> CIImage? {
        guard t >= o.start - 0.001, t <= o.end + 0.001 else { return nil }
        var o = o
        // Top/bottom text that would overflow its band (headroom/footroom) shrinks to fit it.
        if o.type == "text", o.x == nil, o.y == nil, let r = contentRest, let text = o.text,
           o.position.hasPrefix("top") || o.position.hasPrefix("bottom") {
            let top = o.position.hasPrefix("top")
            let band = top ? r.minY - CGFloat(safe[0]) * H : (H - r.maxY) - CGFloat(safe[1]) * H
            let usable = band - 0.025 * H
            if usable > 0.05 * H {
                let h = textImage(o, text: text).extent.height
                if h > usable { o.size *= Double(max(0.55, usable / h)) }
            }
        }
        // Headlines live in the band around the device; when the content moves into it (a zoom),
        // the headline steps aside instead of colliding with it.
        var stepAside: CGFloat = 1
        if o.id == "headline", let cr = contentRect, let text = o.text {
            let img = textImage(o, text: text)
            let a = anchor(o, size: img.extent.size)
            let r = CGRect(x: a.x - img.extent.width / 2, y: a.y - img.extent.height / 2, width: img.extent.width, height: img.extent.height)
            let inter = r.intersection(cr)
            let frac = inter.isNull ? 0 : inter.width * inter.height / max(1, r.width * r.height)
            stepAside = 1 - CGFloat(smoothstep(Double(frac) / 0.2))
            if stepAside <= 0.01 { return nil }
        }
        if o.type == "text", o.id != "headline", o.fill == nil, o.color == "auto", ["title", "hero", "subtitle", "kicker"].contains(o.style),
           let cr = contentRect, let text = o.text {
            let key = "\(o.start)|\(text)"
            let needs: Bool
            if let d = pillDecision[key] { needs = d } else {
                let img = textImage(o, text: text)
                let a = anchor(o, size: img.extent.size)
                let r = CGRect(x: a.x - img.extent.width / 2, y: a.y - img.extent.height / 2, width: img.extent.width, height: img.extent.height)
                let inter = r.intersection(cr)
                needs = !inter.isNull && inter.width * inter.height > 0.15 * r.width * r.height
                pillDecision[key] = needs
            }
            if needs { o.fill = "#101014B8"; o.color = "white" }
        }
        let local = t - o.start, remain = o.end - t
        let inDur = min(0.5, (o.end - o.start) / 3), outDur = min(0.32, (o.end - o.start) / 4)
        let pIn = inDur > 0 ? clamp(local / inDur, 0, 1) : 1
        let pOut = outDur > 0 ? clamp(remain / outDur, 0, 1) : 1
        var img: CIImage
        if o.type == "image" {
            guard let path = o.path ?? brand.logo, let cg = loadCGImage(Backgrounds.resolve(path, baseURL)) else { return nil }
            let key = "i|\(path)|\(o.width)"
            if let c = cache[key] { img = c } else {
                let src = CIImage(cgImage: cg)
                let s = W * CGFloat(o.width) / src.extent.width
                img = src.transformed(by: CGAffineTransform(scaleX: s, y: s))
                cache[key] = img
            }
        } else {
            guard let text = o.text, !text.isEmpty else { return nil }
            if o.animation == "typewriter" {
                let chars = Array(text)
                let dur = min(1.6, 0.05 * Double(chars.count))
                let n = max(1, Int((Double(chars.count) * clamp(local / max(dur, 0.01), 0, 1)).rounded(.up)))
                let full = textImage(o, text: text)
                let part = n >= chars.count ? full : textImage(o, text: String(chars.prefix(n)))
                // Left-align the growing prefix inside the final block so letters don't shift.
                let a = anchor(o, size: full.extent.size)
                let x = a.x - full.extent.width / 2, yTop = a.y - full.extent.height / 2
                return part.transformed(by: CGAffineTransform(translationX: x, y: H - yTop - part.extent.height)).opacity(CGFloat(pOut))
            }
            img = textImage(o, text: text)
        }
        let sz = img.extent.size
        let a = anchor(o, size: sz)
        var tx = a.x - sz.width / 2, tyTop = a.y - sz.height / 2
        var scale: CGFloat = 1
        var alpha = CGFloat(min(pIn, pOut))
        switch o.animation {
        case "none": alpha = 1
        case "rise":
            tyTop += (1 - CGFloat(easeOutCubic(pIn))) * S * 0.035
            tyTop -= (1 - CGFloat(pOut)) * S * 0.01
        case "pop":
            scale = 0.86 + 0.14 * CGFloat(easeOutBack(pIn, 1.6))
            alpha = CGFloat(min(clamp(local / 0.18, 0, 1), pOut))
        case "slide":
            tx -= (1 - CGFloat(easeOutCubic(pIn))) * W * 0.05
        default: break
        }
        var out = img
        if scale != 1 {
            out = out.transformed(by: CGAffineTransform(translationX: -sz.width / 2, y: -sz.height / 2)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: sz.width / 2, y: sz.height / 2)))
        }
        out = out.transformed(by: CGAffineTransform(translationX: tx, y: H - tyTop - sz.height))
        return out.opacity(alpha * stepAside)
    }

    // MARK: Captions

    public func caption(_ text: String, spec: CaptionSpec, t: Double, start: Double, end: Double) -> CIImage {
        var o = Overlay()
        o.type = "text"; o.text = text; o.start = start; o.end = end
        o.size = spec.size; o.animation = "none"
        switch spec.style {
        case "plain":
            o.style = "subtitle"; o.color = "white"
        case "bar":
            o.style = "caption"; o.fill = spec.theme == "light" ? "#FFFFFFEE" : "#000000C8"; o.color = spec.theme == "light" ? "#111114" : "white"
        default:
            o.style = "caption"; o.fill = spec.theme == "light" ? "#FFFFFFE6" : "#141418D0"; o.color = spec.theme == "light" ? "#111114" : "white"
        }
        o.maxWidth = portrait ? 0.84 : 0.7
        o.position = spec.position
        if spec.position == "bottom" { o.y = portrait ? 0.72 : 0.86 }
        let img = textImage(o, text: text)
        let sz = img.extent.size
        let a = anchor(o, size: sz)
        let fade = CGFloat(min(clamp((t - start) / 0.12, 0, 1), clamp((end - t) / 0.12, 0, 1)))
        return img.transformed(by: CGAffineTransform(translationX: a.x - sz.width / 2, y: H - (a.y - sz.height / 2) - sz.height)).opacity(fade)
    }

    // MARK: Keystrokes

    func keystrokeImage(_ caps: [String], spec: KeystrokeSpec, typing: Bool) -> CIImage {
        let key = "k|\(caps.joined(separator: "\u{1}"))|\(spec.theme)|\(spec.size)|\(typing)"
        if let c = cache[key] { return c }
        let dark = spec.theme != "light"
        let h = S * 0.062 * CGFloat(spec.size)
        let fs = h * 0.42
        let font = Fonts.font(name: nil, size: fs, weight: .semibold)
        let pad = h * 0.16, gap = h * 0.1
        let capH = h - pad * 2
        var widths: [CGFloat] = caps.map { max(capH, lineWidth($0, font: font) + capH * 0.62) }
        if typing { widths = [lineWidth(caps.first ?? "", font: font) + h * 0.5] }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)) + pad * 2
        let shadowPad = h * 0.4
        let iw = Int(total + shadowPad * 2), ih = Int(h + shadowPad * 2)
        let cg = drawImage(width: iw, height: ih) { ctx in
            let pill = CGRect(x: shadowPad, y: shadowPad, width: total, height: h)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.06), blur: h * 0.35, color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(roundedRect(pill, h * 0.28))
            ctx.setFillColor((dark ? RGBA(0.11, 0.11, 0.12, 0.9) : RGBA(1, 1, 1, 0.94)).cg); ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(roundedRect(pill.insetBy(dx: 0.5, dy: 0.5), h * 0.28))
            ctx.setStrokeColor((dark ? RGBA(1, 1, 1, 0.1) : RGBA(0, 0, 0, 0.08)).cg); ctx.setLineWidth(1); ctx.strokePath()
            var x = pill.minX + pad
            let ink = dark ? RGBA(1, 1, 1) : RGBA.hex("#1C1C1E")
            for (i, c) in caps.enumerated() {
                let w = widths[i]
                let r = CGRect(x: x, y: pill.minY + pad, width: w, height: capH)
                if !typing {
                    ctx.addPath(roundedRect(r, capH * 0.24))
                    ctx.setFillColor((dark ? RGBA(1, 1, 1, 0.13) : RGBA(0, 0, 0, 0.065)).cg); ctx.fillPath()
                }
                drawLine(ctx, c, font: font, color: ink, at: CGPoint(x: r.minX, y: r.midY), centeredIn: r.width)
                x += w + gap
            }
        }
        let img = CIImage.from(cg)
        cache[key] = img
        return img
    }

    public func keystrokes(_ item: KeystrokeItem, s: Double, spec: KeystrokeSpec) -> CIImage? {
        guard s >= item.start, s <= item.end else { return nil }
        let caps = item.caps(at: s)
        guard !caps.isEmpty, !(caps.first ?? "").isEmpty else { return nil }
        let img = keystrokeImage(caps, spec: spec, typing: item.isTyping)
        let sz = img.extent.size
        let pIn = clamp((s - item.start) / 0.16, 0, 1), pOut = clamp((item.end - s) / 0.25, 0, 1)
        let scale = item.isTyping ? 1 : 0.9 + 0.1 * CGFloat(easeOutBack(pIn, 1.8))
        let margin = S * 0.045
        var cx = W / 2
        if spec.position.hasSuffix("left") { cx = margin + sz.width / 2 }
        if spec.position.hasSuffix("right") { cx = W - margin - sz.width / 2 }
        let top = spec.position.hasPrefix("top")
        var cyTop = top ? margin + (portrait ? H * 0.08 : 0) : H - margin - sz.height - (portrait ? H * 0.12 : 0)
        let c = clampSafe(CGPoint(x: cx, y: cyTop + sz.height / 2), sz)
        cx = c.x; cyTop = c.y - sz.height / 2
        let out = img.transformed(by: CGAffineTransform(translationX: -sz.width / 2, y: -sz.height / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: cx, y: H - cyTop - sz.height / 2)))
        return out.opacity(CGFloat(min(clamp((s - item.start) / 0.1, 0, 1), pOut)))
    }
}

// MARK: - SRT

public func parseSRT(_ text: String) -> [CaptionItem] {
    var items: [CaptionItem] = []
    let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
    func ts(_ s: String) -> Double? {
        let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
    for b in blocks {
        let lines = b.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let tl = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
        let parts = lines[tl].components(separatedBy: "-->")
        guard parts.count == 2, let a = ts(parts[0]), let e = ts(parts[1]) else { continue }
        let text = lines[(tl + 1)...].joined(separator: "\n")
        if !text.isEmpty { items.append(CaptionItem(start: a, end: e, text: text)) }
    }
    return items
}
