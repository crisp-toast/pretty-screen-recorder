import Foundation
import CoreGraphics
import CoreText

/// Geometry + artwork for the chrome around a recording. Everything is in FRAME SPACE:
/// source-video pixels, top-left origin. The renderer scales the whole thing into the stage,
/// so chrome is drawn at the recording's native resolution and stays crisp when zoomed.
public struct FrameGeometry {
    public var type: String
    public var outerSize: CGSize
    /// The device screen / browser viewport area.
    public var screenRect: CGRect
    /// Where the recording itself goes (inside screenRect; smaller when the frame draws
    /// a synthetic status bar / Safari bar around a mobile-web recording).
    public var videoRect: CGRect
    /// Corner radius applied to the screen (devices). 0 when the outer mask handles it.
    public var screenRadius: CGFloat
    /// Mask the whole composite with `outerPath` (browser/window/none).
    public var maskOuter: Bool
    /// Silhouette used for the drop shadow and outer mask.
    public var outerPath: CGPath
    public var under: CGImage?
    public var over: CGImage?
}

public enum Frames {
    public static let types = ["none", "window", "browser", "iphone", "ipad", "android", "macbook"]

    public static func resolveType(_ spec: FrameSpec, source: SourceSpec, videoSize: CGSize) -> String {
        if spec.type != "auto" { return spec.type }
        let portrait = videoSize.height > videoSize.width
        let ratio = min(videoSize.width, videoSize.height) / max(videoSize.width, videoSize.height)
        switch source.kind {
        case "web": return "browser"
        case "mobile-web": return "iphone"
        case "ios": return ratio > 0.62 ? "ipad" : "iphone"
        case "android": return "android"
        default:
            _ = portrait
            return "none"
        }
    }

    public static func build(type: String, spec: FrameSpec, source: SourceSpec, videoSize: CGSize, corners: Double, border: Bool) -> FrameGeometry {
        let ps = CGFloat(max(1, source.pointScale))
        switch type {
        case "browser": return browser(spec, source, videoSize, ps)
        case "window": return window(spec, source, videoSize, ps)
        case "iphone": return phone(spec, source, videoSize, android: false)
        case "android": return phone(spec, source, videoSize, android: true)
        case "ipad": return tablet(spec, videoSize)
        case "macbook": return macbook(spec, videoSize)
        default:
            let r = CGRect(origin: .zero, size: videoSize)
            let rad = CGFloat(corners) * min(videoSize.width, videoSize.height)
            let path = roundedRect(r, rad)
            var over: CGImage? = nil
            if border, rad >= 0 {
                over = drawImage(width: Int(videoSize.width), height: Int(videoSize.height)) { ctx in
                    let lw = max(1, ps * 0.6)
                    ctx.addPath(roundedRect(r.insetBy(dx: lw / 2, dy: lw / 2), max(0, rad - lw / 2)))
                    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14)); ctx.setLineWidth(lw); ctx.strokePath()
                }
            }
            return FrameGeometry(type: "none", outerSize: videoSize, screenRect: r, videoRect: r, screenRadius: 0,
                                 maskOuter: rad > 0.5, outerPath: path, under: nil, over: over)
        }
    }

    // MARK: Browser (Safari-style)

    static func displayHost(_ url: String?) -> String {
        guard var s = url, !s.isEmpty else { return "example.com" }
        if s.hasPrefix("file:") { return "localhost" }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        return s
    }

    static func browser(_ spec: FrameSpec, _ source: SourceSpec, _ v: CGSize, _ u: CGFloat) -> FrameGeometry {
        let dark = spec.theme == "dark"
        let tb = (52 * u).rounded()
        let W = v.width, H = v.height + tb
        let wr = 14 * u
        let outer = CGRect(x: 0, y: 0, width: W, height: H)
        let path = roundedRect(outer, wr)
        let host = displayHost(spec.url ?? source.url)
        let under = drawImage(width: Int(W), height: Int(H)) { ctx in
            let bar = dark ? RGBA.hex("#2B2B2E") : RGBA.hex("#F5F5F7")
            ctx.setFillColor(bar.cg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: tb + 2))
            ctx.setFillColor((dark ? RGBA(1, 1, 1, 0.08) : RGBA(0, 0, 0, 0.09)).cg)
            ctx.fill(CGRect(x: 0, y: tb - max(1, u * 0.5), width: W, height: max(1, u * 0.5)))
            trafficLights(ctx, x: 22 * u, y: tb / 2, u: u)
            let ink = dark ? RGBA(1, 1, 1, 0.55) : RGBA(0, 0, 0, 0.45)
            // Sidebar toggle
            ctx.setStrokeColor(ink.cg); ctx.setLineWidth(1.4 * u)
            let sb = CGRect(x: 88 * u, y: tb / 2 - 7 * u, width: 19 * u, height: 14 * u)
            ctx.addPath(roundedRect(sb, 3 * u)); ctx.strokePath()
            ctx.move(to: CGPoint(x: sb.minX + 6.5 * u, y: sb.minY)); ctx.addLine(to: CGPoint(x: sb.minX + 6.5 * u, y: sb.maxY)); ctx.strokePath()
            // Back / forward
            chevron(ctx, x: 130 * u, y: tb / 2, u: u, left: true, color: ink)
            chevron(ctx, x: 156 * u, y: tb / 2, u: u, left: false, color: ink.with(alpha: ink.a * 0.5))
            // URL field
            let fw = min(max(W * 0.42, 260 * u), 620 * u), fh = 32 * u
            let field = CGRect(x: (W - fw) / 2, y: (tb - fh) / 2, width: fw, height: fh)
            ctx.addPath(roundedRect(field, fh / 2))
            ctx.setFillColor((dark ? RGBA.hex("#3A3A3D") : RGBA(0, 0, 0, 0.055)).cg); ctx.fillPath()
            let font = Fonts.font(name: nil, size: 13.5 * u, weight: .medium)
            let tcol = dark ? RGBA(1, 1, 1, 0.86) : RGBA(0, 0, 0, 0.78)
            let tw = lineWidth(host, font: font)
            let lockW = 10 * u
            let startX = field.midX - (tw + lockW + 6 * u) / 2
            lock(ctx, x: startX, y: field.midY, u: u, color: tcol.with(alpha: 0.6))
            drawLine(ctx, host, font: font, color: tcol, at: CGPoint(x: startX + lockW + 6 * u, y: field.midY))
            reload(ctx, c: CGPoint(x: field.maxX - 16 * u, y: field.midY), u: u, color: ink)
            // Right icons: share, new tab, tabs
            share(ctx, c: CGPoint(x: W - 96 * u, y: tb / 2), u: u, color: ink)
            plus(ctx, c: CGPoint(x: W - 62 * u, y: tb / 2), u: u, color: ink)
            tabs(ctx, c: CGPoint(x: W - 30 * u, y: tb / 2), u: u, color: ink)
            // Page area backdrop (shows only if the recording has transparency)
            ctx.setFillColor((dark ? RGBA.hex("#1C1C1E") : RGBA(1, 1, 1)).cg)
            ctx.fill(CGRect(x: 0, y: tb, width: W, height: H - tb))
        }
        let over = drawImage(width: Int(W), height: Int(H)) { ctx in
            ctx.addPath(roundedRect(outer.insetBy(dx: u * 0.25, dy: u * 0.25), wr))
            ctx.setStrokeColor((dark ? RGBA(1, 1, 1, 0.16) : RGBA(0, 0, 0, 0.14)).cg)
            ctx.setLineWidth(max(1, u * 0.5)); ctx.strokePath()
        }
        let screen = CGRect(x: 0, y: tb, width: W, height: v.height)
        return FrameGeometry(type: "browser", outerSize: CGSize(width: W, height: H), screenRect: screen, videoRect: screen,
                             screenRadius: 0, maskOuter: true, outerPath: path, under: under, over: over)
    }

    // MARK: macOS window

    static func window(_ spec: FrameSpec, _ source: SourceSpec, _ v: CGSize, _ u: CGFloat) -> FrameGeometry {
        let dark = spec.theme == "dark"
        let tb = (32 * u).rounded()
        let W = v.width, H = v.height + tb
        let wr = 14 * u
        let outer = CGRect(x: 0, y: 0, width: W, height: H)
        let title = spec.title ?? source.title ?? ""
        let under = drawImage(width: Int(W), height: Int(H)) { ctx in
            ctx.setFillColor((dark ? RGBA.hex("#2A2A2D") : RGBA.hex("#EDEDEF")).cg)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: tb + 2))
            ctx.setFillColor((dark ? RGBA(1, 1, 1, 0.07) : RGBA(0, 0, 0, 0.08)).cg)
            ctx.fill(CGRect(x: 0, y: tb - max(1, u * 0.5), width: W, height: max(1, u * 0.5)))
            trafficLights(ctx, x: 20 * u, y: tb / 2, u: u)
            if !title.isEmpty {
                let f = Fonts.font(name: nil, size: 13 * u, weight: .semibold)
                drawLine(ctx, title, font: f, color: dark ? RGBA(1, 1, 1, 0.8) : RGBA(0, 0, 0, 0.75),
                         at: CGPoint(x: 0, y: tb / 2), centeredIn: W)
            }
        }
        let over = drawImage(width: Int(W), height: Int(H)) { ctx in
            ctx.addPath(roundedRect(outer.insetBy(dx: u * 0.25, dy: u * 0.25), wr))
            ctx.setStrokeColor((dark ? RGBA(1, 1, 1, 0.16) : RGBA(0, 0, 0, 0.14)).cg)
            ctx.setLineWidth(max(1, u * 0.5)); ctx.strokePath()
        }
        let screen = CGRect(x: 0, y: tb, width: W, height: v.height)
        return FrameGeometry(type: "window", outerSize: CGSize(width: W, height: H), screenRect: screen, videoRect: screen,
                             screenRadius: 0, maskOuter: true, outerPath: roundedRect(outer, wr), under: under, over: over)
    }

    // MARK: Phones

    struct Finish { var light: RGBA; var dark: RGBA; var edge: RGBA }
    static func finish(_ name: String) -> Finish {
        switch name {
        case "silver", "white": return Finish(light: .hex("#F1F2F4"), dark: .hex("#B8BBC0"), edge: .hex("#FFFFFF"))
        case "natural", "titanium": return Finish(light: .hex("#D6D1C8"), dark: .hex("#8F8A82"), edge: .hex("#F0ECE4"))
        case "desert", "gold": return Finish(light: .hex("#DCC6AC"), dark: .hex("#9E8468"), edge: .hex("#F3E5D3"))
        case "blue": return Finish(light: .hex("#55698A"), dark: .hex("#2C3A52"), edge: .hex("#8DA2C4"))
        case "orange": return Finish(light: .hex("#F2994A"), dark: .hex("#B5541B"), edge: .hex("#FFC28A"))
        default: return Finish(light: .hex("#4A4A4E"), dark: .hex("#161618"), edge: .hex("#77777C"))
        }
    }

    static func phone(_ spec: FrameSpec, _ source: SourceSpec, _ v: CGSize, android: Bool) -> FrameGeometry {
        let portrait = v.height >= v.width
        let shortSide = min(v.width, v.height)
        let mobileWeb = source.kind == "mobile-web"
        // In mobile-web mode the recording is the page viewport only; the frame adds iOS chrome.
        let refW: CGFloat = android ? 412 : 402
        var u = shortSide / refW
        var screenSize = v
        var statusH: CGFloat = 0, bottomH: CGFloat = 0
        if mobileWeb && portrait && !android {
            u = v.width / refW
            statusH = (54 * u).rounded(); bottomH = (82 * u).rounded()
            screenSize = CGSize(width: v.width, height: v.height + statusH + bottomH)
        }
        let band = (android ? 3.2 : 4.6) * u
        let bezel = (android ? 8.5 : 10.5) * u
        let screenR = (android ? 0.085 : 0.153) * refW * u
        let side = band + bezel
        let margin = 3 * u
        let bodyW = (portrait ? screenSize.width : screenSize.width) + side * 2
        let bodyH = screenSize.height + side * 2
        let W = bodyW + (portrait ? margin * 2 : 0)
        let H = bodyH + (portrait ? 0 : margin * 2)
        let body = CGRect(x: portrait ? margin : 0, y: portrait ? 0 : margin, width: bodyW, height: bodyH)
        let outerR = screenR + side
        let screen = CGRect(x: body.minX + side, y: body.minY + side, width: screenSize.width, height: screenSize.height)
        let video = CGRect(x: screen.minX, y: screen.minY + statusH, width: v.width, height: v.height)
        let fin = finish(spec.color)
        let dark = spec.theme == "dark"

        let under = drawImage(width: Int(W.rounded(.up)), height: Int(H.rounded(.up))) { ctx in
            // Side buttons (drawn first, peeking out from behind the body)
            ctx.setFillColor(fin.dark.mixed(fin.light, 0.35).cg)
            func button(_ along: CGFloat, _ length: CGFloat, leftOrTop: Bool) {
                let t = 3.4 * u
                let r: CGRect
                if portrait {
                    r = CGRect(x: leftOrTop ? body.minX - t + u : body.maxX - u, y: body.minY + along * u, width: t, height: length * u)
                } else {
                    r = CGRect(x: body.minX + along * u, y: leftOrTop ? body.minY - t + u : body.maxY - u, width: length * u, height: t)
                }
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.6 * u, cornerHeight: 1.6 * u, transform: nil)); ctx.fillPath()
            }
            if android {
                button(190, 70, leftOrTop: false); button(290, 120, leftOrTop: false)
            } else {
                button(118, 34, leftOrTop: true); button(182, 58, leftOrTop: true); button(254, 58, leftOrTop: true)
                button(220, 96, leftOrTop: false)
                button(470, 48, leftOrTop: false)
            }
            // Metal band with a soft sheen
            let bodyPath = roundedRect(body, outerR)
            ctx.saveGState(); ctx.addPath(bodyPath); ctx.clip()
            let g = CGGradient(colorsSpace: sRGB, colors: [fin.light.cg, fin.dark.cg, fin.light.mixed(fin.dark, 0.3).cg, fin.dark.cg, fin.light.cg] as CFArray,
                               locations: [0, 0.18, 0.5, 0.82, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
            ctx.restoreGState()
            // Polished inner lip
            ctx.addPath(roundedRect(body.insetBy(dx: band * 0.55, dy: band * 0.55), outerR - band * 0.55))
            ctx.setStrokeColor(fin.edge.with(alpha: 0.55).cg); ctx.setLineWidth(max(1, 0.7 * u)); ctx.strokePath()
            // Black glass bezel
            ctx.addPath(roundedRect(body.insetBy(dx: band, dy: band), outerR - band))
            ctx.setFillColor(RGBA.hex("#050506").cg); ctx.fillPath()
            ctx.addPath(roundedRect(body.insetBy(dx: band + 0.6 * u, dy: band + 0.6 * u), outerR - band - 0.6 * u))
            ctx.setStrokeColor(RGBA(1, 1, 1, 0.07).cg); ctx.setLineWidth(max(1, 0.8 * u)); ctx.strokePath()

            if mobileWeb && statusH > 0 {
                // Synthetic iOS chrome around a mobile-web viewport.
                let bg = dark ? RGBA.hex("#000000") : RGBA(1, 1, 1)
                ctx.saveGState(); ctx.addPath(roundedRect(screen, screenR)); ctx.clip()
                ctx.setFillColor(bg.cg); ctx.fill(screen)
                ctx.restoreGState()
                drawStatusBar(ctx, rect: CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: statusH), u: u, dark: dark)
                drawSafariBar(ctx, rect: CGRect(x: screen.minX, y: video.maxY, width: screen.width, height: bottomH), u: u, dark: dark,
                              host: displayHost(spec.url ?? source.url))
            }
        }

        let over = drawImage(width: Int(W.rounded(.up)), height: Int(H.rounded(.up))) { ctx in
            if android {
                let d = 11 * u
                let c = portrait ? CGPoint(x: screen.midX, y: screen.minY + 14 * u) : CGPoint(x: screen.minX + 14 * u, y: screen.midY)
                ctx.setFillColor(RGBA.hex("#000000").cg)
                ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            } else if source.kind == "ios" {
                // Simulator captures already contain the real Dynamic Island, pixel-exact;
                // drawing another one doubles it.
            } else {
                // Dynamic Island
                let iw = 125 * u, ih = 36.7 * u, top = 11.3 * u
                let r = portrait ? CGRect(x: screen.midX - iw / 2, y: screen.minY + top, width: iw, height: ih)
                                 : CGRect(x: screen.minX + top, y: screen.midY - iw / 2, width: ih, height: iw)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil))
                ctx.setFillColor(RGBA.hex("#000000").cg); ctx.fillPath()
                // Camera lens hint
                let lc = portrait ? CGPoint(x: r.maxX - ih / 2, y: r.midY) : CGPoint(x: r.midX, y: r.maxY - ih / 2)
                let lr = ih * 0.22
                ctx.setFillColor(RGBA.hex("#0E1222").cg)
                ctx.fillEllipse(in: CGRect(x: lc.x - lr, y: lc.y - lr, width: lr * 2, height: lr * 2))
                ctx.setFillColor(RGBA(0.35, 0.4, 0.65, 0.35).cg)
                ctx.fillEllipse(in: CGRect(x: lc.x - lr * 0.35, y: lc.y - lr * 0.55, width: lr * 0.5, height: lr * 0.5))
            }
        }
        return FrameGeometry(type: android ? "android" : "iphone", outerSize: CGSize(width: W.rounded(.up), height: H.rounded(.up)),
                             screenRect: screen, videoRect: video, screenRadius: screenR,
                             maskOuter: false, outerPath: roundedRect(body, outerR), under: under, over: over)
    }

    static func tablet(_ spec: FrameSpec, _ v: CGSize) -> FrameGeometry {
        let u = min(v.width, v.height) / 834
        let band = 3.0 * u, bezel = 20 * u, side = band + bezel
        let screenR = 18.5 * u, outerR = screenR + side
        let W = v.width + side * 2, H = v.height + side * 2
        let body = CGRect(x: 0, y: 0, width: W, height: H)
        let screen = CGRect(x: side, y: side, width: v.width, height: v.height)
        let fin = finish(spec.color == "black" ? "black" : spec.color)
        let under = drawImage(width: Int(W.rounded(.up)), height: Int(H.rounded(.up))) { ctx in
            ctx.saveGState(); ctx.addPath(roundedRect(body, outerR)); ctx.clip()
            let g = CGGradient(colorsSpace: sRGB, colors: [fin.light.cg, fin.dark.cg, fin.light.cg] as CFArray, locations: [0, 0.5, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
            ctx.restoreGState()
            ctx.addPath(roundedRect(body.insetBy(dx: band, dy: band), outerR - band))
            ctx.setFillColor(RGBA.hex("#060607").cg); ctx.fillPath()
            // Front camera on the landscape long edge
            let landscape = v.width > v.height
            let c = landscape ? CGPoint(x: W / 2, y: side / 2 + band / 2) : CGPoint(x: W - side / 2 - band / 2, y: H / 2)
            let r = 2.6 * u
            ctx.setFillColor(RGBA.hex("#1A1D26").cg)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        return FrameGeometry(type: "ipad", outerSize: CGSize(width: W.rounded(.up), height: H.rounded(.up)), screenRect: screen, videoRect: screen,
                             screenRadius: screenR, maskOuter: false, outerPath: roundedRect(body, outerR), under: under, over: nil)
    }

    // MARK: MacBook

    static func macbook(_ spec: FrameSpec, _ v: CGSize) -> FrameGeometry {
        let w = v.width
        let bezelSide = 0.021 * w, bezelTop = 0.026 * w, bezelBottom = 0.034 * w
        let lidR = 0.022 * w
        let lid = CGRect(x: 0.07 * w, y: 0, width: w + bezelSide * 2, height: v.height + bezelTop + bezelBottom)
        let baseH = 0.032 * w
        let baseW = lid.width * 1.16
        let W = max(lid.maxX + 0.07 * w, baseW)
        let lidRect = CGRect(x: (W - lid.width) / 2, y: 0, width: lid.width, height: lid.height)
        let base = CGRect(x: (W - baseW) / 2, y: lidRect.maxY - 0.002 * w, width: baseW, height: baseH)
        let H = base.maxY
        let screen = CGRect(x: lidRect.minX + bezelSide, y: bezelTop, width: v.width, height: v.height)
        let silver = spec.color == "silver"
        let under = drawImage(width: Int(W.rounded(.up)), height: Int(H.rounded(.up))) { ctx in
            // Lid: thin aluminum edge + black bezel
            ctx.addPath(roundedRect(lidRect, lidR))
            ctx.setFillColor((silver ? RGBA.hex("#C9CBCF") : RGBA.hex("#2E2F33")).cg); ctx.fillPath()
            let inner = lidRect.insetBy(dx: 0.0035 * w, dy: 0.0035 * w)
            ctx.addPath(roundedRect(inner, lidR - 0.0035 * w))
            ctx.setFillColor(RGBA.hex("#050506").cg); ctx.fillPath()
            // Notch
            let nw = 0.118 * w, nh = 0.0205 * w
            let notch = CGRect(x: screen.midX - nw / 2, y: screen.minY - 1, width: nw, height: nh + 1)
            let np = CGMutablePath()
            np.addRoundedRect(in: notch, cornerWidth: nh * 0.45, cornerHeight: nh * 0.45)
            ctx.addPath(np); ctx.setFillColor(RGBA.hex("#050506").cg); ctx.fillPath()
            // Base / deck: a wide slab with a finger notch
            let deck = CGMutablePath()
            let taper = baseH * 0.9
            deck.move(to: CGPoint(x: base.minX + 0.004 * w, y: base.minY))
            deck.addLine(to: CGPoint(x: base.maxX - 0.004 * w, y: base.minY))
            deck.addQuadCurve(to: CGPoint(x: base.maxX - taper, y: base.maxY), control: CGPoint(x: base.maxX, y: base.maxY))
            deck.addLine(to: CGPoint(x: base.minX + taper, y: base.maxY))
            deck.addQuadCurve(to: CGPoint(x: base.minX + 0.004 * w, y: base.minY), control: CGPoint(x: base.minX, y: base.maxY))
            deck.closeSubpath()
            ctx.saveGState(); ctx.addPath(deck); ctx.clip()
            let top = silver ? RGBA.hex("#E3E4E7") : RGBA.hex("#3A3B40")
            let bot = silver ? RGBA.hex("#9FA2A8") : RGBA.hex("#141417")
            let g = CGGradient(colorsSpace: sRGB, colors: [top.cg, top.mixed(bot, 0.4).cg, bot.cg] as CFArray, locations: [0, 0.35, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base.minY), end: CGPoint(x: 0, y: base.maxY), options: [])
            ctx.restoreGState()
            let lip = CGRect(x: W / 2 - 0.085 * w, y: base.minY, width: 0.17 * w, height: baseH * 0.32)
            ctx.addPath(CGPath(roundedRect: lip, cornerWidth: baseH * 0.3, cornerHeight: baseH * 0.3, transform: nil))
            ctx.setFillColor((silver ? RGBA.hex("#B5B8BD") : RGBA.hex("#24252A")).cg); ctx.fillPath()
        }
        let silhouette = CGMutablePath()
        silhouette.addPath(roundedRect(lidRect, lidR))
        silhouette.addRect(base)
        return FrameGeometry(type: "macbook", outerSize: CGSize(width: W.rounded(.up), height: H.rounded(.up)), screenRect: screen, videoRect: screen,
                             screenRadius: 0.006 * w, maskOuter: false, outerPath: silhouette, under: under, over: nil)
    }

    // MARK: Small glyphs

    static func trafficLights(_ ctx: CGContext, x: CGFloat, y: CGFloat, u: CGFloat) {
        let d = 12.5 * u
        for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            let cx = x + CGFloat(i) * 20 * u
            let r = CGRect(x: cx - d / 2, y: y - d / 2, width: d, height: d)
            ctx.setFillColor(RGBA.hex(hex).cg); ctx.fillEllipse(in: r)
            ctx.setStrokeColor(RGBA(0, 0, 0, 0.12).cg); ctx.setLineWidth(max(0.5, 0.5 * u))
            ctx.strokeEllipse(in: r.insetBy(dx: 0.25 * u, dy: 0.25 * u))
        }
    }

    static func chevron(_ ctx: CGContext, x: CGFloat, y: CGFloat, u: CGFloat, left: Bool, color: RGBA) {
        let h = 6.5 * u, w = 4.5 * u
        ctx.setStrokeColor(color.cg); ctx.setLineWidth(1.9 * u); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        if left {
            ctx.move(to: CGPoint(x: x + w / 2, y: y - h)); ctx.addLine(to: CGPoint(x: x - w / 2, y: y)); ctx.addLine(to: CGPoint(x: x + w / 2, y: y + h))
        } else {
            ctx.move(to: CGPoint(x: x - w / 2, y: y - h)); ctx.addLine(to: CGPoint(x: x + w / 2, y: y)); ctx.addLine(to: CGPoint(x: x - w / 2, y: y + h))
        }
        ctx.strokePath()
    }

    static func lock(_ ctx: CGContext, x: CGFloat, y: CGFloat, u: CGFloat, color: RGBA) {
        let bw = 9 * u, bh = 7 * u
        let body = CGRect(x: x, y: y - bh / 2 + 1.5 * u, width: bw, height: bh)
        ctx.setFillColor(color.cg)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 1.6 * u, cornerHeight: 1.6 * u, transform: nil)); ctx.fillPath()
        ctx.setStrokeColor(color.cg); ctx.setLineWidth(1.5 * u)
        ctx.addArc(center: CGPoint(x: x + bw / 2, y: body.minY), radius: 3 * u, startAngle: .pi, endAngle: 0, clockwise: false)
        ctx.strokePath()
    }

    static func reload(_ ctx: CGContext, c: CGPoint, u: CGFloat, color: RGBA) {
        ctx.setStrokeColor(color.cg); ctx.setLineWidth(1.5 * u); ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: 5.5 * u, startAngle: -.pi * 0.35, endAngle: .pi * 1.45, clockwise: false)
        ctx.strokePath()
        let tip = CGPoint(x: c.x + 5.5 * u * cos(-.pi * 0.35), y: c.y + 5.5 * u * sin(-.pi * 0.35))
        ctx.setFillColor(color.cg)
        ctx.move(to: CGPoint(x: tip.x + 2.8 * u, y: tip.y - 0.5 * u)); ctx.addLine(to: CGPoint(x: tip.x - 1.2 * u, y: tip.y - 3 * u))
        ctx.addLine(to: CGPoint(x: tip.x - 0.6 * u, y: tip.y + 2.2 * u)); ctx.closePath(); ctx.fillPath()
    }

    static func share(_ ctx: CGContext, c: CGPoint, u: CGFloat, color: RGBA) {
        ctx.setStrokeColor(color.cg); ctx.setLineWidth(1.5 * u); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let b = CGRect(x: c.x - 6.5 * u, y: c.y - 2 * u, width: 13 * u, height: 10 * u)
        ctx.move(to: CGPoint(x: b.minX + 3.5 * u, y: b.minY)); ctx.addLine(to: CGPoint(x: b.minX, y: b.minY))
        ctx.addLine(to: CGPoint(x: b.minX, y: b.maxY)); ctx.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
        ctx.addLine(to: CGPoint(x: b.maxX, y: b.minY)); ctx.addLine(to: CGPoint(x: b.maxX - 3.5 * u, y: b.minY)); ctx.strokePath()
        ctx.move(to: CGPoint(x: c.x, y: c.y + 3 * u)); ctx.addLine(to: CGPoint(x: c.x, y: c.y - 9 * u)); ctx.strokePath()
        ctx.move(to: CGPoint(x: c.x - 3.5 * u, y: c.y - 5.5 * u)); ctx.addLine(to: CGPoint(x: c.x, y: c.y - 9 * u))
        ctx.addLine(to: CGPoint(x: c.x + 3.5 * u, y: c.y - 5.5 * u)); ctx.strokePath()
    }

    static func plus(_ ctx: CGContext, c: CGPoint, u: CGFloat, color: RGBA) {
        ctx.setStrokeColor(color.cg); ctx.setLineWidth(1.6 * u); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x - 6 * u, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 6 * u, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 6 * u)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 6 * u)); ctx.strokePath()
    }

    static func tabs(_ ctx: CGContext, c: CGPoint, u: CGFloat, color: RGBA) {
        ctx.setStrokeColor(color.cg); ctx.setLineWidth(1.4 * u)
        ctx.addPath(roundedRect(CGRect(x: c.x - 7 * u, y: c.y - 4 * u, width: 10 * u, height: 10 * u), 2.2 * u)); ctx.strokePath()
        ctx.move(to: CGPoint(x: c.x - 3 * u, y: c.y - 7 * u)); ctx.addLine(to: CGPoint(x: c.x + 5 * u, y: c.y - 7 * u))
        ctx.addQuadCurve(to: CGPoint(x: c.x + 7 * u, y: c.y - 5 * u), control: CGPoint(x: c.x + 7 * u, y: c.y - 7 * u))
        ctx.addLine(to: CGPoint(x: c.x + 7 * u, y: c.y + 3 * u)); ctx.strokePath()
    }

    static func drawStatusBar(_ ctx: CGContext, rect: CGRect, u: CGFloat, dark: Bool) {
        let ink = dark ? RGBA(1, 1, 1) : RGBA(0, 0, 0)
        let f = Fonts.font(name: nil, size: 17 * u, weight: .semibold)
        let cy = rect.minY + rect.height * 0.56
        drawLine(ctx, "9:41", font: f, color: ink, at: CGPoint(x: rect.minX, y: cy), centeredIn: rect.width * 0.36)
        // Right cluster: cellular, wifi, battery
        var x = rect.maxX - rect.width * 0.18 - 40 * u
        ctx.setFillColor(ink.cg)
        for i in 0..<4 {
            let bh = (4 + CGFloat(i) * 2.4) * u
            ctx.addPath(CGPath(roundedRect: CGRect(x: x + CGFloat(i) * 4.6 * u, y: cy + 5.5 * u - bh, width: 3.2 * u, height: bh),
                               cornerWidth: 1 * u, cornerHeight: 1 * u, transform: nil))
        }
        ctx.fillPath()
        x += 24 * u
        ctx.setStrokeColor(ink.cg); ctx.setLineCap(.round)
        for i in 0..<3 {
            let r = (3 + CGFloat(i) * 3.6) * u
            ctx.setLineWidth(2.1 * u)
            ctx.addArc(center: CGPoint(x: x + 8 * u, y: cy + 5 * u), radius: r, startAngle: -.pi * 0.75, endAngle: -.pi * 0.25, clockwise: false)
            ctx.strokePath()
        }
        x += 22 * u
        let bat = CGRect(x: x, y: cy - 6 * u, width: 25 * u, height: 12 * u)
        ctx.setStrokeColor(ink.with(alpha: 0.4).cg); ctx.setLineWidth(1 * u)
        ctx.addPath(CGPath(roundedRect: bat, cornerWidth: 3.6 * u, cornerHeight: 3.6 * u, transform: nil)); ctx.strokePath()
        ctx.setFillColor(ink.cg)
        ctx.addPath(CGPath(roundedRect: bat.insetBy(dx: 2 * u, dy: 2 * u), cornerWidth: 2 * u, cornerHeight: 2 * u, transform: nil)); ctx.fillPath()
        ctx.setFillColor(ink.with(alpha: 0.4).cg)
        ctx.fill(CGRect(x: bat.maxX + 1 * u, y: cy - 2 * u, width: 1.5 * u, height: 4 * u))
    }

    static func drawSafariBar(_ ctx: CGContext, rect: CGRect, u: CGFloat, dark: Bool, host: String) {
        let pill = CGRect(x: rect.minX + 14 * u, y: rect.minY + 8 * u, width: rect.width - 28 * u, height: 46 * u)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3 * u), blur: 14 * u, color: CGColor(gray: 0, alpha: dark ? 0.5 : 0.16))
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.setFillColor((dark ? RGBA.hex("#2C2C2E") : RGBA(1, 1, 1)).cg); ctx.fillPath()
        ctx.restoreGState()
        let f = Fonts.font(name: nil, size: 15.5 * u, weight: .medium)
        let ink = dark ? RGBA(1, 1, 1, 0.9) : RGBA(0, 0, 0, 0.85)
        let tw = lineWidth(host, font: f)
        let lx = pill.midX - (tw + 15 * u) / 2
        lock(ctx, x: lx, y: pill.midY, u: u * 1.05, color: ink.with(alpha: 0.55))
        drawLine(ctx, host, font: f, color: ink, at: CGPoint(x: lx + 15 * u, y: pill.midY))
        // Home indicator
        let hi = CGRect(x: rect.midX - 67 * u, y: rect.maxY - 9 * u, width: 134 * u, height: 5 * u)
        ctx.addPath(CGPath(roundedRect: hi, cornerWidth: 2.5 * u, cornerHeight: 2.5 * u, transform: nil))
        ctx.setFillColor((dark ? RGBA(1, 1, 1, 0.9) : RGBA(0, 0, 0, 0.9)).cg); ctx.fillPath()
    }
}
