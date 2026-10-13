import Foundation
import CoreGraphics

public enum PrettyError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self { case .message(let m): return m }
    }
}

public func fail(_ msg: String) -> PrettyError { .message(msg) }

/// Logging goes to stderr so stdout stays machine-readable JSON for agents.
public enum Log {
    public static var quiet = false
    public static func info(_ s: String) {
        guard !quiet else { return }
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
    public static func warn(_ s: String) {
        FileHandle.standardError.write(("warning: " + s + "\n").data(using: .utf8)!)
    }
}

// MARK: - Colors

public struct RGBA: Equatable {
    public var r, g, b, a: CGFloat
    public init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public func with(alpha: CGFloat) -> RGBA { RGBA(r, g, b, alpha) }
    public var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    public func mixed(_ o: RGBA, _ t: CGFloat) -> RGBA {
        RGBA(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
    }

    public static let named: [String: String] = [
        "blue": "#3B82F6", "white": "#FFFFFF", "black": "#000000", "red": "#EF4444", "orange": "#F97316",
        "yellow": "#FACC15", "green": "#22C55E", "teal": "#14B8A6", "cyan": "#06B6D4", "purple": "#A855F7",
        "pink": "#EC4899", "gray": "#8E8E93", "grey": "#8E8E93", "indigo": "#6366F1", "clear": "#00000000",
    ]

    /// Parses "#RGB", "#RRGGBB", "#RRGGBBAA", named colors, "brand:N", and "rgba(r,g,b,a)".
    public static func parse(_ s: String, brand: [String] = []) -> RGBA? {
        var str = s.trimmingCharacters(in: .whitespaces).lowercased()
        if str.hasPrefix("brand:"), let i = Int(str.dropFirst(6)), i >= 0, i < brand.count {
            return parse(brand[i])
        }
        if str == "brand", let first = brand.first { return parse(first) }
        if let n = named[str] { str = n.lowercased() }
        if str.hasPrefix("rgba(") || str.hasPrefix("rgb(") {
            let inner = str.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3 else { return nil }
            return RGBA(parts[0] / 255, parts[1] / 255, parts[2] / 255, parts.count > 3 ? parts[3] : 1)
        }
        guard str.hasPrefix("#") else { return nil }
        var hex = String(str.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return RGBA(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255, 1)
        }
        return RGBA(CGFloat((v >> 24) & 0xFF) / 255, CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }

    public static func hex(_ s: String) -> RGBA { parse(s) ?? RGBA(1, 0, 1) }
}

// MARK: - Math

@inline(__always) public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
@inline(__always) public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) public func smoothstep(_ t: Double) -> Double { let x = clamp(t, 0, 1); return x * x * (3 - 2 * x) }
/// Minimum-jerk profile (bell-shaped velocity), the way a hand moves a mouse.
@inline(__always) public func smootherstep(_ t: Double) -> Double { let x = clamp(t, 0, 1); return x * x * x * (x * (x * 6 - 15) + 10) }
@inline(__always) public func easeOutCubic(_ t: Double) -> Double { let x = 1 - clamp(t, 0, 1); return 1 - x * x * x }
@inline(__always) public func easeInOutCubic(_ t: Double) -> Double {
    let x = clamp(t, 0, 1); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}
@inline(__always) public func easeOutBack(_ t: Double, _ s: Double = 1.4) -> Double {
    let x = clamp(t, 0, 1) - 1; return 1 + (s + 1) * x * x * x + s * x * x
}

extension CGRect {
    public var center: CGPoint { CGPoint(x: midX, y: midY) }
    public func flippedY(in height: CGFloat) -> CGRect { CGRect(x: minX, y: height - maxY, width: width, height: height) }
}

public func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
    let s = min(rect.width / size.width, rect.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

/// Parses "16:9" style ratios. Returns nil for "auto".
public func parseAspect(_ s: String) -> Double? {
    let parts = s.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
    return parts[0] / parts[1]
}

@inline(__always) public func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

public func formatTime(_ t: Double) -> String {
    let m = Int(t) / 60, s = t - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}

// MARK: - JSON helpers

public func prettyJSON<T: Encodable>(_ v: T) throws -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try enc.encode(v)
}

public func printJSON(_ obj: Any) {
    print(jsonString(obj))
}

/// Deterministic JSON text with sorted keys and shortest round-trip number formatting
/// (JSONSerialization prints 0.93 as 0.93000000000000005).
public func jsonString(_ obj: Any, indent: String = "") -> String {
    let inner = indent + "  "
    switch obj {
    case let d as [String: Any]:
        if d.isEmpty { return "{}" }
        let body = d.keys.sorted().map { "\(inner)\(jsonString($0)): \(jsonString(d[$0]!, indent: inner))" }
        return "{\n" + body.joined(separator: ",\n") + "\n\(indent)}"
    case let a as [Any]:
        if a.isEmpty { return "[]" }
        if a.allSatisfy({ $0 is NSNumber && !($0 is Bool) }) && a.count <= 6 {
            return "[" + a.map { jsonString($0) }.joined(separator: ", ") + "]"
        }
        return "[\n" + a.map { inner + jsonString($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
    case let s as String:
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        let d = n.doubleValue
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    case is NSNull: return "null"
    default:
        let m = Mirror(reflecting: obj)
        if m.displayStyle == .optional {
            if let c = m.children.first { return jsonString(c.value, indent: indent) }
            return "null"
        }
        return jsonString("\(obj)")
    }
}

public func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
