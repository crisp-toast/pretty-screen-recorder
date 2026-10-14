import Foundation
import CoreGraphics
import CoreImage
import CoreText
import AppKit
import AVFoundation

/// Full-screen kinetic typography: the moments where the device steps aside and the words carry
/// the story. Restrained by design — line reveals with soft blur, two-tone white/gray, exact
/// CoreText spacing, no bounces or highlighter gimmicks unless asked for. Rendered in output space.
public final class Kinetic {
    let W: CGFloat, H: CGFloat, S: CGFloat
    let portrait: Bool
    let brand: BrandSpec
    let baseURL: URL?
    public var safe: [Double] = [0, 0, 0, 0]

    private var images: [String: CIImage] = [:]
    private var layouts: [String: Layout] = [:]
    private var iconImage: [String: (CIImage, CIImage)] = [:]
    private var clips: [String: ClipFrames] = [:]

    public init(output: CGSize, brand: BrandSpec, baseURL: URL?) {
        W = output.width; H = output.height; S = min(W, H)
        portrait = H / W > 1.3
        self.brand = brand
        self.baseURL = baseURL
    }

    // MARK: Color

    struct Palette {
        var text: RGBA
        var secondary: RGBA
        var accent: RGBA
        var markerFill: RGBA
        var markerText: RGBA
        var dark: Bool
    }

    var brandColors: [RGBA] {
        var cs = brand.colors.compactMap { RGBA.parse($0) }
        if cs.isEmpty { cs = [RGBA.hex("#0A84FF")] }
        // A single-hue brand gets an analogous partner so light has depth.
        if cs.count == 1 || cs.dropFirst().allSatisfy({ abs($0.r - cs[0].r) + abs($0.g - cs[0].g) + abs($0.b - cs[0].b) < 0.3 }) {
            cs.insert(Kinetic.rotateHue(cs[0], by: 0.09), at: 1)
        }
        return cs
    }

    public static func lighten(_ c: RGBA, to lum: CGFloat) -> RGBA {
        var x = c, i = 0
        while x.luminance < lum && i < 24 { x = x.mixed(RGBA(1, 1, 1), 0.1); i += 1 }
        return x
    }

    public static func darken(_ c: RGBA, to lum: CGFloat) -> RGBA {
        var x = c, i = 0
        while x.luminance > lum && i < 24 { x = x.mixed(RGBA(0, 0, 0), 0.1); i += 1 }
        return x
    }

    static func rotateHue(_ c: RGBA, by d: CGFloat) -> RGBA {
        let ns = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let r = NSColor(hue: (h + d).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB)!
        return RGBA(r.redComponent, r.greenComponent, r.blueComponent)
    }

    func palette(_ s: TextScene) -> Palette {
        let cs = brandColors
        let primary = cs[0]
        let light = Kinetic.lighten(primary, to: 0.5), deep = Kinetic.darken(primary, to: 0.36)
        var p: Palette
        let bg = s.background.hasPrefix("clip:") ? "content" : s.background
        switch bg {
        case "studio", "light", "white":
            p = Palette(text: .hex("#1D1D1F"), secondary: .hex("#6E6E73"), accent: deep, markerFill: Kinetic.lighten(primary, to: 0.82), markerText: .hex("#1D1D1F"), dark: false)
        case "paper":
            p = Palette(text: .hex("#121212"), secondary: .hex("#77736B"), accent: deep, markerFill: Kinetic.lighten(primary, to: 0.82), markerText: .hex("#121212"), dark: false)
        case "cinema":
            p = Palette(text: .hex("#EFEAE2"), secondary: .hex("#8E8A84"), accent: Kinetic.lighten(primary, to: 0.55), markerFill: .hex("#EFEAE2"), markerText: .hex("#0B0B0C"), dark: true)
        case "glow", "brand":
            p = Palette(text: RGBA(1, 1, 1), secondary: RGBA(1, 1, 1, 0.56), accent: Kinetic.lighten(primary, to: 0.62), markerFill: RGBA(1, 1, 1), markerText: Kinetic.darken(primary, to: 0.2), dark: true)
        case "content":
            p = Palette(text: RGBA(1, 1, 1), secondary: RGBA(1, 1, 1, 0.68), accent: light, markerFill: RGBA(1, 1, 1), markerText: .hex("#111114"), dark: true)
        case "keynote", "dark", "black":
            p = Palette(text: .hex("#F5F5F7"), secondary: .hex("#86868B"), accent: light, markerFill: primary, markerText: RGBA(1, 1, 1), dark: true)
        default:
            let c = RGBA.parse(bg, brand: brand.colors)
            let dark = c.map { $0.luminance < 0.55 } ?? (Backgrounds.preset(bg)?.dark ?? true)
            p = dark ? Palette(text: RGBA(1, 1, 1), secondary: RGBA(1, 1, 1, 0.6), accent: light, markerFill: RGBA(1, 1, 1), markerText: .hex("#111114"), dark: true)
                     : Palette(text: .hex("#1D1D1F"), secondary: .hex("#6E6E73"), accent: deep, markerFill: Kinetic.lighten(primary, to: 0.82), markerText: .hex("#1D1D1F"), dark: false)
        }
        if let c = s.color.flatMap({ RGBA.parse($0, brand: brand.colors) }) { p.text = c }
        if let c = s.accentColor.flatMap({ RGBA.parse($0, brand: brand.colors) }) { p.accent = c; p.markerFill = c }
        return p
    }

    // MARK: Backgrounds

    /// The scene backdrop: a lit stage (slowly breathing), a blurred recording, or a video clip.
    func background(_ s: TextScene, t: Double, content: (() -> CIImage)?) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        let lt = t - s.start
        if s.background.hasPrefix("clip:") {
            let path = String(s.background.dropFirst(5))
            if let frame = clipFrame(path, at: s.clipStart + max(0, lt)) {
                // Aspect-fill with a slow push, then a soft scrim so type always reads.
                let e = frame.extent
                let k = max(W / e.width, H / e.height) * (1.0 + 0.05 * CGFloat(clamp(lt / max(s.duration, 0.1), 0, 1)))
                var img = frame.transformed(by: CGAffineTransform(scaleX: k, y: k))
                img = img.transformed(by: CGAffineTransform(translationX: (W - img.extent.width) / 2 - img.extent.minX, y: (H - img.extent.height) / 2 - img.extent.minY))
                let scrim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.32)).cropped(to: full)
                return scrim.over(img).cropped(to: full)
            }
        }
        switch s.background {
        case "content":
            if let c = content?() {
                return c.applyingFilter("CIColorControls", parameters: ["inputBrightnessKey": -0.22, "inputSaturationKey": 1.05]).cropped(to: full)
            }
            return stageImage("keynote", t: lt)
        case "keynote", "studio", "glow", "paper", "cinema":
            return stageImage(s.background, t: lt)
        case "dark", "black": return stageImage("keynote", t: lt)
        case "light", "white": return stageImage("studio", t: lt)
        case "brand": return stageImage("glow", t: lt)
        default:
            if let c = RGBA.parse(s.background, brand: brand.colors) { return CIImage(color: CIColor(cgColor: c.cg)).cropped(to: full) }
            let key = "bg|\(s.background)"
            if let c = images[key] { return c }
            var spec = BackgroundSpec(); spec.type = "gradient"; spec.preset = s.background
            let img = Backgrounds.render(spec, size: CGSize(width: W, height: H), brand: brand.colors, baseURL: baseURL)
            images[key] = img
            return img
        }
    }

    /// Stages breathe very slowly (a lit set, not a still): 3% over ten seconds.
    func stageImage(_ name: String, t: Double) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        let key = "stage|\(name)"
        let base: CIImage
        if let c = images[key] { base = c } else {
            base = Backgrounds.stage(name, size: CGSize(width: W, height: H), brand: brand.colors, focus: CGPoint(x: 0.5, y: 0.44))
            images[key] = base
        }
        let k = 1.0 + 0.03 * CGFloat(clamp(t / 10, 0, 1))
        return base.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2).concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))).cropped(to: full)
    }

    func clipFrame(_ path: String, at t: Double) -> CIImage? {
        let url = Backgrounds.resolve(path, baseURL)
        if clips[url.path] == nil { clips[url.path] = ClipFrames(url: url) }
        return clips[url.path]?.frame(at: t)
    }

    // MARK: Type

    struct Word {
        var text: String
        var x: CGFloat
        var width: CGFloat
        var baseline: CGFloat
        var line: Int
        /// 0 primary, 1 secondary, 2 accent
        var tone: Int
    }
    struct Layout {
        var words: [Word]
        var font: CTFont
        var size: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var cap: CGFloat
        var leading: CGFloat
        var lineCount: Int
        /// Top-left rect of the ink block (cap height of line 1 to the last baseline + descent).
        var block: CGRect
    }

    var safeRect: CGRect {
        let s = safe.count == 4 ? safe : [0, 0, 0, 0]
        let top = CGFloat(s[0]) * H, bottom = CGFloat(s[1]) * H, left = CGFloat(s[2]) * W, right = CGFloat(s[3]) * W
        let margin = S * 0.075
        return CGRect(x: left + margin, y: top + margin * 0.6, width: W - left - right - margin * 2, height: H - top - bottom - margin * 1.2)
    }

    func font(_ s: TextScene, size: CGFloat, weight: FontWeight, digits: Bool = false) -> CTFont {
        var f: CTFont
        let name = s.font ?? brand.font
        switch name {
        case "mono": f = NSFont.monospacedSystemFont(ofSize: size, weight: weight.ns) as CTFont
        case "rounded": f = Fonts.font(name: nil, size: size, weight: weight, rounded: true)
        case "serif":
            let base = NSFont.systemFont(ofSize: size, weight: weight.ns)
            f = (base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
        case "system", "sf": f = Fonts.font(name: nil, size: size, weight: weight)
        default:
            let resolved = name.map { ($0.hasSuffix(".ttf") || $0.hasSuffix(".otf")) && !$0.hasPrefix("/") ? Backgrounds.resolve($0, baseURL).path : $0 }
            f = Fonts.font(name: resolved, size: size, weight: weight)
        }
        if digits {
            let feat: [[CFString: Any]] = [[kCTFontFeatureTypeIdentifierKey: kNumberSpacingType, kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]]
            let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(f), [kCTFontFeatureSettingsAttribute: feat] as CFDictionary)
            f = CTFontCreateWithFontDescriptor(d, size, nil)
        }
        return f
    }

    /// Display tracking: tighter as type gets bigger (SF Pro Display at hero sizes is about -0.022em).
    func tracking(_ size: CGFloat) -> CGFloat {
        let rel = size / S
        return -size * (rel > 0.09 ? 0.024 : rel > 0.05 ? 0.016 : rel > 0.03 ? 0.006 : 0)
    }

    func attributed(_ text: String, _ f: CTFont, _ size: CGFloat, _ color: RGBA? = nil) -> NSAttributedString {
        var a: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking(size),
        ]
        if let c = color { a[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = c.cg }
        return NSAttributedString(string: text, attributes: a)
    }

    func width(_ text: String, _ f: CTFont, _ size: CGFloat) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(text, f, size)), nil, nil, nil))
    }

    static func norm(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Typeset `raw` words: greedy breaking, shrink-to-fit, balanced lines, then each word's exact
    /// position from CoreText (so spacing and kerning match a normally set line).
    func layout(_ s: TextScene, key: String, words raw: [String], forcedLines: [[String]]? = nil, base: CGFloat, weight: FontWeight,
                maxLines: Int, maxWidth: CGFloat, maxHeight: CGFloat, leading: CGFloat = 1.08, align: String, centerY: CGFloat? = nil) -> Layout {
        let cacheKey = "\(key)|\(raw.joined(separator: " "))|\(base)|\(maxWidth)|\(align)|\(centerY ?? -1)"
        if let l = layouts[cacheKey] { return l }
        let accentSet = Set(s.accent.flatMap { $0.split(separator: " ").map { Kinetic.norm(String($0)) } })
        let secondarySet = Set(s.secondary.flatMap { $0.split(separator: " ").map { Kinetic.norm(String($0)) } })
        var size = base
        var lines: [[String]] = []
        var f = font(s, size: size, weight: weight)
        func lineWidth(_ l: [String]) -> CGFloat { width(l.joined(separator: " "), f, size) }
        func breakLines(_ limit: CGFloat) -> [[String]] {
            var out: [[String]] = [], cur: [String] = []
            for w in raw {
                if !cur.isEmpty && lineWidth(cur + [w]) > limit { out.append(cur); cur = [w] } else { cur.append(w) }
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
        for _ in 0..<40 {
            f = font(s, size: size, weight: weight)
            lines = forcedLines ?? breakLines(maxWidth)
            let widest = lines.map(lineWidth).max() ?? 0
            let height = CGFloat(max(0, lines.count - 1)) * size * leading + size
            if lines.count <= maxLines && widest <= maxWidth + 0.5 && height <= maxHeight {
                if forcedLines == nil && lines.count >= 2 {
                    var lo = maxWidth * 0.4, hi = maxWidth
                    for _ in 0..<14 { let mid = (lo + hi) / 2; if breakLines(mid).count <= lines.count { hi = mid } else { lo = mid } }
                    lines = breakLines(hi)
                }
                break
            }
            size *= 0.94
            if size < base * 0.3 { break }
        }
        let d = CTFontGetDescent(f), a = CTFontGetAscent(f), cap = CTFontGetCapHeight(f)
        let lh = size * leading
        let blockH = CGFloat(lines.count - 1) * lh + cap
        let sr = safeRect
        let cy = centerY ?? (sr.midY - H * 0.015)
        var top = cy - blockH / 2
        if centerY == nil { top = max(sr.minY, min(top, sr.maxY - blockH - d)) }
        var words: [Word] = []
        var minX = CGFloat.greatestFiniteMagnitude, maxX: CGFloat = 0
        let leftX = sr.minX + (sr.width - maxWidth) / 2
        for (li, line) in lines.enumerated() {
            let text = line.joined(separator: " ")
            let ctl = CTLineCreateWithAttributedString(attributed(text, f, size))
            let lw = CGFloat(CTLineGetTypographicBounds(ctl, nil, nil, nil))
            let x0 = align == "left" ? leftX : (W - lw) / 2
            let baseline = top + cap + CGFloat(li) * lh
            var idx = 0
            for w in line {
                let len = (w as NSString).length
                let start = CTLineGetOffsetForStringIndex(ctl, idx, nil)
                let end = CTLineGetOffsetForStringIndex(ctl, idx + len, nil)
                let n = Kinetic.norm(w)
                let tone = accentSet.contains(n) ? 2 : secondarySet.contains(n) ? 1 : 0
                words.append(Word(text: w, x: x0 + start, width: end - start, baseline: baseline, line: li, tone: tone))
                minX = min(minX, x0 + start); maxX = max(maxX, x0 + end)
                idx += len + 1
            }
        }
        _ = a
        let l = Layout(words: words, font: f, size: size, ascent: CTFontGetAscent(f), descent: d, cap: cap, leading: lh, lineCount: lines.count,
                       block: CGRect(x: minX, y: top, width: maxX - minX, height: blockH + d))
        layouts[cacheKey] = l
        return l
    }

    /// A word (or any run) as an image, plus where its baseline origin sits inside the image.
    func glyphs(_ text: String, font f: CTFont, size: CGFloat, color: RGBA) -> (CIImage, CGPoint) {
        let pad = ceil(size * 0.25)
        let a = CTFontGetAscent(f), d = CTFontGetDescent(f)
        let key = "g|\(text)|\(CTFontCopyPostScriptName(f))|\(size)|\(color.r),\(color.g),\(color.b),\(color.a)"
        if let c = images[key] { return (c, CGPoint(x: pad, y: pad + a)) }
        let line = CTLineCreateWithAttributedString(attributed(text, f, size, color))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let cg = drawImage(width: Int(ceil(w + pad * 2)), height: Int(ceil(a + d + pad * 2))) { ctx in
            ctx.saveGState()
            ctx.translateBy(x: pad, y: pad + a)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        let img = CIImage.from(cg)
        images[key] = img
        return (img, CGPoint(x: pad, y: pad + a))
    }

    /// Place glyphs so their baseline origin lands at (x, baseline) in top-left output coordinates.
    func placeGlyphs(_ g: (CIImage, CGPoint), x: CGFloat, baseline: CGFloat, dy: CGFloat = 0) -> CIImage {
        place(g.0, x: x - g.1.x, y: baseline - g.1.y + dy)
    }

    func place(_ img: CIImage, x: CGFloat, y: CGFloat) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: x, y: H - y - img.extent.height))
    }

    func scaled(_ img: CIImage, _ k: CGFloat, about c: CGPoint) -> CIImage {
        guard abs(k - 1) > 0.0005 else { return img }
        let cy = H - c.y
        return img.transformed(by: CGAffineTransform(translationX: -c.x, y: -cy).concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: c.x, y: cy)))
    }

    func blurred(_ img: CIImage, _ r: CGFloat) -> CIImage {
        guard r > 0.35 else { return img }
        return img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": r]).cropped(to: img.extent.insetBy(dx: -r * 2.5, dy: -r * 2.5))
    }

    func pill(_ size: CGSize, radius: CGFloat, color: RGBA, stroke: RGBA? = nil) -> CIImage {
        let key = "pill|\(Int(size.width))x\(Int(size.height))|\(radius)|\(color.r),\(color.g),\(color.b),\(color.a)|\(stroke.map { "\($0.a)" } ?? "")"
        if let c = images[key] { return c }
        let img = CIImage.from(drawImage(width: Int(ceil(size.width)), height: Int(ceil(size.height))) { ctx in
            let r = CGRect(origin: .zero, size: size)
            ctx.addPath(roundedRect(r, radius)); ctx.setFillColor(color.cg); ctx.fillPath()
            if let s = stroke {
                ctx.addPath(roundedRect(r.insetBy(dx: 0.75, dy: 0.75), radius - 0.75)); ctx.setStrokeColor(s.cg); ctx.setLineWidth(1.5); ctx.strokePath()
            }
        })
        images[key] = img
        return img
    }

    func color(_ tone: Int, _ pal: Palette) -> RGBA { tone == 2 ? pal.accent : tone == 1 ? pal.secondary : pal.text }

    // MARK: Timing

    /// Default landing times (seconds from scene start) when the planner didn't set them.
    public static func defaultTimes(_ s: TextScene, count n: Int) -> [Double] {
        guard n > 0 else { return [] }
        switch s.style {
        case "punch", "beat":
            let span = max(0.3, s.duration - 0.6)
            return (0..<n).map { 0.1 + span * Double($0) / Double(n) }
        case "stack":
            let step = min(0.65, max(0.3, (s.duration - 1.0) / Double(n)))
            return (0..<n).map { 0.15 + step * Double($0) }
        case "reveal": return (0..<n).map { 0.15 + 0.16 * Double($0) }
        case "type", "count", "lockup": return [0.2]
        default: return (0..<n).map { 0.15 + 0.085 * Double($0) }
        }
    }

    func times(_ s: TextScene, count n: Int) -> [Double] {
        var ts = s.times ?? []
        if ts.count < n {
            let d = Kinetic.defaultTimes(s, count: n)
            let last = ts.last ?? -1
            for i in ts.count..<n { ts.append(max(d[i], last + 0.08 * Double(i - ts.count + 1))) }
        }
        return ts
    }

    func tokens(_ s: TextScene) -> [String] {
        (s.text ?? s.allLines.joined(separator: " ")).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    func weightOf(_ s: TextScene, _ def: FontWeight) -> FontWeight { s.weight.flatMap(FontWeight.init(rawValue:)) ?? def }

    /// Soft entrance: opacity, a small rise and a blur that clears (ease-out quint over `dur`).
    func entrance(_ lt: Double, at t0: Double, dur: Double = 0.7) -> (alpha: CGFloat, rise: CGFloat, blur: CGFloat) {
        let p = clamp((lt - t0) / dur, 0, 1)
        let e = 1 - pow(1 - p, 5)
        return (CGFloat(clamp(p * 1.8, 0, 1)), CGFloat(1 - e), CGFloat(1 - e))
    }

    // MARK: Scene

    /// The scene at time `t`: type over its backdrop.
    public func image(_ s: TextScene, index: Int, t: Double, content: (() -> CIImage)?) -> CIImage {
        let l = layers(s, index: index, t: t, content: content)
        return l.type.over(l.bg)
    }

    /// Backdrop and type as separate layers (transitions move them differently).
    func layers(_ s: TextScene, index: Int, t: Double, content: (() -> CIImage)?) -> (bg: CIImage, type: CIImage) {
        let lt = t - s.start
        let pal = palette(s)
        let bg = background(s, t: t, content: content)
        var type = CIImage.empty()
        let sr = safeRect
        let wantW = sr.width * (portrait ? 0.94 : 0.78)
        let align = s.align == "left" ? "left" : "center"
        switch s.style {
        case "punch", "beat":
            let chunks = s.lines ?? tokens(s)
            guard !chunks.isEmpty else { break }
            let ts = times(s, count: chunks.count)
            guard let i = ts.lastIndex(where: { $0 <= lt + 1e-6 }) else { break }
            let base = S * (portrait ? 0.2 : 0.16) * CGFloat(s.size)
            let probe = font(s, size: base, weight: weightOf(s, .bold))
            let longest = chunks.max { width($0, probe, base) < width($1, probe, base) } ?? chunks[0]
            let fit = layout(s, key: "punchfit\(index)", words: longest.split(separator: " ").map(String.init), base: base, weight: weightOf(s, .bold),
                             maxLines: 2, maxWidth: wantW, maxHeight: sr.height * 0.45, leading: 1.0, align: align)
            let l = layout(s, key: "punch\(index)-\(i)", words: chunks[i].split(separator: " ").map(String.init), base: fit.size, weight: weightOf(s, .bold),
                           maxLines: 2, maxWidth: wantW, maxHeight: sr.height * 0.45, leading: 1.0, align: align)
            let isAccent = s.accent.contains { Kinetic.norm($0) == Kinetic.norm(chunks[i]) }
            let p = clamp((lt - ts[i]) / 0.3, 0, 1)
            let k = 1.025 - 0.025 * CGFloat(1 - pow(1 - p, 5))
            var layer = CIImage.empty()
            for w in l.words {
                let g = glyphs(w.text, font: l.font, size: l.size, color: isAccent ? pal.accent : color(w.tone, pal))
                layer = placeGlyphs(g, x: w.x, baseline: w.baseline).over(layer)
            }
            layer = scaled(layer, k, about: CGPoint(x: l.block.midX, y: l.block.midY))
            type = layer.opacity(CGFloat(clamp((lt - ts[i]) / 0.07, 0, 1)))
        case "stack", "reveal":
            let lines = s.allLines
            guard !lines.isEmpty else { break }
            let ts = times(s, count: lines.count)
            let base = S * (portrait ? 0.118 : 0.09) * CGFloat(s.size)
            let l = layout(s, key: "stack\(index)", words: lines.flatMap { $0.split(separator: " ").map(String.init) },
                           forcedLines: lines.map { $0.split(separator: " ").map(String.init) }, base: base, weight: weightOf(s, .bold),
                           maxLines: lines.count, maxWidth: wantW, maxHeight: sr.height * 0.7, leading: 1.1, align: align)
            for li in 0..<l.lineCount {
                let lineWords = l.words.filter { $0.line == li }
                guard let first = lineWords.first else { continue }
                let p = clamp((lt - ts[li]) / 0.6, 0, 1)
                guard p > 0 else { continue }
                let e = 1 - pow(1 - p, 5)
                // Earlier lines settle into the secondary tone as the next arrives (stack only).
                var settle: CGFloat = 0
                if s.style == "stack", li + 1 < ts.count { settle = CGFloat(clamp((lt - ts[li + 1]) / 0.45, 0, 1)) }
                var layer = CIImage.empty()
                for w in lineWords {
                    var g = placeGlyphs(glyphs(w.text, font: l.font, size: l.size, color: color(w.tone, pal)), x: w.x, baseline: w.baseline)
                    if settle > 0 && w.tone == 0 {
                        let quiet = placeGlyphs(glyphs(w.text, font: l.font, size: l.size, color: pal.secondary), x: w.x, baseline: w.baseline)
                        g = quiet.opacity(settle).over(g.opacity(1 - settle))
                    }
                    layer = g.over(layer)
                }
                // Rise from a slot under the line's baseline.
                let rise = CGFloat(1 - e) * l.size * 1.05
                let slotTop = first.baseline - l.ascent - l.size * 0.1
                let slotBottom = first.baseline + l.descent + l.size * 0.12
                let clip = CGRect(x: 0, y: H - slotBottom, width: W, height: slotBottom - slotTop)
                layer = layer.transformed(by: CGAffineTransform(translationX: 0, y: -rise)).cropped(to: clip)
                type = layer.over(type)
            }
            if let sub = s.sub { type = subLine(s, sub, pal: pal, below: l.block, lt: lt, at: (ts.last ?? 0) + 0.4, align: align).over(type) }
        case "type":
            let text = s.text ?? s.allLines.joined(separator: " ")
            let ts = times(s, count: 1)
            let chars = Array(text)
            let cps = max(14, Double(chars.count) / max(0.6, (s.duration - ts[0]) * 0.6))
            let n = clamp(Int(((lt - ts[0]) * cps).rounded(.down)), 0, chars.count)
            let base = S * (portrait ? 0.075 : 0.058) * CGFloat(s.size)
            let l = layout(s, key: "type\(index)", words: text.split(separator: " ").map(String.init), base: base, weight: weightOf(s, .medium),
                           maxLines: 6, maxWidth: wantW, maxHeight: sr.height * 0.6, leading: 1.25, align: "left")
            var used = 0
            var caret: (CGFloat, CGFloat)? = nil
            for w in l.words {
                let count = w.text.count
                let visible = clamp(n - used, 0, count)
                used += count + 1
                if visible <= 0 { if caret == nil { caret = (w.x, w.baseline) }; continue }
                let str = String(w.text.prefix(visible))
                type = placeGlyphs(glyphs(str, font: l.font, size: l.size, color: color(w.tone, pal)), x: w.x, baseline: w.baseline).over(type)
                if visible < count || used > n { caret = (w.x + width(str, l.font, l.size) + l.size * 0.05, w.baseline) }
            }
            if caret == nil, let last = l.words.last { caret = (last.x + last.width + l.size * 0.06, last.baseline) }
            if let c = caret, (Int(lt * 2.2) % 2 == 0 || n < chars.count) {
                let bar = pill(CGSize(width: max(2, l.size * 0.065), height: l.cap * 1.25), radius: l.size * 0.03, color: pal.accent)
                type = place(bar, x: c.0, y: c.1 - l.cap * 1.1).over(type)
            }
        case "count":
            let target = s.value ?? Double(s.text?.filter { $0.isNumber || $0 == "." } ?? "") ?? 100
            let ts = times(s, count: 1)
            let p = clamp((lt - ts[0]) / 1.4, 0, 1)
            let e = p >= 1 ? 1 : 1 - pow(2, -10 * p)
            let decimals = target == target.rounded() ? 0 : min(2, String(target).split(separator: ".").last?.count ?? 1)
            let nf = NumberFormatter(); nf.numberStyle = .decimal; nf.minimumFractionDigits = decimals; nf.maximumFractionDigits = decimals
            let str = (s.prefix ?? "") + (nf.string(from: NSNumber(value: target * e)) ?? "") + (s.suffix ?? "")
            let finalStr = (s.prefix ?? "") + (nf.string(from: NSNumber(value: target)) ?? "") + (s.suffix ?? "")
            var size = S * (portrait ? 0.24 : 0.2) * CGFloat(s.size)
            var f = font(s, size: size, weight: weightOf(s, .bold), digits: true)
            while width(finalStr, f, size) > wantW && size > S * 0.05 { size *= 0.94; f = font(s, size: size, weight: weightOf(s, .bold), digits: true) }
            let fw = width(finalStr, f, size), cap = CTFontGetCapHeight(f)
            let baseline = sr.midY - H * 0.03 + cap / 2
            let x = (W - fw) / 2 + (fw - width(str, f, size))
            let en = entrance(lt, at: ts[0], dur: 0.8)
            type = blurred(placeGlyphs(glyphs(str, font: f, size: size, color: pal.text), x: x, baseline: baseline, dy: en.rise * size * 0.15), en.blur * size * 0.04).opacity(en.alpha)
            if let sub = s.sub ?? (s.value != nil ? s.text : nil) {
                type = subLine(s, sub, pal: pal, below: CGRect(x: (W - fw) / 2, y: baseline - cap, width: fw, height: cap + CTFontGetDescent(f)), lt: lt, at: ts[0] + 0.5, align: "center").over(type)
            }
        case "lockup":
            type = lockup(s, index: index, pal: pal, lt: lt)
        default: // statement
            let words = tokens(s)
            guard !words.isEmpty else { break }
            let base = S * (portrait ? 0.105 : 0.08) * CGFloat(s.size)
            let l = layout(s, key: "stmt\(index)", words: words, base: base, weight: weightOf(s, .semibold), maxLines: portrait ? 5 : 3,
                           maxWidth: wantW, maxHeight: sr.height * 0.6, leading: 1.08, align: align)
            let ts = times(s, count: words.count)
            let byWords = (s.reveal ?? "lines") == "words"
            if s.marker { type = markers(l, ts: ts, lt: lt, pal: pal).over(type) }
            for (i, w) in l.words.enumerated() {
                // Lines reveal together at their first word's time; words cascade individually.
                let lineFirst = l.words.firstIndex { $0.line == w.line } ?? i
                let t0 = ts[min(byWords ? i : lineFirst, ts.count - 1)]
                let en = entrance(lt, at: t0, dur: byWords ? 0.55 : 0.75)
                guard en.alpha > 0 else { continue }
                var c = color(w.tone, pal)
                if s.marker && w.tone == 2 {
                    c = clamp((lt - ts[min(i, ts.count - 1)] - 0.25) / 0.38, 0, 1) > 0.6 ? pal.markerText : pal.accent
                }
                let layer = placeGlyphs(glyphs(w.text, font: l.font, size: l.size, color: c), x: w.x, baseline: w.baseline, dy: en.rise * l.size * 0.24)
                type = blurred(layer, en.blur * l.size * 0.05).opacity(en.alpha).over(type)
            }
            if let sub = s.sub { type = subLine(s, sub, pal: pal, below: l.block, lt: lt, at: (ts.last ?? 0) + 0.35, align: align).over(type) }
        }
        return (bg, type)
    }

    /// Highlighter swipes behind runs of accent words (opt-in via `marker`), sized from the font's
    /// cap height and descender so padding is even on every word.
    func markers(_ l: Layout, ts: [Double], lt: Double, pal: Palette) -> CIImage {
        var out = CIImage.empty()
        var runs: [(first: Int, last: Int)] = []
        for (i, w) in l.words.enumerated() where w.tone == 2 {
            if let r = runs.last, r.last == i - 1, l.words[r.last].line == w.line { runs[runs.count - 1].last = i } else { runs.append((i, i)) }
        }
        for r in runs {
            let a = l.words[r.first], b = l.words[r.last]
            let padX = l.size * 0.14
            let top = a.baseline - l.cap - l.size * 0.16, bottom = a.baseline + l.descent * 0.55
            let fullW = (b.x + b.width) - a.x + padX * 2
            let mp = CGFloat(clamp((lt - ts[min(r.first, ts.count - 1)] - 0.25) / 0.38, 0, 1))
            guard mp > 0 else { continue }
            let w = fullW * CGFloat(easeInOutCubic(Double(mp)))
            out = place(pill(CGSize(width: max(1, w), height: bottom - top), radius: l.size * 0.1, color: pal.markerFill), x: a.x - padX, y: top).over(out)
        }
        return out
    }

    /// A supporting line under a block (kicker, label, tagline) in the secondary tone.
    func subLine(_ s: TextScene, _ text: String, pal: Palette, below block: CGRect, lt: Double, at: Double, align: String) -> CIImage {
        let size = S * (portrait ? 0.04 : 0.032) * CGFloat(s.size)
        var sub = TextScene(); sub.font = s.font
        let l = layout(sub, key: "sub|\(text)", words: text.split(separator: " ").map(String.init), base: size, weight: .medium, maxLines: 2,
                       maxWidth: safeRect.width * 0.86, maxHeight: H * 0.2, leading: 1.25, align: align, centerY: block.maxY + size * 1.7)
        let en = entrance(lt, at: at, dur: 0.7)
        guard en.alpha > 0 else { return CIImage.empty() }
        var out = CIImage.empty()
        let dx = align == "left" ? block.minX - (l.words.first?.x ?? block.minX) : 0
        for w in l.words {
            out = placeGlyphs(glyphs(w.text, font: l.font, size: l.size, color: pal.secondary), x: w.x + dx, baseline: w.baseline, dy: en.rise * size * 0.3).over(out)
        }
        return out.opacity(en.alpha)
    }

    // MARK: Lockup (end card)

    func lockup(_ s: TextScene, index: Int, pal: Palette, lt: Double) -> CIImage {
        var out = CIImage.empty()
        let sr = safeRect
        let t0 = times(s, count: 1)[0]
        let k = CGFloat(s.size)
        let iconSize = S * (portrait ? 0.24 : 0.18) * k
        let name = s.text ?? brand.name ?? ""
        let tagline = s.sub ?? brand.tagline
        let cta = s.cta ?? brand.cta
        let nameSize = S * (portrait ? 0.088 : 0.066) * k
        let tagSize = S * (portrait ? 0.038 : 0.03) * k
        let ctaSize = S * (portrait ? 0.034 : 0.027) * k
        let nf = font(s, size: nameSize, weight: weightOf(s, .bold))
        let icon = loadIcon(s.icon ?? brand.icon ?? brand.logo, size: iconSize, dark: pal.dark)
        var tagL: Layout? = nil
        if let tg = tagline {
            var sub = TextScene(); sub.font = s.font
            tagL = layout(sub, key: "lockuptag\(index)", words: tg.split(separator: " ").map(String.init), base: tagSize, weight: .medium,
                          maxLines: 2, maxWidth: sr.width * 0.8, maxHeight: H * 0.2, leading: 1.3, align: "center", centerY: 0)
        }
        let nameCap = CTFontGetCapHeight(nf), nameDesc = CTFontGetDescent(nf)
        let gIconName = iconSize * 0.22, gNameTag = tagSize * 1.3, gTagCta = tagSize * 2.3
        let ctaH = cta == nil ? 0 : ctaSize * 2.5
        let tagH = tagL.map { CGFloat($0.lineCount - 1) * $0.leading + $0.cap + $0.descent } ?? 0
        let total = (icon == nil ? 0 : iconSize + gIconName) + (name.isEmpty ? 0 : nameCap + nameDesc) + (tagL == nil ? 0 : gNameTag + tagH) + (cta == nil ? 0 : gTagCta + ctaH)
        var y = sr.midY - total / 2 - H * 0.02
        if let (ic, shadow) = icon {
            let en = entrance(lt, at: t0, dur: 0.9)
            let sc = 0.93 + 0.07 * (1 - en.rise)
            let x = (W - iconSize) / 2
            let center = CGPoint(x: W / 2, y: y + iconSize / 2)
            let sh = place(shadow, x: x - (shadow.extent.width - iconSize) / 2, y: y + iconSize * 0.07 - (shadow.extent.height - iconSize) / 2)
            out = scaled(blurred(place(ic, x: x, y: y), en.blur * iconSize * 0.04).over(sh), sc, about: center).opacity(en.alpha).over(out)
            y += iconSize + gIconName
        }
        if !name.isEmpty {
            let en = entrance(lt, at: t0 + 0.18, dur: 0.8)
            if en.alpha > 0 {
                let w = width(name, nf, nameSize)
                let g = placeGlyphs(glyphs(name, font: nf, size: nameSize, color: pal.text), x: (W - w) / 2, baseline: y + nameCap, dy: en.rise * nameSize * 0.2)
                out = blurred(g, en.blur * nameSize * 0.05).opacity(en.alpha).over(out)
            }
            y += nameCap + nameDesc
        }
        if let tl = tagL {
            y += gNameTag
            let en = entrance(lt, at: t0 + 0.34, dur: 0.8)
            if en.alpha > 0 {
                var layer = CIImage.empty()
                for w in tl.words {
                    let base = y + tl.cap + CGFloat(w.line) * tl.leading
                    layer = placeGlyphs(glyphs(w.text, font: tl.font, size: tl.size, color: pal.secondary), x: w.x, baseline: base, dy: en.rise * tagSize * 0.3).over(layer)
                }
                out = layer.opacity(en.alpha).over(out)
            }
            y += tagH
        }
        if let c = cta {
            y += gTagCta
            let en = entrance(lt, at: t0 + 0.55, dur: 0.8)
            if en.alpha > 0 {
                let cf = font(s, size: ctaSize, weight: .semibold)
                let tw = width(c, cf, ctaSize), cap = CTFontGetCapHeight(cf)
                let ph = ctaH, pw = tw + ctaSize * 2.4
                let fill = pal.dark ? RGBA(1, 1, 1, 0.1) : RGBA(0, 0, 0, 0.05)
                let stroke = pal.dark ? RGBA(1, 1, 1, 0.22) : RGBA(0, 0, 0, 0.1)
                let px = (W - pw) / 2
                let pillImg = place(pill(CGSize(width: pw, height: ph), radius: ph / 2, color: fill, stroke: stroke), x: px, y: y)
                // Optical centering on the cap height, not the ascender box.
                let textImg = placeGlyphs(glyphs(c, font: cf, size: ctaSize, color: pal.text), x: px + (pw - tw) / 2, baseline: y + (ph + cap) / 2)
                out = textImg.over(pillImg).transformed(by: CGAffineTransform(translationX: 0, y: -en.rise * ctaSize * 0.3)).opacity(en.alpha).over(out)
            }
        }
        return out
    }

    /// App icon at `size` (squircle-masked when the art is a full square) and a soft shadow made
    /// from the icon's own silhouette — no boxes, no bounce.
    func loadIcon(_ path: String?, size: CGFloat, dark: Bool) -> (CIImage, CIImage)? {
        guard let path, !path.isEmpty else { return nil }
        let key = "\(path)|\(size)|\(dark)"
        if let c = iconImage[key] { return c }
        guard let cg = loadCGImage(Backgrounds.resolve(path, baseURL)) else { Log.warn("scene icon not found: \(path)"); return nil }
        let square = abs(CGFloat(cg.width) / CGFloat(cg.height) - 1) < 0.05
        let opaqueCorner = square && cornerAlpha(cg) > 0.9
        let w = size, h = size * CGFloat(cg.height) / CGFloat(cg.width)
        let img = CIImage.from(drawImage(width: Int(ceil(w)), height: Int(ceil(h))) { ctx in
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.saveGState()
            if opaqueCorner { ctx.addPath(continuousRoundedRect(r, radius: w * 0.2237, smoothing: 0.6)); ctx.clip() }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: r)
            ctx.restoreGState()
            if opaqueCorner && dark {
                // Hairline edge, like the system draws on dark backgrounds.
                ctx.addPath(continuousRoundedRect(r.insetBy(dx: 0.5, dy: 0.5), radius: w * 0.2237 - 0.5, smoothing: 0.6))
                ctx.setStrokeColor(RGBA(1, 1, 1, 0.14).cg); ctx.setLineWidth(1); ctx.strokePath()
            }
        })
        let blurR = size * 0.1
        let silhouette = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: dark ? 0.6 : 0.26)])
        let pad = blurR * 3
        let shadow = silhouette.transformed(by: CGAffineTransform(translationX: pad, y: pad)).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurR])
            .cropped(to: CGRect(x: 0, y: 0, width: w + pad * 2, height: h + pad * 2))
        let pair = (img, shadow)
        iconImage[key] = pair
        return pair
    }

    func cornerAlpha(_ cg: CGImage) -> CGFloat {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        let k = max(1, cg.width / 64)
        ctx.draw(cg, in: CGRect(x: 0, y: -CGFloat(cg.height - k), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard let data = ctx.data else { return 1 }
        return CGFloat(data.load(fromByteOffset: 3, as: UInt8.self)) / 255
    }

    // MARK: Transitions

    public struct Mix {
        public var scene: CIImage?
        /// 0 = only the device, 1 = only the scene.
        public var cover: Double
        public var deviceScale: CGFloat = 1
        public var deviceBlur: CGFloat = 0
        public var deviceDim: CGFloat = 0
        /// Vertical offset of the device layer in output points (positive = down on screen).
        public var deviceOffset: CGFloat = 0
        public var needsDevice: Bool { cover < 0.999 }
    }

    /// What's on screen at output time t.
    public func mix(_ scenes: [TextScene], t: Double, content: (() -> CIImage)?) -> Mix {
        guard let i = scenes.indices.last(where: { t >= scenes[$0].start - 1e-6 && t <= scenes[$0].end + 1e-6 }) else {
            return Mix(scene: nil, cover: 0)
        }
        let s = scenes[i]
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        let kind = s.transition == "auto" ? "dissolve" : s.transition
        let d = kind == "cut" ? 0 : clamp(s.transitionDuration, 0.08, min(0.9, s.duration / 3))
        let prev = scenes.indices.first { $0 != i && abs(scenes[$0].end - s.start) < 0.06 }
        // The closing card holds to the last frame instead of dissolving back to the device.
        let closes = s.style == "lockup" && !scenes.contains { $0.start > s.start + 1e-3 }
        let nextAdjacent = closes || scenes.indices.contains { $0 != i && abs(scenes[$0].start - s.end) < 0.06 }
        let pin = d == 0 || s.start < 0.05 ? 1 : clamp((t - s.start) / d, 0, 1)
        let pout = nextAdjacent || d == 0 ? 1 : clamp((s.end - t) / d, 0, 1)
        let lay = layers(s, index: i, t: t, content: content)
        let c = CGPoint(x: W / 2, y: H / 2)
        var m = Mix(scene: nil, cover: 1)
        var img = lay.type.over(lay.bg)
        if pin < 1 {
            let e = easeInOutCubic(pin)
            // The backdrop arrives first; the words follow.
            let typeA = CGFloat(clamp((e - 0.3) / 0.7, 0, 1))
            if let p = prev {
                // Scene to scene: the old words leave before the new ones arrive (never stacked on each
                // other) while the backdrops dissolve; no device flash.
                let pl = layers(scenes[p], index: p, t: min(t, scenes[p].end), content: content)
                let under = pl.type.opacity(CGFloat(1 - clamp(e / 0.45, 0, 1))).over(pl.bg)
                let inA = CGFloat(clamp((e - 0.5) / 0.5, 0, 1))
                img = lay.type.opacity(inA).over(lay.bg.opacity(CGFloat(e))).over(under)
                m.cover = 1
            } else {
                m.cover = e
                switch kind {
                case "lift":
                    img = lay.type.opacity(typeA).over(lay.bg).transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(1 - e) * H * 0.18)).cropped(to: full).opacity(CGFloat(e))
                    m.deviceOffset = -CGFloat(e) * H * 0.12; m.deviceDim = CGFloat(e) * 0.5
                case "zoom":
                    img = scaled(lay.type.opacity(typeA).over(lay.bg), 1.06 - 0.06 * CGFloat(e), about: c).cropped(to: full).opacity(CGFloat(e))
                    m.deviceScale = 1 + 0.12 * CGFloat(e); m.deviceBlur = CGFloat(e) * S * 0.018
                case "slide":
                    img = img.transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(1 - e) * H)).cropped(to: full)
                    m.cover = pin > 0 ? 0.5 : 0; m.deviceDim = CGFloat(e) * 0.4
                default: // dissolve
                    img = lay.type.opacity(typeA).over(lay.bg).opacity(CGFloat(e))
                    m.deviceBlur = CGFloat(e) * S * 0.012; m.deviceScale = 1 + 0.025 * CGFloat(e)
                }
            }
        } else if pout < 1 {
            let e = easeInOutCubic(pout)
            m.cover = e
            // The words leave first, so they never sit on the returning device.
            let typeA = CGFloat(clamp((e - 0.45) / 0.55, 0, 1))
            switch kind {
            case "lift":
                img = lay.type.opacity(typeA).over(lay.bg).transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(1 - e) * H * 0.2)).cropped(to: full).opacity(CGFloat(e))
                m.deviceOffset = CGFloat(e) * H * 0.14
            case "zoom":
                img = scaled(lay.type.opacity(typeA).over(lay.bg), 1 + 0.08 * CGFloat(1 - e), about: c).cropped(to: full).opacity(CGFloat(e))
                m.deviceScale = 0.92 + 0.08 * CGFloat(1 - e); m.deviceBlur = CGFloat(e) * S * 0.018
            case "slide":
                img = img.transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(1 - e) * H)).cropped(to: full)
                m.cover = 0.5; m.deviceDim = CGFloat(e) * 0.4
            default:
                img = lay.type.opacity(typeA).over(lay.bg).opacity(CGFloat(e))
                m.deviceBlur = CGFloat(e) * S * 0.012; m.deviceScale = 0.975 + 0.025 * CGFloat(1 - e)
            }
        }
        m.scene = img
        return m
    }
}

/// Frames from a video file (AI B-roll, 3D renders) for scene backgrounds.
public final class ClipFrames {
    let generator: AVAssetImageGenerator?
    public let duration: Double
    private var cache: (t: Double, img: CIImage)? = nil

    public init(url: URL) {
        let asset = AVURLAsset(url: url)
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
        generator = FileManager.default.fileExists(atPath: url.path) ? g : nil
        duration = (try? AssetInfo.load(url).duration) ?? 0
        if generator == nil { Log.warn("clip not found: \(url.path)") }
    }

    public func frame(at t: Double) -> CIImage? {
        guard let g = generator else { return nil }
        // Hold the last frame past the clip's end.
        let tt = duration > 0 ? min(max(0, t), max(0, duration - 0.04)) : max(0, t)
        if let c = cache, abs(c.t - tt) < 0.001 { return c.img }
        let cg: CGImage? = try? blocking { try await g.image(at: CMTime(seconds: tt, preferredTimescale: 600)).image }
        guard let cg else { return cache?.img }
        let img = CIImage(cgImage: cg)
        cache = (tt, img)
        return img
    }
}
