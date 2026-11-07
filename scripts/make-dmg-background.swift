// Draws the disk-image window background (660×420 pt) at 1x and 2x.
// usage: swift scripts/make-dmg-background.swift <out-dir>
import AppKit
import CoreGraphics
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let W: CGFloat = 660, H: CGFloat = 420
// Icon centers (points, top-left origin) — must match scripts/dmg-settings.py.
let appPt = CGPoint(x: 170, y: 196), appsPt = CGPoint(x: 490, y: 196)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> CGImage {
    let w = Int(W * scale), h = Int(H * scale)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Top-left coordinates.
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)

    // Light, Apple-style base (Finder draws icon labels in black on background pictures,
    // even in Dark Mode — so the art stays light) with the app's colors glowing in.
    let base = CGGradient(colorsSpace: cs, colors: [color(0xFBFBFD), color(0xEEEEF3)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H), options: [])
    func glow(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
        let g = CGGradient(colorsSpace: cs, colors: [color(hex, a), color(hex, a * 0.4), color(hex, 0)] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }
    glow(CGPoint(x: 80, y: 30), 320, 0x8C7DFF, 0.22)
    glow(CGPoint(x: 610, y: 60), 300, 0x3FD3FF, 0.18)
    glow(CGPoint(x: 540, y: 440), 300, 0xFF7FB5, 0.14)

    // Soft platforms under the icons (tall enough to hold Finder's labels).
    for p in [appPt, appsPt] {
        let r = CGRect(x: p.x - 88, y: p.y - 84, width: 176, height: 196)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: CGColor(gray: 0, alpha: 0.08))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 36, cornerHeight: 36, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.72)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 36, cornerHeight: 36, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.06)); ctx.setLineWidth(1); ctx.strokePath()
    }

    // Arrow: a gentle arc from the app to Applications, in the app's gradient.
    let start = CGPoint(x: appPt.x + 100, y: appPt.y), end = CGPoint(x: appsPt.x - 104, y: appsPt.y)
    let ctrl = CGPoint(x: (start.x + end.x) / 2, y: appPt.y - 34)
    let path = CGMutablePath()
    path.move(to: start); path.addQuadCurve(to: end, control: ctrl)
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: 3.2, lineCap: .round, lineJoin: .round, miterLimit: 2))
    ctx.clip()
    let arrowGrad = CGGradient(colorsSpace: cs, colors: [color(0x6E5BFF), color(0x00A8E8)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(arrowGrad, start: start, end: end, options: [])
    ctx.restoreGState()
    // Arrowhead along the curve's end tangent.
    let dir = CGPoint(x: end.x - ctrl.x, y: end.y - ctrl.y)
    let len = max(0.001, hypot(dir.x, dir.y))
    let u = CGPoint(x: dir.x / len, y: dir.y / len), n = CGPoint(x: -u.y, y: u.x)
    let tip = CGPoint(x: end.x + u.x * 6, y: end.y + u.y * 6)
    let head = CGMutablePath()
    head.move(to: CGPoint(x: tip.x - u.x * 14 + n.x * 8, y: tip.y - u.y * 14 + n.y * 8))
    head.addLine(to: tip)
    head.addLine(to: CGPoint(x: tip.x - u.x * 14 - n.x * 8, y: tip.y - u.y * 14 - n.y * 8))
    ctx.addPath(head.copy(strokingWithWidth: 3.2, lineCap: .round, lineJoin: .round, miterLimit: 2))
    ctx.setFillColor(color(0x00A8E8)); ctx.fillPath()

    // Type.
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat, tracking: CGFloat = 0) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: alpha), .kern: tracking])
        let line = CTLineCreateWithAttributedString(attr)
        let bw = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.translateBy(x: (W - CGFloat(bw)) / 2, y: y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
    text("Drag Pretty Studio to Applications", size: 19, weight: .semibold, alpha: 0.92, y: 64, tracking: -0.2)
    text("Then open it — a short setup gets your voice, music and agents ready.", size: 12, weight: .regular, alpha: 0.5, y: 372)
    return ctx.makeImage()!
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let img = render(scale: scale)
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
print(out.path)
