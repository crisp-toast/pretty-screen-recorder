import Foundation

/// Reading/writing projects, creating bundles, dotted-path edits, and "looks".
public enum ProjectIO {
    public static let bundleExtension = "prettystudio"

    public static func loadJSON(_ url: URL) throws -> [String: Any] {
        let (pu, _) = Studio.locate(url)
        let data = try Data(contentsOf: pu)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw fail("project.json is not an object") }
        return obj
    }

    public static func saveJSON(_ obj: [String: Any], to url: URL) throws {
        let (pu, _) = Studio.locate(url)
        // Validate before writing: decoding must succeed.
        let data = Data((jsonString(obj) + "\n").utf8)
        do { _ = try JSONDecoder().decode(Project.self, from: data) } catch { throw fail("edit makes project invalid: \(describe(error))") }
        try data.write(to: pu, options: .atomic)
    }

    public static func load(_ url: URL) throws -> Project {
        let (pu, _) = Studio.locate(url)
        do { return try JSONDecoder().decode(Project.self, from: Data(contentsOf: pu)) }
        catch let e as PrettyError { throw e }
        catch { throw fail("cannot read \(pu.path): \(describe(error))") }
    }

    public static func save(_ p: Project, to url: URL) throws {
        let (pu, _) = Studio.locate(url)
        try prettyJSON(p).write(to: pu, options: .atomic)
    }

    // MARK: Dotted paths: "cursor.size", "zoom.segments[0].level", "overlays[+]" (append)

    enum Token { case key(String); case index(Int); case append }

    static func tokens(_ path: String) throws -> [Token] {
        var out: [Token] = []
        for part in path.split(separator: ".") {
            var s = Substring(part)
            if let b = s.firstIndex(of: "[") {
                let key = s[..<b]
                if !key.isEmpty { out.append(.key(String(key))) }
                s = s[b...]
                while s.hasPrefix("[") {
                    guard let e = s.firstIndex(of: "]") else { throw fail("bad path \(path)") }
                    let inner = s[s.index(after: s.startIndex)..<e]
                    if inner == "+" { out.append(.append) }
                    else if let i = Int(inner) { out.append(.index(i)) }
                    else { throw fail("bad index in \(path)") }
                    s = s[s.index(after: e)...]
                }
            } else { out.append(.key(String(s))) }
        }
        return out
    }

    public static func setValue(_ root: inout [String: Any], path: String, value: Any?) throws {
        let toks = try tokens(path)
        func assign(_ node: Any?, _ rest: ArraySlice<Token>) throws -> Any? {
            guard let t = rest.first else { return value }
            let tail = rest.dropFirst()
            switch t {
            case .key(let k):
                var d = (node as? [String: Any]) ?? [:]
                let v = try assign(d[k], tail)
                if v == nil { d.removeValue(forKey: k) } else { d[k] = v }
                return d
            case .index(let i):
                var a = (node as? [Any]) ?? []
                let idx = i < 0 ? a.count + i : i
                guard idx >= 0 && idx < a.count else { throw fail("index \(i) out of range in \(path) (count \(a.count))") }
                if tail.isEmpty && value == nil { a.remove(at: idx) } else { a[idx] = try assign(a[idx], tail) as Any }
                return a
            case .append:
                var a = (node as? [Any]) ?? []
                a.append(try assign(nil, tail) as Any)
                return a
            }
        }
        guard let r = try assign(root, toks[...]) as? [String: Any] else { throw fail("bad path \(path)") }
        root = r
    }

    public static func getValue(_ root: Any, path: String) throws -> Any? {
        var node: Any? = root
        for t in try tokens(path) {
            switch t {
            case .key(let k): node = (node as? [String: Any])?[k]
            case .index(let i):
                guard let a = node as? [Any] else { return nil }
                let idx = i < 0 ? a.count + i : i
                node = idx >= 0 && idx < a.count ? a[idx] : nil
            case .append: return nil
            }
        }
        return node
    }

    /// Parse a CLI value: JSON if it parses (numbers, bools, null, objects, arrays, "quoted"), else a bare string.
    public static func parseValue(_ s: String) -> Any? {
        if s == "null" { return nil }
        if let d = s.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) { return v }
        return s
    }

    // MARK: Looks (one-word styles that set several fields)

    public struct Look { public let name: String; public let summary: String; public let apply: (inout Project) -> Void }

    public static let looks: [Look] = [
        Look(name: "aurora", summary: "Deep blue/violet mesh gradient, soft shadow (default)") { p in
            p.background = BackgroundSpec(); p.background.preset = "aurora"; p.frame.theme = "dark"; p.layout.shadow = 0.6 },
        Look(name: "clean", summary: "Bright cloud-white backdrop, light chrome — docs, landing pages") { p in
            p.background.type = "gradient"; p.background.preset = "cloud"; p.frame.theme = "light"; p.layout.shadow = 0.4; p.layout.padding = 0.07 },
        Look(name: "sky", summary: "Soft blue sky gradient — friendly product demos") { p in
            p.background.type = "gradient"; p.background.preset = "sky"; p.frame.theme = "light"; p.layout.shadow = 0.5 },
        Look(name: "dusk", summary: "Blue-to-pink pastel (CleanShot-like)") { p in
            p.background.type = "gradient"; p.background.preset = "dusk"; p.frame.theme = "light"; p.layout.shadow = 0.5 },
        Look(name: "midnight", summary: "Near-black navy with purple glow, dark chrome — dev tools, night mode") { p in
            p.background.type = "gradient"; p.background.preset = "midnight"; p.frame.theme = "dark"; p.layout.shadow = 0.7 },
        Look(name: "sunset", summary: "Warm orange/pink — energetic social ads") { p in
            p.background.type = "gradient"; p.background.preset = "sunset"; p.frame.theme = "light"; p.layout.shadow = 0.55 },
        Look(name: "pastel", summary: "Lavender pastel — calm, premium") { p in
            p.background.type = "gradient"; p.background.preset = "lavender"; p.frame.theme = "light"; p.layout.shadow = 0.45 },
        Look(name: "mint", summary: "Fresh mint/teal") { p in
            p.background.type = "gradient"; p.background.preset = "mint"; p.frame.theme = "light"; p.layout.shadow = 0.45 },
        Look(name: "graphite", summary: "Neutral dark graphite — serious B2B") { p in
            p.background.type = "gradient"; p.background.preset = "graphite"; p.frame.theme = "dark"; p.layout.shadow = 0.7 },
        Look(name: "minimal", summary: "Flat off-white, tight padding — documentation") { p in
            p.background.type = "color"; p.background.color = "#F4F4F6"; p.frame.theme = "light"; p.layout.shadow = 0.3; p.layout.padding = 0.05 },
        Look(name: "glass", summary: "Blurred copy of the recording as the backdrop") { p in
            p.background.type = "blur"; p.layout.shadow = 0.6 },
        Look(name: "brand", summary: "Gradient from brand.colors") { p in
            if p.brand.colors.count >= 2 { p.background.type = "gradient"; p.background.colors = p.brand.colors }
            else if let c = p.brand.colors.first { p.background.type = "color"; p.background.color = c } },
    ]

    public static func look(_ name: String) -> Look? { looks.first { $0.name == name.lowercased() } }

    // MARK: Creating bundles

    public struct NewOptions {
        public var video: URL?
        public var events: URL?
        public var camera: URL?
        public var kind: String?
        public var name: String?
        public var look: String?
        public var preset: String?
        public var url: String?
        public var duration: Double?
        public var copySources = true
        public var compressIdle = false
        public var autoZoom = true
        public var brand: BrandSpec?
        public init() {}
    }

    /// Create a `.prettystudio` bundle. Returns the bundle URL.
    @discardableResult
    public static func create(at bundle: URL, _ o: NewOptions) throws -> URL {
        let fm = FileManager.default
        var b = bundle
        if b.pathExtension != bundleExtension { b = b.appendingPathExtension(bundleExtension) }
        if fm.fileExists(atPath: b.appendingPathComponent("project.json").path) {
            throw fail("\(b.path) already exists (pick another name or delete it)")
        }
        let sources = b.appendingPathComponent("sources")
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try fm.createDirectory(at: b.appendingPathComponent("renders"), withIntermediateDirectories: true)

        var p = Project()
        p.name = o.name ?? b.deletingPathExtension().lastPathComponent
        func bring(_ src: URL, as name: String) throws -> String {
            let dst = sources.appendingPathComponent(name)
            if src.standardizedFileURL.path == dst.standardizedFileURL.path { return "sources/\(name)" }
            try? fm.removeItem(at: dst)
            if o.copySources { try fm.copyItem(at: src, to: dst) } // APFS clones: instant, no extra space
            else { try fm.createSymbolicLink(at: dst, withDestinationURL: src) }
            return "sources/\(name)"
        }
        if let v = o.video {
            guard fm.fileExists(atPath: v.path) else { throw fail("video not found: \(v.path)") }
            p.source.video = try bring(v, as: "screen." + (v.pathExtension.isEmpty ? "mov" : v.pathExtension.lowercased()))
        } else {
            p.source.kind = "card"
            p.duration = o.duration ?? 3
        }
        if let e = o.events { p.source.events = try bring(e, as: "events.json") }
        if let c = o.camera { p.source.camera = try bring(c, as: "camera." + c.pathExtension.lowercased()) }
        if let k = o.kind { p.source.kind = k }
        if let u = o.url { p.source.url = u }
        if let br = o.brand { p.brand = br }
        if let pr = o.preset { p.export.preset = pr }

        // Sensible per-kind defaults.
        var events = InputEvents()
        if let e = p.source.events { events = (try? InputEvents.load(b.appendingPathComponent(e))) ?? InputEvents() }
        if events.pointScale > 0 { p.source.pointScale = events.pointScale }
        switch p.source.kind {
        case "ios", "mobile-web", "android":
            p.cursor.style = "touch"; p.cursor.ripple.enabled = false; p.layout.padding = 0.06; p.layout.shadow = 0.5
            if p.source.kind == "ios" { p.source.pointScale = 3 }
        case "card":
            p.cursor.show = false
        default: break
        }
        if let l = o.look { guard let look = look(l) else { throw fail("unknown look '\(l)'. Run `pretty looks`.") }; look.apply(&p) }
        try save(p, to: b)

        // Smart zooms / idle compression need the derived data.
        if o.video != nil && (o.autoZoom || o.compressIdle) {
            try autoEdit(bundle: b, zooms: o.autoZoom, idle: o.compressIdle)
        }
        return b
    }

    /// Regenerate automatic zooms and/or idle compression. Manual edits are preserved.
    public static func autoEdit(bundle: URL, zooms: Bool, idle: Bool) throws {
        var p = try load(bundle)
        let studio = try Studio(url: bundle)
        if idle, let v = studio.videoURL {
            p.timeline.idle.compress = true
            let fr = Media.freezes(v)
            let r = AutoEdit.idleRanges(events: studio.events, duration: studio.sourceDuration, freezes: fr, spec: p.timeline.idle,
                                        trimStart: p.timeline.trimStart, trimEnd: p.timeline.trimEnd)
            p.timeline.cuts = p.timeline.cuts.filter { !$0.auto } + r.cuts
            p.timeline.speed = p.timeline.speed.filter { !$0.auto } + r.speed
        }
        if zooms {
            let auto = AutoEdit.smartZooms(events: studio.events, duration: studio.sourceDuration, level: p.zoom.level,
                                           mode: p.zoom.mode, kind: p.source.kind)
            let manual = p.zoom.segments.filter { !$0.auto }
            // Drop auto zooms that collide with manual ones.
            let keep = auto.filter { a in !manual.contains { $0.start < a.end && a.start < $0.end } }
            p.zoom.segments = (manual + keep).sorted { $0.start < $1.start }
        }
        try save(p, to: bundle)
    }
}
