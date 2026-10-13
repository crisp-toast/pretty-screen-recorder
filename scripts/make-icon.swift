// Renders the Pretty Studio app icon (1024px PNG). Usage: swift make-icon.swift out.png
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)   // top-left origin

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func squircle(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    let p = CGMutablePath(); let k = rad * 1.6
    p.move(to: CGPoint(x: r.minX + k, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY)); p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + k), control1: CGPoint(x: r.maxX - k * 0.18, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + k * 0.18))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k)); p.addCurve(to: CGPoint(x: r.maxX - k, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - k * 0.18), control2: CGPoint(x: r.maxX - k * 0.18, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY)); p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - k), control1: CGPoint(x: r.minX + k * 0.18, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - k * 0.18))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + k)); p.addCurve(to: CGPoint(x: r.minX + k, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + k * 0.18), control2: CGPoint(x: r.minX + k * 0.18, y: r.minY))
    p.closeSubpath(); return p
}

// Body: Apple grid (824px squircle centred, with a soft drop shadow)
let body = CGRect(x: 100, y: 92, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: c(0x000000, 0.35))
ctx.addPath(squircle(body, 185)); ctx.setFillColor(c(0x1B1F4B)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(squircle(body, 185)); ctx.clip()
// Mesh gradient: base + glowing blobs
ctx.setFillColor(c(0x141A4D)); ctx.fill(body)
for (x, y, r, hex) in [(0.12, 0.15, 0.85, 0x6D5BFF), (0.92, 0.2, 0.7, 0x00C2FF), (0.85, 1.0, 0.8, 0xFF5FA2), (0.2, 0.95, 0.6, 0x2E47FF)] as [(CGFloat, CGFloat, CGFloat, UInt32)] {
    let ctr = CGPoint(x: body.minX + x * body.width, y: body.minY + y * body.height)
    let g = CGGradient(colorsSpace: cs, colors: [c(hex, 1), c(hex, 0.55), c(hex, 0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(g, startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: r * body.width, options: [])
}
ctx.restoreGState()

// Floating window card
let card = CGRect(x: 214, y: 268, width: 596, height: 420)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 48, color: c(0x05061A, 0.55))
ctx.addPath(CGPath(roundedRect: card, cornerWidth: 46, cornerHeight: 46, transform: nil)); ctx.setFillColor(c(0xFFFFFF, 0.96)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(CGPath(roundedRect: card, cornerWidth: 46, cornerHeight: 46, transform: nil)); ctx.clip()
ctx.setFillColor(c(0xEEF0F7)); ctx.fill(CGRect(x: card.minX, y: card.minY, width: card.width, height: 74))
ctx.restoreGState()
for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
    ctx.setFillColor(c(UInt32(hex))); ctx.fillEllipse(in: CGRect(x: card.minX + 38 + CGFloat(i) * 40, y: card.minY + 24, width: 26, height: 26))
}
// Content bars
ctx.setFillColor(c(0x5B5BF6, 0.9)); ctx.addPath(CGPath(roundedRect: CGRect(x: card.minX + 44, y: card.minY + 116, width: 230, height: 34), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
for (i, w) in [420.0, 360.0, 300.0].enumerated() {
    ctx.setFillColor(c(0xC9CBE0)); ctx.addPath(CGPath(roundedRect: CGRect(x: card.minX + 44, y: card.minY + 184 + CGFloat(i) * 56, width: CGFloat(w), height: 24), cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
}

// Click ripple + cursor
let tip = CGPoint(x: 640, y: 560)
for (r, a, w) in [(118.0, 0.35, 10.0), (78.0, 0.85, 12.0)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.setStrokeColor(c(0x3B82F6, a)); ctx.setLineWidth(w)
    ctx.strokeEllipse(in: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2))
}
let k: CGFloat = 13.5
let pts: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15.6), CGPoint(x: 3.8, y: 12.1), CGPoint(x: 6.35, y: 17.9),
                      CGPoint(x: 8.75, y: 16.85), CGPoint(x: 6.25, y: 11.15), CGPoint(x: 11.3, y: 11.15)].map { CGPoint(x: tip.x + $0.x * k, y: tip.y + $0.y * k) }
let arrow = CGMutablePath(); arrow.addLines(between: pts); arrow.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0x000000, 0.45))
ctx.addPath(arrow); ctx.setLineJoin(.round); ctx.setLineWidth(2.4 * k); ctx.setStrokeColor(c(0xFFFFFF)); ctx.strokePath()
ctx.restoreGState()
ctx.addPath(arrow); ctx.setFillColor(c(0x0B0B0F)); ctx.fillPath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
