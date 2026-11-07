import Foundation
import CoreGraphics
import AppKit

/// Pull a product's identity — name, promise, colors, icon, font — from its website, its Xcode
/// project, its web project, or an icon image, so every video is dressed in the product itself.
public enum BrandKit {
    public struct Result {
        public var brand: BrandSpec
        public var sources: [String]
        public var notes: [String]
    }

    public static func extract(_ target: String, into dir: URL) throws -> Result {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if target.hasPrefix("http://") || target.hasPrefix("https://") || (target.contains(".") && !target.contains("/") && !FileManager.default.fileExists(atPath: target)) {
            let u = URL(string: target.hasPrefix("http") ? target : "https://\(target)")!
            return try fromWebsite(u, into: dir)
        }
        let u = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { throw fail("not found: \(target)") }
        if !isDir.boolValue { return try fromImage(u, into: dir) }
        return try fromFolder(u, into: dir)
    }

    // MARK: Website

    static let ua = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]

    static func fromWebsite(_ url: URL, into dir: URL) throws -> Result {
        let r = try HTTP.request(url, headers: ua, timeout: 30)
        guard r.ok else { throw fail("couldn't load \(url.absoluteString) (\(r.status))") }
        let html = r.text
        var b = BrandSpec()
        var sources = [url.absoluteString], notes: [String] = []
        func meta(_ names: [String]) -> String? {
            for n in names {
                for pat in ["<meta[^>]+(?:name|property)=[\"']\(n)[\"'][^>]*content=[\"']([^\"']+)[\"']",
                            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*(?:name|property)=[\"']\(n)[\"']"] {
                    if let m = firstMatch(pat, html) { return decodeEntities(m) }
                }
            }
            return nil
        }
        b.name = meta(["og:site_name", "application-name", "apple-mobile-web-app-title"])
            ?? firstMatch("<title[^>]*>([^<]+)</title>", html).map { decodeEntities($0).components(separatedBy: CharacterSet(charactersIn: "|–—-:")).first!.trimmingCharacters(in: .whitespaces) }
        b.tagline = meta(["og:description", "description", "twitter:description"]).map { shortTagline($0) }
        b.url = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        var colors: [String] = []
        if let tc = meta(["theme-color"]), let c = RGBA.parse(tc), !isNeutral(c) { colors.append(hex(c)) }

        // Web app manifest.
        var iconCandidates: [(URL, Int)] = []
        if let mh = firstMatch("<link[^>]+rel=[\"']manifest[\"'][^>]*href=[\"']([^\"']+)[\"']", html) ?? firstMatch("<link[^>]+href=[\"']([^\"']+)[\"'][^>]*rel=[\"']manifest[\"']", html),
           let mu = URL(string: mh, relativeTo: url), let mr = try? HTTP.request(mu.absoluteURL, headers: ua, timeout: 20), mr.ok, let mj = mr.json() {
            sources.append(mu.absoluteString)
            if b.name == nil { b.name = (mj["name"] as? String) ?? (mj["short_name"] as? String) }
            if let tc = mj["theme_color"] as? String, let c = RGBA.parse(tc), !isNeutral(c) { colors.append(hex(c)) }
            for ic in (mj["icons"] as? [[String: Any]]) ?? [] {
                if let src = ic["src"] as? String, let iu = URL(string: src, relativeTo: mu) {
                    let size = Int(((ic["sizes"] as? String) ?? "0").split(separator: "x").first ?? "0") ?? 0
                    iconCandidates.append((iu.absoluteURL, size))
                }
            }
        }
        // <link rel=apple-touch-icon / icon>
        for m in allMatches("<link[^>]+>", html) {
            guard let rel = firstMatch("rel=[\"']([^\"']+)[\"']", m), rel.contains("icon"), let href = firstMatch("href=[\"']([^\"']+)[\"']", m),
                  let iu = URL(string: href, relativeTo: url) else { continue }
            var size = Int((firstMatch("sizes=[\"'](\\d+)x", m)) ?? "") ?? (rel.contains("apple") ? 180 : 32)
            if href.hasSuffix(".svg") || href.hasSuffix(".ico") { size = min(size, 16) }
            iconCandidates.append((iu.absoluteURL, size))
        }
        if let og = meta(["og:image"]), let ou = URL(string: og, relativeTo: url) { b.logo = ou.absoluteString }

        // Stylesheets: brand custom properties and the most used saturated colors.
        var css = allMatches("<style[^>]*>([\\s\\S]*?)</style>", html, group: 1).joined(separator: "\n")
        for href in allMatches("<link[^>]+rel=[\"']stylesheet[\"'][^>]*href=[\"']([^\"']+)[\"']", html, group: 1).prefix(4) {
            if let su = URL(string: href, relativeTo: url), let sr = try? HTTP.request(su.absoluteURL, headers: ua, timeout: 20), sr.ok {
                css += "\n" + sr.text; sources.append(su.absoluteString)
            }
        }
        let siteColors = cssColors(css)
        b.font = cssFont(css)

        // Icon: biggest raster.
        for (iu, _) in iconCandidates.sorted(by: { $0.1 > $1.1 }) where !iu.path.hasSuffix(".svg") {
            let ext = iu.pathExtension.isEmpty ? "png" : iu.pathExtension
            let dst = dir.appendingPathComponent("icon.\(ext)")
            if (try? HTTP.download(iu, to: dst, headers: ua)) != nil, loadCGImage(dst) != nil {
                b.icon = dst.lastPathComponent
                // The icon's own color is the most reliable brand color.
                if let cg = loadCGImage(dst) { colors += dominantColors(cg) }
                break
            }
        }
        colors += siteColors
        if b.icon == nil { notes.append("no raster icon found on the site — pass the app icon PNG: pretty brand icon.png") }
        b.colors = dedupe(colors)
        if b.colors.isEmpty { notes.append("no brand colors found — set brand.colors by hand") }
        return Result(brand: b, sources: sources, notes: notes)
    }

    // MARK: Folders (Xcode or web projects)

    static func fromFolder(_ root: URL, into dir: URL) throws -> Result {
        var b = BrandSpec()
        var sources: [String] = [], notes: [String] = []
        let fm = FileManager.default
        var colors: [String] = []
        var bestIcon: (URL, Int)? = nil
        var cssText = ""
        let skip: Set<String> = ["node_modules", ".git", "build", "DerivedData", ".build", "Pods", "dist", ".next", "vendor"]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { throw fail("can't read \(root.path)") }
        var scanned = 0
        for case let u as URL in e {
            if skip.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            scanned += 1
            if scanned > 60000 { break }
            let name = u.lastPathComponent
            if name.hasSuffix(".xcodeproj"), b.name == nil { b.name = String(name.dropLast(10)); sources.append(u.path) }
            if name == "AppIcon.appiconset" {
                for f in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "png" {
                    if let cg = loadCGImage(f), cg.width > (bestIcon?.1 ?? 0) { bestIcon = (f, cg.width) }
                }
                sources.append(u.path)
            }
            if name == "AccentColor.colorset" || (name.hasSuffix(".colorset") && name.lowercased().contains("brand")) {
                if let c = colorsetColor(u.appendingPathComponent("Contents.json")) { colors.insert(hex(c), at: 0); sources.append(u.path) }
            }
            if name == "package.json", b.name == nil, let d = try? Data(contentsOf: u), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                if let n = j["productName"] as? String ?? j["displayName"] as? String { b.name = n }
            }
            let low = name.lowercased()
            if ["png", "jpg", "jpeg"].contains(u.pathExtension.lowercased()), low.contains("icon") || low.contains("apple-touch"),
               !low.contains("favicon"), let cg = loadCGImage(u), cg.width >= 120, abs(cg.width - cg.height) < 4, cg.width > (bestIcon?.1 ?? 0) {
                bestIcon = (u, cg.width)
            }
            if ["css", "scss"].contains(u.pathExtension), cssText.count < 600_000, let t = try? String(contentsOf: u, encoding: .utf8) { cssText += "\n" + t }
            if name == "tailwind.config.js" || name == "tailwind.config.ts", let t = try? String(contentsOf: u, encoding: .utf8) { cssText += "\n" + t }
            if name == "Info.plist", let d = NSDictionary(contentsOf: u), let n = d["CFBundleDisplayName"] as? String, !n.contains("$") { b.name = n }
        }
        if b.font == nil { b.font = cssFont(cssText) }
        if let (iu, _) = bestIcon {
            let dst = dir.appendingPathComponent("icon.\(iu.pathExtension)")
            try? fm.removeItem(at: dst); try fm.copyItem(at: iu, to: dst)
            b.icon = dst.lastPathComponent
            sources.append(iu.path)
            if let cg = loadCGImage(iu) { colors += dominantColors(cg) }
        } else { notes.append("no app icon found — pass one: pretty brand icon.png") }
        colors += cssColors(cssText)
        // Logos (transparent wordmarks / 3D marks) nearby.
        if let logo = findLogo(root) {
            let dst = dir.appendingPathComponent("logo.\(logo.pathExtension)")
            try? fm.removeItem(at: dst); try? fm.copyItem(at: logo, to: dst)
            b.logo = dst.lastPathComponent
        }
        if b.name == nil { b.name = root.lastPathComponent.capitalized }
        b.colors = dedupe(colors)
        return Result(brand: b, sources: sources, notes: notes)
    }

    static func findLogo(_ root: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var best: (URL, Int)? = nil
        var n = 0
        for case let u as URL in e {
            if ["node_modules", ".git", "build", "DerivedData", ".build", "Pods", "dist"].contains(u.lastPathComponent) { e.skipDescendants(); continue }
            n += 1; if n > 40000 { break }
            let low = u.lastPathComponent.lowercased()
            guard u.pathExtension.lowercased() == "png", low.contains("logo") || low.contains("3d") || low.contains("glass") else { continue }
            if let cg = loadCGImage(u), cg.alphaInfo != .none, cg.alphaInfo != .noneSkipLast, cg.alphaInfo != .noneSkipFirst {
                let score = cg.width + (low.contains("3d") ? 4000 : 0) + (low.contains("white") ? -500 : 0)
                if score > (best?.1 ?? 0) { best = (u, score) }
            }
        }
        return best?.0
    }

    static func fromImage(_ u: URL, into dir: URL) throws -> Result {
        guard let cg = loadCGImage(u) else { throw fail("not an image: \(u.path)") }
        var b = BrandSpec()
        let dst = dir.appendingPathComponent("icon.\(u.pathExtension)")
        if dst.path != u.path { try? FileManager.default.removeItem(at: dst); try FileManager.default.copyItem(at: u, to: dst) }
        b.icon = dst.lastPathComponent
        b.colors = dedupe(dominantColors(cg))
        return Result(brand: b, sources: [u.path], notes: ["set brand.name, tagline and cta by hand (images carry no text)"])
    }

    // MARK: Color & type helpers

    static func colorsetColor(_ u: URL) -> RGBA? {
        guard let d = try? Data(contentsOf: u), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let cs = j["colors"] as? [[String: Any]], let first = cs.first(where: { ($0["appearances"] == nil) }) ?? cs.first,
              let comps = (first["color"] as? [String: Any])?["components"] as? [String: Any] else { return nil }
        func v(_ k: String) -> CGFloat? {
            guard let s = comps[k] as? String else { return (comps[k] as? Double).map { CGFloat($0) } }
            if s.hasPrefix("0x") { return CGFloat(Int(s.dropFirst(2), radix: 16) ?? 0) / 255 }
            let x = Double(s) ?? 0
            return CGFloat(x > 1 ? x / 255 : x)
        }
        guard let r = v("red"), let g = v("green"), let b = v("blue") else { return nil }
        return RGBA(r, g, b)
    }

    static func cssColors(_ css: String) -> [String] {
        guard !css.isEmpty else { return [] }
        var out: [String] = []
        // Named brand variables first.
        for m in allMatches("--[\\w-]*(?:brand|primary|accent|main|theme)[\\w-]*\\s*:\\s*(#[0-9a-fA-F]{3,8})\\b", css, group: 1) {
            if let c = RGBA.parse(m), !isNeutral(c) { out.append(hex(c)) }
        }
        // Then the most frequent saturated colors.
        var counts: [String: Int] = [:]
        for m in allMatches("#[0-9a-fA-F]{6}\\b", css) {
            if let c = RGBA.parse(m), !isNeutral(c) { counts[hex(c), default: 0] += 1 }
        }
        out += counts.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        return out
    }

    static func cssFont(_ css: String) -> String? {
        let generic: Set<String> = ["system-ui", "-apple-system", "blinkmacsystemfont", "sans-serif", "serif", "monospace", "inherit", "initial",
                                    "ui-sans-serif", "ui-serif", "ui-monospace", "helvetica", "arial", "segoe ui", "roboto", "var", "sf pro", "sf pro display", "sf pro text",
                                    "helvetica neue", "arial black", "verdana", "tahoma", "trebuchet ms", "times new roman", "times", "georgia",
                                    "courier new", "courier", "menlo", "monaco", "impact", "comic sans ms", "lucida grande", "apple color emoji", "noto sans"]
        let installed = Set(NSFontManager.shared.availableFontFamilies.map { $0.lowercased() })
        for decl in allMatches("font-family\\s*:\\s*([^;}]+)", css, group: 1) {
            for fam in decl.split(separator: ",") {
                let f = fam.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
                if f.isEmpty || generic.contains(f) || f.hasPrefix("var(") || f.hasPrefix("__") { continue }
                if installed.contains(f) { return fam.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            }
        }
        return nil
    }

    static func isNeutral(_ c: RGBA) -> Bool {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let sat = mx == 0 ? 0 : (mx - mn) / mx
        return sat < 0.22 || mx < 0.12 || (mn > 0.92)
    }

    /// The two or three most present saturated hues in an image.
    public static func dominantColors(_ cg: CGImage) -> [String] {
        let n = 48
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return [] }
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var buckets: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
        for i in 0..<(n * n) {
            let a = CGFloat(px[i * 4 + 3]) / 255
            guard a > 0.6 else { continue }
            let c = RGBA(CGFloat(px[i * 4]) / 255 / a, CGFloat(px[i * 4 + 1]) / 255 / a, CGFloat(px[i * 4 + 2]) / 255 / a)
            if isNeutral(c) { continue }
            let h = Int(hue(c) * 18) // 20° buckets
            var bk = buckets[h] ?? (0, 0, 0, 0)
            bk.count += 1; bk.r += c.r; bk.g += c.g; bk.b += c.b
            buckets[h] = bk
        }
        let total = buckets.values.map(\.count).reduce(0, +)
        return buckets.values.sorted { $0.count > $1.count }.filter { Double($0.count) > Double(total) * 0.06 }.prefix(3).map {
            hex(RGBA($0.r / CGFloat($0.count), $0.g / CGFloat($0.count), $0.b / CGFloat($0.count)))
        }
    }

    static func hue(_ c: RGBA) -> CGFloat {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 0 else { return 0 }
        var h: CGFloat
        if mx == c.r { h = (c.g - c.b) / d } else if mx == c.g { h = 2 + (c.b - c.r) / d } else { h = 4 + (c.r - c.g) / d }
        h /= 6
        return h < 0 ? h + 1 : min(h, 0.9999)
    }

    static func hex(_ c: RGBA) -> String {
        String(format: "#%02X%02X%02X", Int((clamp(c.r, 0, 1) * 255).rounded()), Int((clamp(c.g, 0, 1) * 255).rounded()), Int((clamp(c.b, 0, 1) * 255).rounded()))
    }

    /// Drop near-duplicates (same hue family and lightness).
    static func dedupe(_ cs: [String]) -> [String] {
        var out: [RGBA] = []
        for s in cs {
            guard let c = RGBA.parse(s) else { continue }
            if out.contains(where: { abs($0.r - c.r) + abs($0.g - c.g) + abs($0.b - c.b) < 0.3 }) { continue }
            out.append(c)
        }
        return out.prefix(4).map(hex)
    }

    static func shortTagline(_ s: String) -> String {
        let t = decodeEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = t.firstIndex(where: { ".!?".contains($0) }), t.distance(from: t.startIndex, to: end) > 12 { return String(t[...end]) }
        return String(t.prefix(90))
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
        return Range(r, in: s).map { String(s[$0]) }
    }

    static func allMatches(_ pattern: String, _ s: String, group: Int = 0) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: min(group, m.numberOfRanges - 1)), in: s).map { String(s[$0]) }
        }
    }
}
