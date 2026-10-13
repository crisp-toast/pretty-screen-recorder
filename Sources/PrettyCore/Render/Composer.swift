import Foundation
import CoreImage
import CoreGraphics

/// Renders one output frame. Build once per (project, output size); call `render` per frame.
public final class Composer {
    public let studio: Studio
    public let size: CGSize
    public let layout: StageLayout
    public let camera: CameraTrack
    public let hud: HUD
    let W: CGFloat, H: CGFloat, S: CGFloat
    let p: Project

    private let background: CIImage
    private let shadow: CIImage
    private let under: CIImage?
    private let over: CIImage?
    private let outerMask: CIImage?
    private let screenMask: CIImage?
    private let cursorArt = CursorArt()
    private let rippleArt = RippleArt()
    private let rippleColor: RGBA
    private let cursorBoost: CGFloat
    private let shutter: Double
    private let blurSamples: Int
    private var overlayCache: [Int: CIImage] = [:]
    private let darkBG: Bool

    public init(studio: Studio, size: CGSize) {
        self.studio = studio
        self.size = size
        p = studio.project
        W = size.width; H = size.height; S = min(W, H)
        let crop = studio.cropRect
        let ftype = studio.hasVideo ? Frames.resolveType(p.frame, source: p.source, videoSize: crop.size) : "none"
        let frame = Frames.build(type: ftype, spec: p.frame, source: p.source, videoSize: crop.size,
                                 corners: p.layout.corners, border: p.layout.border)
        layout = StageLayout(outputSize: size, frame: frame, layout: p.layout, videoSize: crop.size, cropOrigin: crop.origin)
        camera = CameraTrack(layout: layout, zoom: p.zoom, motion: p.motion, map: studio.map,
                             cursor: studio.cursor, fullVideoSize: studio.videoSize)
        darkBG = Backgrounds.isDark(p.background, brand: p.brand.colors)
        hud = HUD(output: size, darkBackground: darkBG, brand: p.brand, baseURL: studio.baseURL)
        if studio.hasVideo && layout.baseZoom <= 1.001 { hud.contentRest = layout.framedRect }
        background = p.background.type == "blur" ? CIImage.empty() :
            Backgrounds.render(p.background, size: size, brand: p.brand.colors, baseURL: studio.baseURL)
        rippleColor = RGBA.parse(p.cursor.ripple.color, brand: p.brand.colors) ?? RGBA.hex("#3B82F6")
        let maxLevel = p.zoom.segments.map(\.level).max() ?? 1
        cursorBoost = clamp(CGFloat(maxLevel) * layout.baseZoom, 1, 3.5)
        switch p.motion.blur {
        case "off", "none": shutter = 0; blurSamples = 1
        case "low": shutter = 0.3; blurSamples = 4
        case "high": shutter = 0.85; blurSamples = 9
        default: shutter = 0.5; blurSamples = 6
        }

        let fr = layout.framedRect
        let sc = layout.scale
        under = frame.under.map { CIImage(cgImage: $0).placed(in: fr, stageHeight: size.height) }
        over = frame.over.map { CIImage(cgImage: $0).placed(in: fr, stageHeight: size.height) }

        // Masks drawn in frame space (source resolution) so edges stay crisp when zoomed.
        let fw = Int(frame.outerSize.width.rounded(.up)), fh = Int(frame.outerSize.height.rounded(.up))
        if frame.maskOuter {
            outerMask = CIImage.from(drawImage(width: fw, height: fh) { ctx in
                ctx.addPath(frame.outerPath); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
            }).placed(in: fr, stageHeight: size.height)
        } else { outerMask = nil }
        if frame.screenRadius > 0 {
            screenMask = CIImage.from(drawImage(width: fw, height: fh) { ctx in
                ctx.addPath(roundedRect(frame.screenRect, frame.screenRadius)); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
            }).placed(in: fr, stageHeight: size.height)
        } else { screenMask = nil }

        // Soft two-layer drop shadow from the frame silhouette.
        let strength = CGFloat(clamp(p.layout.shadow, 0, 1))
        if strength > 0.01 && studio.hasVideo {
            let sil = CIImage.from(drawImage(width: Int(size.width), height: Int(size.height)) { ctx in
                ctx.translateBy(x: fr.minX, y: fr.minY); ctx.scaleBy(x: sc, y: sc)
                ctx.addPath(frame.outerPath); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
            })
            let S = min(size.width, size.height)
            let ambient = sil.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": S * 0.045])
                .cropped(to: CGRect(origin: .zero, size: size))
                .transformed(by: CGAffineTransform(translationX: 0, y: -S * 0.018)).opacity(0.55 * strength)
            let key = sil.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": S * 0.009])
                .cropped(to: CGRect(origin: .zero, size: size))
                .transformed(by: CGAffineTransform(translationX: 0, y: -S * 0.004)).opacity(0.35 * strength)
            shadow = key.over(ambient)
        } else {
            shadow = CIImage.empty()
        }
    }

    // MARK: - Frame

    /// - t: output time. `source`: the video frame for this time (extent at 0,0, video pixels).
    public func render(t: Double, source: CIImage?, cameraFrame: CIImage? = nil) -> CIImage {
        let s = studio.map.source(atOutput: t)
        let full = CGRect(origin: .zero, size: size)

        // 1. Content (the recording) placed on the stage.
        var stageBase = CIImage.empty()
        if let src = source, studio.hasVideo {
            var content = src
            let crop = studio.cropRect
            if crop.size != studio.videoSize {
                let ciCrop = CGRect(x: crop.minX, y: studio.videoSize.height - crop.maxY, width: crop.width, height: crop.height)
                content = content.cropped(to: ciCrop).transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
            }
            content = applyContentOverlays(content, s: s)
            let vr = layout.videoStageRect
            let sx = vr.width / crop.width, sy = vr.height / crop.height
            content = content.transformed(by: CGAffineTransform(scaleX: sx, y: sy)
                .concatenating(CGAffineTransform(translationX: vr.minX, y: H - vr.maxY)))
            if let m = screenMask { content = content.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": m]) }
            var framed = content
            if let u = under { framed = framed.over(u) }
            if let o = over { framed = o.over(framed) }
            if let m = outerMask { framed = framed.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": m]) }
            stageBase = framed
            stageBase = stageOverlays(s: s, t: t).over(stageBase)
            stageBase = ripples(s: s).over(stageBase)
        }

        // 2. Camera + cursor, with motion blur from sub-frame sampling.
        let bg: CIImage = p.background.type == "blur" ? blurredBackground(source) : background
        let subs = subTimes(t)
        let states = subs.map { camera.state(at: $0) }
        let camMoving: Bool = {
            guard states.count > 1, let a = states.first, let b = states.last else { return false }
            let dzPx = abs(a.zoom - b.zoom) * max(W, H) / 2
            let dcPx = hypot(a.center.x - b.center.x, a.center.y - b.center.y) * a.zoom
            return dzPx + dcPx > 0.75
        }()
        let tilted = p.layout.tiltX != 0 || p.layout.tiltY != 0
        var composed: CIImage
        if camMoving {
            var acc: CIImage? = nil
            let w = 1 / CGFloat(subs.count)
            for (i, st) in states.enumerated() {
                var stage = cursorLayer(times: [subs[i]]).over(stageBase)
                stage = tilted ? tilt(stage.over(shadow)) : stage.over(shadow)
                let frameImg = stage.over(bg).transformed(by: ciCamera(st)).cropped(to: full).opacity(w)
                acc = acc.map { frameImg.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": $0]) } ?? frameImg
            }
            composed = acc ?? CIImage.empty()
        } else {
            let st = camera.state(at: t)
            var stage = cursorLayer(times: subs).over(stageBase)
            stage = tilted ? tilt(stage.over(shadow)) : stage.over(shadow)
            composed = stage.over(bg).transformed(by: ciCamera(st)).cropped(to: full)
        }

        // 3. Screen-space HUD.
        var hudLayer = CIImage.empty()
        if let cam = cameraFrame, p.camera.show { hudLayer = cameraBubble(cam, t: t).over(hudLayer) }
        if p.keystrokes.show {
            for item in studio.keyItems where s >= item.start && s <= item.end {
                if let k = hud.keystrokes(item, s: s, spec: p.keystrokes) { hudLayer = k.over(hudLayer) }
            }
        }
        if p.captions.show {
            for c in studio.captions where t >= c.start && t <= c.end {
                hudLayer = hud.caption(c.text, spec: p.captions, t: t, start: c.start, end: c.end).over(hudLayer)
            }
        }
        // Where the recording lands on screen right now (for text legibility decisions).
        let camNow = camera.state(at: t)
        let contentOnScreen = studio.hasVideo ? layout.framedRect.applying(CameraTrack.transform(camNow, output: size)) : nil
        for o in p.overlays where o.type == "text" || o.type == "image" {
            let tt = o.usesSourceTime ? s : t
            if let img = hud.overlay(o, t: tt, contentRect: contentOnScreen) { hudLayer = img.over(hudLayer) }
        }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: full)
        var final = hudLayer.over(composed).over(black).cropped(to: full)
        // Output-space dither: kills gradient banding in 8-bit encodes, never scales with zoom.
        if p.background.grain > 0 {
            final = final.applyingFilter("CIDither", parameters: ["inputIntensity": 0.08 * clamp(p.background.grain, 0, 1)]).cropped(to: full)
        }
        return final
    }

    // MARK: - Pieces

    private func ciCamera(_ st: CameraState) -> CGAffineTransform {
        CGAffineTransform(translationX: W / 2, y: H / 2)
            .scaledBy(x: st.zoom, y: st.zoom)
            .translatedBy(x: -st.center.x, y: -(H - st.center.y))
    }

    private func subTimes(_ t: Double) -> [Double] {
        guard shutter > 0, blurSamples > 1 else { return [t] }
        let fps = Double(max(1, frameRateHint))
        let span = shutter / fps
        let cuts = studio.map.cutPoints
        return (0..<blurSamples).map { i in
            var st = t - span / 2 + span * Double(i) / Double(blurSamples - 1)
            // Never blur across a cut.
            for c in cuts where (t >= c && st < c) { st = c }
            for c in cuts where (t < c && st >= c) { st = c - 1e-4 }
            return clamp(st, 0, studio.outputDuration)
        }
    }

    /// Set by the exporter so motion blur uses the right shutter interval.
    public var frameRateHint: Int = 60
    /// Platform-safe area for text (fractions top, bottom, left, right).
    public var safeArea: [Double] { get { hud.safe } set { hud.safe = newValue } }

    /// Convenience: size, fps and safe area from export settings.
    public convenience init(studio: Studio, settings: ExportSettings) {
        self.init(studio: studio, size: settings.size)
        frameRateHint = settings.fps
        safeArea = settings.safe
    }

    private func cursorLayer(times: [Double]) -> CIImage {
        guard p.cursor.show, studio.hasVideo, studio.cursor.hasData else { return CIImage.empty() }
        let ps = CGFloat(max(1, studio.events.pointScale))
        let pt = ps * layout.contentScale * CGFloat(p.cursor.size)
        guard pt > 0.05 else { return CIImage.empty() }
        var positions: [(CGPoint, Double, Double, String)] = []
        for t in times {
            let s = studio.map.source(atOutput: t)
            let v = studio.cursor.visibility(at: s)
            if v <= 0.01 { continue }
            positions.append((layout.stagePoint(studio.cursor.position(at: s)), v, studio.cursor.press(at: s), studio.cursor.kind(at: s)))
        }
        guard !positions.isEmpty else { return CIImage.empty() }
        let spread = positions.count > 1 ? hypot(positions.first!.0.x - positions.last!.0.x, positions.first!.0.y - positions.last!.0.y) : 0
        let use = spread > 1.5 ? positions : [positions[positions.count / 2]]
        let w = 1 / CGFloat(use.count)
        var acc: CIImage? = nil
        for (pos, vis, press, kind) in use {
            let sprite = cursorArt.sprite(kind: kind, style: p.cursor.style, pt: pt * cursorBoost, shadow: p.cursor.shadow)
            let pressScale: CGFloat = p.cursor.pressEffect ? 1 - 0.17 * CGFloat(press) : 1
            let f = pt * pressScale / sprite.scale
            let img = sprite.image.transformed(by: CGAffineTransform(scaleX: f, y: f)
                .concatenating(CGAffineTransform(translationX: pos.x - sprite.hotspot.x * f,
                                                 y: (H - pos.y) - (sprite.size.height - sprite.hotspot.y) * f)))
                .opacity(CGFloat(vis) * (use.count > 1 ? w : 1))
            if use.count > 1 {
                acc = acc.map { img.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": $0]) } ?? img
            } else { acc = img }
        }
        return acc ?? CIImage.empty()
    }

    private func ripples(s: Double) -> CIImage {
        guard p.cursor.ripple.enabled, studio.hasVideo else { return CIImage.empty() }
        let ps = CGFloat(max(1, studio.events.pointScale))
        let touch = p.cursor.style == "touch"
        let R = (touch ? 34 : 26) * ps * layout.contentScale * CGFloat(p.cursor.ripple.size) * (touch ? 1 : CGFloat(max(1, p.cursor.size)) / 1.5)
        var out = CIImage.empty()
        for (c, prog) in studio.cursor.ripples(at: s) {
            let img = rippleArt.frame(progress: prog, color: rippleColor, style: p.cursor.ripple.style)
            let canvas = CGFloat(RippleArt.canvas)
            let f = (2 * R) / (canvas - 8)
            let pos = layout.stagePoint(CGPoint(x: c.x, y: c.y))
            out = img.transformed(by: CGAffineTransform(scaleX: f, y: f)
                .concatenating(CGAffineTransform(translationX: pos.x - canvas * f / 2, y: H - pos.y - canvas * f / 2))).over(out)
        }
        return out
    }

    /// Blur regions applied inside the recording (privacy redaction).
    private func applyContentOverlays(_ content: CIImage, s: Double) -> CIImage {
        var img = content
        let vw = content.extent.width, vh = content.extent.height
        let crop = studio.cropRect
        for o in p.overlays where o.type == "blur" {
            let tt = o.usesSourceTime ? s : studio.map.output(atSource: s)
            guard tt >= o.start, tt <= o.end, let r = o.rect else { continue }
            let fade = CGFloat(min(clamp((tt - o.start) / 0.2, 0, 1), clamp((o.end - tt) / 0.2, 0, 1)))
            let px = CGRect(x: r.x * studio.videoSize.width - crop.minX, y: r.y * studio.videoSize.height - crop.minY,
                            width: r.w * studio.videoSize.width, height: r.h * studio.videoSize.height)
            let ci = CGRect(x: px.minX, y: vh - px.maxY, width: px.width, height: px.height).intersection(CGRect(x: 0, y: 0, width: vw, height: vh))
            guard !ci.isEmpty else { continue }
            let radius = CGFloat(o.amount) * vw / 1440
            let blurred = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: ci)
            img = blurred.opacity(fade).over(img)
        }
        return img
    }

    /// Spotlight (dim everything but a rect) and highlight boxes, in stage space.
    private func stageOverlays(s: Double, t: Double) -> CIImage {
        var out = CIImage.empty()
        for (i, o) in p.overlays.enumerated() where o.type == "spotlight" || o.type == "highlight" {
            let tt = o.usesSourceTime ? s : t
            guard tt >= o.start, tt <= o.end, let r = o.rect else { continue }
            let fade = CGFloat(min(clamp((tt - o.start) / 0.35, 0, 1), clamp((o.end - tt) / 0.35, 0, 1)))
            let img: CIImage
            if let c = overlayCache[i] { img = c } else {
                let rect = layout.stageRect(normalized: r, fullSize: studio.videoSize)
                let rad = CGFloat(o.radius) * S
                let cg = drawImage(width: Int(W), height: Int(H)) { ctx in
                    if o.type == "spotlight" {
                        ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(clamp(o.dim, 0, 1))))
                        ctx.addRect(CGRect(x: 0, y: 0, width: W, height: H))
                        ctx.addPath(roundedRect(rect.insetBy(dx: -rad * 0.4, dy: -rad * 0.4), rad))
                        ctx.fillPath(using: .evenOdd)
                    } else {
                        let col = RGBA.parse(o.color == "auto" ? "brand:0" : o.color, brand: p.brand.colors) ?? RGBA.hex("#3B82F6")
                        let lw = max(2, S * 0.004)
                        ctx.setShadow(offset: .zero, blur: S * 0.012, color: col.with(alpha: 0.75).cg)
                        ctx.addPath(roundedRect(rect.insetBy(dx: -lw * 1.5, dy: -lw * 1.5), rad))
                        ctx.setStrokeColor(col.cg); ctx.setLineWidth(lw); ctx.strokePath()
                    }
                }
                img = CIImage.from(cg)
                overlayCache[i] = img
            }
            out = img.opacity(fade).over(out)
        }
        return out
    }

    private func blurredBackground(_ source: CIImage?) -> CIImage {
        let full = CGRect(origin: .zero, size: size)
        guard let src = source else { return CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.06)).cropped(to: full) }
        let e = src.extent
        let sc = max(W / e.width, H / e.height) * 1.15
        var img = src.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
        img = img.transformed(by: CGAffineTransform(translationX: (W - img.extent.width) / 2 - img.extent.minX,
                                                    y: (H - img.extent.height) / 2 - img.extent.minY))
        img = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": S * 0.05])
            .applyingFilter("CIColorControls", parameters: ["inputSaturationKey": 1.25, "inputBrightnessKey": -0.08])
        return img.cropped(to: full)
    }

    private func tilt(_ img: CIImage) -> CIImage {
        let fr = layout.framedRect
        let ci = CGRect(x: fr.minX, y: H - fr.maxY, width: fr.width, height: fr.height)
        let ax = CGFloat(p.layout.tiltX) * .pi / 180, ay = CGFloat(p.layout.tiltY) * .pi / 180
        let f = max(W, H) * 2.2
        let c = CGPoint(x: ci.midX, y: ci.midY)
        func project(_ x: CGFloat, _ y: CGFloat) -> CIVector {
            // Rotate around Y (tiltY) then X (tiltX); simple pinhole projection.
            var px = x - c.x, py = y - c.y, pz: CGFloat = 0
            let x1 = px * cos(ay) + pz * sin(ay); let z1 = -px * sin(ay) + pz * cos(ay); px = x1; pz = z1
            let y2 = py * cos(ax) - pz * sin(ax); let z2 = py * sin(ax) + pz * cos(ax); py = y2; pz = z2
            let k = f / (f + pz)
            return CIVector(x: c.x + px * k, y: c.y + py * k)
        }
        return img.applyingFilter("CIPerspectiveTransformWithExtent", parameters: [
            "inputExtent": CIVector(cgRect: ci),
            "inputTopLeft": project(ci.minX, ci.maxY), "inputTopRight": project(ci.maxX, ci.maxY),
            "inputBottomLeft": project(ci.minX, ci.minY), "inputBottomRight": project(ci.maxX, ci.minY),
        ])
    }

    private func cameraBubble(_ frame: CIImage, t: Double) -> CIImage {
        let c = p.camera
        let st = camera.state(at: t)
        let aspect: CGFloat
        var width: CGFloat
        switch c.shape {
        case "rectangle": aspect = 4.0 / 3.0; width = S * CGFloat(c.size) * 1.3
        case "vertical": aspect = 3.0 / 4.0; width = S * CGFloat(c.size) * 0.85
        default: aspect = 1; width = S * CGFloat(c.size)
        }
        if c.shrinkOnZoom { width *= 1 - 0.22 * st.zoomAmount }
        let height = width / aspect
        let radius: CGFloat = c.shape == "circle" ? width / 2 : min(width, height) * (c.shape == "square" ? 0.22 : 0.12)
        // Center-crop the camera frame to the bubble aspect, mirror if needed, scale.
        var img = frame
        let e = img.extent
        let cropW = min(e.width, e.height * aspect), cropH = cropW / aspect
        img = img.cropped(to: CGRect(x: e.midX - cropW / 2, y: e.midY - cropH / 2, width: cropW, height: cropH))
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        if c.flip { img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -cropW, y: 0)) }
        img = img.transformed(by: CGAffineTransform(scaleX: width / cropW, y: height / cropH))
        let margin = S * 0.035
        let pos = c.position
        var x = (W - width) / 2, yTop = (H - height) / 2
        if pos.hasSuffix("left") { x = margin }
        if pos.hasSuffix("right") { x = W - margin - width }
        if pos.hasPrefix("top") { yTop = margin }
        if pos.hasPrefix("bottom") { yTop = H - margin - height }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let mask = CIImage.from(drawImage(width: Int(width.rounded(.up)), height: Int(height.rounded(.up))) { ctx in
            ctx.addPath(roundedRect(rect, radius)); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        })
        var bubble = img.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": mask])
        if c.border > 0 {
            let col = RGBA.parse(c.borderColor, brand: p.brand.colors) ?? RGBA(1, 1, 1)
            let ring = CIImage.from(drawImage(width: Int(width.rounded(.up)), height: Int(height.rounded(.up))) { ctx in
                let lw = CGFloat(c.border) * S / 1080
                ctx.addPath(roundedRect(rect.insetBy(dx: lw / 2, dy: lw / 2), radius - lw / 2))
                ctx.setStrokeColor(col.cg); ctx.setLineWidth(lw); ctx.strokePath()
            })
            bubble = ring.over(bubble)
        }
        let shadowImg = mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": S * 0.012])
            .cropped(to: rect.insetBy(dx: -S * 0.05, dy: -S * 0.05)).transformed(by: CGAffineTransform(translationX: 0, y: -S * 0.006)).opacity(0.45)
        return bubble.over(shadowImg).transformed(by: CGAffineTransform(translationX: x, y: H - yTop - height))
    }
}
