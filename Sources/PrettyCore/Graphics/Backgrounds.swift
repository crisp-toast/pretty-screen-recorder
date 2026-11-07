import Foundation
import CoreGraphics
import CoreImage

/// Built-in backgrounds: soft "mesh" gradients made of large blurred color fields,
/// in the spirit of macOS wallpapers and CleanShot's built-in set.
public struct GradientPreset {
    public struct Blob { public var x, y, r: CGFloat; public var color: String }
    public var name: String
    public var base: String
    public var blobs: [Blob]
    public var dark: Bool

    init(_ name: String, _ base: String, dark: Bool, _ blobs: [(CGFloat, CGFloat, CGFloat, String)]) {
        self.name = name; self.base = base; self.dark = dark
        self.blobs = blobs.map { Blob(x: $0.0, y: $0.1, r: $0.2, color: $0.3) }
    }
}

public enum Backgrounds {
    public static let presets: [GradientPreset] = [
        GradientPreset("aurora", "#0B1E4B", dark: true, [(0.12, 0.18, 0.75, "#6D5BFF"), (0.88, 0.22, 0.65, "#00C2FF"), (0.78, 0.98, 0.7, "#FF5FA2"), (0.25, 0.92, 0.55, "#1F3BFF")]),
        GradientPreset("sky", "#8FBFF2", dark: false, [(0.15, 0.1, 0.75, "#EAF3FF"), (0.85, 0.85, 0.75, "#3F7FE0"), (0.92, 0.1, 0.45, "#BFDDFF"), (0.1, 0.95, 0.5, "#6EA8F0")]),
        GradientPreset("dusk", "#7184D9", dark: false, [(0.92, 0.95, 0.75, "#F4A8C6"), (0.08, 0.08, 0.65, "#8FBAF2"), (0.55, 0.5, 0.5, "#B59BE3"), (0.1, 0.9, 0.45, "#5B6FD0")]),
        GradientPreset("sunset", "#FF7A59", dark: false, [(0.08, 0.1, 0.7, "#FFC371"), (0.9, 0.85, 0.75, "#FF4E8D"), (0.88, 0.08, 0.5, "#8A4BEA"), (0.2, 0.95, 0.5, "#FF9466")]),
        GradientPreset("ocean", "#0A4D8C", dark: true, [(0.18, 0.85, 0.7, "#00B4D8"), (0.9, 0.15, 0.55, "#90E0EF"), (0.85, 0.95, 0.6, "#023E8A"), (0.1, 0.1, 0.5, "#0077B6")]),
        GradientPreset("lavender", "#CDB8F5", dark: false, [(0.85, 0.2, 0.65, "#F6C6EA"), (0.15, 0.85, 0.7, "#A9C6FF"), (0.4, 0.3, 0.55, "#EDE4FF"), (0.9, 0.9, 0.5, "#C3A6F2")]),
        GradientPreset("peach", "#FFD3B6", dark: false, [(0.88, 0.82, 0.7, "#FFAAA5"), (0.12, 0.12, 0.7, "#FFF1D6"), (0.92, 0.08, 0.45, "#FF8FA3"), (0.1, 0.9, 0.5, "#FFC9A0")]),
        GradientPreset("mint", "#A8E6CF", dark: false, [(0.15, 0.2, 0.7, "#E4F6C8"), (0.85, 0.85, 0.7, "#4FBFB0"), (0.82, 0.12, 0.5, "#CFF5EA"), (0.1, 0.92, 0.5, "#7FD8BE")]),
        GradientPreset("midnight", "#070A1A", dark: true, [(0.2, 0.2, 0.75, "#1B2A6B"), (0.85, 0.82, 0.65, "#4A1D6E"), (0.88, 0.12, 0.5, "#0E3A5B"), (0.15, 0.95, 0.45, "#141B45")]),
        GradientPreset("graphite", "#1C1C1F", dark: true, [(0.2, 0.12, 0.85, "#3A3A42"), (0.82, 0.92, 0.7, "#26262C"), (0.9, 0.1, 0.45, "#2E2E35")]),
        GradientPreset("candy", "#FF9AC1", dark: false, [(0.85, 0.18, 0.7, "#9AD0FF"), (0.15, 0.85, 0.65, "#FFD1E8"), (0.6, 0.6, 0.45, "#B79CFF"), (0.08, 0.1, 0.45, "#FFB3D1")]),
        GradientPreset("ember", "#2A0A0A", dark: true, [(0.85, 0.88, 0.75, "#E8492F"), (0.95, 0.3, 0.45, "#FF9A3C"), (0.1, 0.2, 0.6, "#5E0F2A"), (0.3, 0.95, 0.4, "#8A1C1C")]),
        GradientPreset("forest", "#0F3D2E", dark: true, [(0.8, 0.2, 0.65, "#2E8B57"), (0.9, 0.92, 0.45, "#A3D977"), (0.1, 0.9, 0.6, "#0B2A20"), (0.15, 0.1, 0.45, "#1E6B4A")]),
        GradientPreset("sand", "#E9DCC9", dark: false, [(0.2, 0.2, 0.75, "#F7EFE3"), (0.85, 0.85, 0.7, "#D6B88F"), (0.9, 0.1, 0.4, "#EFD9BC")]),
        GradientPreset("noir", "#050505", dark: true, [(0.5, 0.38, 0.9, "#1E1E22"), (0.15, 0.95, 0.5, "#0B0B0D")]),
        GradientPreset("cloud", "#EEF0F5", dark: false, [(0.3, 0.2, 0.85, "#FFFFFF"), (0.82, 0.9, 0.65, "#DCE1EB"), (0.95, 0.1, 0.4, "#F7F8FB")]),
        GradientPreset("grape", "#3B1C6B", dark: true, [(0.82, 0.2, 0.7, "#8E44EC"), (0.9, 0.92, 0.55, "#E255A1"), (0.1, 0.9, 0.6, "#24124A"), (0.12, 0.12, 0.45, "#5B2BA8")]),
        GradientPreset("lagoon", "#0E7C86", dark: true, [(0.2, 0.2, 0.65, "#4FD1C5"), (0.85, 0.85, 0.7, "#2B6CB0"), (0.9, 0.1, 0.4, "#9AE6B4"), (0.1, 0.92, 0.45, "#0B5E73")]),
        GradientPreset("rose", "#F43F5E", dark: false, [(0.15, 0.15, 0.65, "#FDA4AF"), (0.85, 0.9, 0.65, "#BE123C"), (0.82, 0.2, 0.45, "#FB7185"), (0.1, 0.92, 0.45, "#E11D48")]),
        GradientPreset("citrus", "#FDE047", dark: false, [(0.85, 0.85, 0.65, "#F97316"), (0.15, 0.15, 0.65, "#FEF9C3"), (0.1, 0.9, 0.45, "#84CC16"), (0.92, 0.12, 0.4, "#FACC15")]),
    ]

    public static func preset(_ name: String) -> GradientPreset? {
        presets.first { $0.name == name.lowercased() }
    }

    /// Approximate perceived darkness of a background (for auto text color).
    public static func isDark(_ spec: BackgroundSpec, brand: [String]) -> Bool {
        switch spec.type {
        case "color": return (RGBA.parse(spec.color, brand: brand) ?? RGBA(0, 0, 0)).luminance < 0.5
        case "gradient":
            if spec.colors.count >= 2 {
                let cs = spec.colors.compactMap { RGBA.parse($0, brand: brand) }
                return cs.map(\.luminance).reduce(0, +) / CGFloat(max(1, cs.count)) < 0.5
            }
            return preset(spec.preset)?.dark ?? true
        case "none": return true
        case "stage": return !["studio", "paper"].contains(spec.preset)
        default: return true
        }
    }

    public static let stages = ["keynote", "studio", "glow", "paper", "cinema"]

    /// Modern stages: restrained, lit backdrops (not wallpapers). Drawn small and blurred for silky
    /// light falloff; the output dither keeps them band-free.
    public static func stage(_ name: String, size: CGSize, brand: [String], focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> CIImage {
        let full = CGRect(origin: .zero, size: size)
        let aspect = size.width / max(size.height, 1)
        let sh = 320, sw = max(8, Int(320 * aspect))
        let cs = brand.compactMap { RGBA.parse($0) }
        let primary = cs.first ?? RGBA.hex("#0A84FF"), second = cs.count > 1 ? cs[1] : primary.mixed(RGBA.hex("#5E5CE6"), 0.5)
        let cg = drawImage(width: sw, height: sh) { ctx in
            let W = CGFloat(sw), H = CGFloat(sh), D = max(W, H)
            let fx = focus.x * W, fy = focus.y * H
            func fill(_ c: RGBA) { ctx.setFillColor(c.cg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
            func light(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: RGBA) {
                let g = CGGradient(colorsSpace: sRGB, colors: [c.cg, c.with(alpha: c.a * 0.45).cg, c.with(alpha: 0).cg] as CFArray, locations: [0, 0.42, 1])!
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
            }
            func vignette(_ a: CGFloat) {
                let g = CGGradient(colorsSpace: sRGB, colors: [RGBA(0, 0, 0, 0).cg, RGBA(0, 0, 0, a).cg] as CFArray, locations: [0.55, 1])!
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: W / 2, y: H * 0.48), startRadius: 0, endCenter: CGPoint(x: W / 2, y: H * 0.48), endRadius: D * 0.75, options: [])
            }
            switch name {
            case "studio":
                // Seamless sweep: lighter behind the subject, falling off to the floor and corners.
                let g = CGGradient(colorsSpace: sRGB, colors: [RGBA.hex("#E9E9ED").cg, RGBA.hex("#F5F5F7").cg, RGBA.hex("#E2E2E7").cg] as CFArray, locations: [0, 0.55, 1])!
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H), options: [])
                light(fx, fy * 0.95, D * 0.55, RGBA(1, 1, 1, 0.85))
                vignette(0.07)
            case "paper":
                fill(RGBA.hex("#F2F0EB"))
                light(W * 0.35, H * 0.3, D * 0.7, RGBA(1, 1, 1, 0.55))
                vignette(0.05)
            case "glow":
                fill(RGBA.hex("#040406"))
                light(fx, fy * 1.02, D * 0.62, Kinetic.darken(primary, to: 0.42).with(alpha: 0.85))
                light(fx + W * 0.18, fy - H * 0.16, D * 0.38, Kinetic.darken(second, to: 0.4).with(alpha: 0.55))
                light(fx, fy, D * 0.2, primary.mixed(RGBA(1, 1, 1), 0.2).with(alpha: 0.35))
                vignette(0.55)
            case "cinema":
                fill(RGBA.hex("#06080A"))
                light(W * 0.2, H * 0.18, D * 0.6, RGBA.hex("#123038").with(alpha: 0.7))
                light(W * 0.85, H * 0.92, D * 0.55, RGBA.hex("#2A1A10").with(alpha: 0.65))
                light(fx, fy, D * 0.35, RGBA.hex("#1A1E22").with(alpha: 0.6))
                vignette(0.7)
            default: // keynote
                fill(RGBA.hex("#000000"))
                light(fx, fy * 0.96, D * 0.55, RGBA.hex("#1C1C21").with(alpha: 1))
                light(fx, fy * 0.96, D * 0.22, RGBA.hex("#26262C").with(alpha: 0.6))
                vignette(0.4)
            }
        }
        var img = CIImage.from(cg)
        let sc = size.height / CGFloat(sh)
        img = img.samplingLinear().transformed(by: CGAffineTransform(scaleX: sc * 1.0001, y: sc * 1.0001))
        img = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": size.height * 0.012])
        return img.cropped(to: full)
    }

    /// Render the background at `size` (output pixels).
    public static func render(_ spec: BackgroundSpec, size: CGSize, brand: [String], baseURL: URL?) -> CIImage {
        let W = size.width, H = size.height
        let full = CGRect(origin: .zero, size: size)
        var img: CIImage
        switch spec.type {
        case "none":
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: full)
        case "color":
            let c = RGBA.parse(spec.color, brand: brand) ?? RGBA(0.06, 0.06, 0.08)
            return CIImage(color: CIColor(cgColor: c.cg)).cropped(to: full)
        case "stage":
            return stage(spec.preset, size: size, brand: brand)
        case "image":
            guard let path = spec.image, let cg = loadCGImage(resolve(path, baseURL)) else {
                Log.warn("background image not found: \(spec.image ?? "(none)"); using gradient")
                var g = spec; g.type = "gradient"
                return render(g, size: size, brand: brand, baseURL: baseURL)
            }
            let src = CIImage(cgImage: cg)
            // Aspect-fill.
            let s = max(W / src.extent.width, H / src.extent.height)
            img = src.transformed(by: CGAffineTransform(scaleX: s, y: s))
            img = img.transformed(by: CGAffineTransform(translationX: (W - img.extent.width) / 2 - img.extent.minX,
                                                        y: (H - img.extent.height) / 2 - img.extent.minY))
            if spec.blur > 0 {
                img = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": spec.blur * min(W, H) / 1080])
            }
            return img.cropped(to: full)
        default:
            img = gradientImage(spec, size: size, brand: brand)
        }
        return img.cropped(to: full)
    }

    public static func resolve(_ path: String, _ base: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if let base { return base.appendingPathComponent(path) }
        return URL(fileURLWithPath: path)
    }

    static func gradientImage(_ spec: BackgroundSpec, size: CGSize, brand: [String]) -> CIImage {
        // Draw small, then upscale + blur: silky gradients at a fraction of the cost.
        let aspect = size.width / max(size.height, 1)
        let sh = 240, sw = max(8, Int(240 * aspect))
        let custom = spec.colors.compactMap { RGBA.parse($0, brand: brand) }
        let cg = drawImage(width: sw, height: sh) { ctx in
            let W = CGFloat(sw), H = CGFloat(sh), D = max(W, H)
            if custom.count >= 2 {
                // Custom linear gradient at `angle`, softened with a couple of glow blobs.
                let rad = spec.angle * .pi / 180
                let dx = cos(rad), dy = sin(rad)
                let half = (abs(dx) * W + abs(dy) * H) / 2
                let c = CGPoint(x: W / 2, y: H / 2)
                let g = CGGradient(colorsSpace: sRGB, colors: custom.map(\.cg) as CFArray,
                                   locations: custom.indices.map { CGFloat($0) / CGFloat(custom.count - 1) })!
                ctx.drawLinearGradient(g, start: CGPoint(x: c.x - dx * half, y: c.y - dy * half),
                                       end: CGPoint(x: c.x + dx * half, y: c.y + dy * half),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                let glow = custom[custom.count / 2].mixed(RGBA(1, 1, 1), 0.25)
                radial(ctx, CGPoint(x: W * 0.25, y: H * 0.2), D * 0.55, glow.with(alpha: 0.35))
                return
            }
            let p = preset(spec.preset) ?? presets[0]
            ctx.setFillColor(RGBA.hex(p.base).cg)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            for b in p.blobs {
                radial(ctx, CGPoint(x: b.x * W, y: b.y * H), b.r * D, RGBA.hex(b.color))
            }
        }
        var img = CIImage.from(cg)
        let s = size.height / CGFloat(sh)
        img = img.samplingLinear().transformed(by: CGAffineTransform(scaleX: s * 1.0001, y: s * 1.0001))
        img = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": size.height * 0.035])
        return img.cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func radial(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: RGBA) {
        let g = CGGradient(colorsSpace: sRGB, colors: [color.cg, color.with(alpha: color.a * 0.55).cg, color.with(alpha: 0).cg] as CFArray,
                           locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }

}
