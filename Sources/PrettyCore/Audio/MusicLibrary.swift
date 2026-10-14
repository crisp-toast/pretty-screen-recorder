import Foundation

/// Real music, used legally.
///
/// - **Kevin MacLeod / incompetech.com** — ~1,400 widely recognized tracks ("Carefree", "Wallpaper",
///   "Life of Riley", "Inspired"...) under Creative Commons Attribution 4.0: commercial use and
///   sync are allowed when the credit is published. Pretty Studio writes the exact credit line.
/// - **Your licensed library** — downloads from a subscription you hold (Epidemic Sound, Artlist,
///   Musicbed, Soundstripe...). Put them in the licensed folder; a `<file>.license.json` sidecar
///   (or a folder named after the service) records the license.
/// - **Generated** — Pretty Studio's procedural beds. Always legal, never famous; used only when
///   asked or when nothing real fits.
///
/// Chart songs (major-label recordings) are not available: attribution doesn't license them —
/// that takes sync + master licenses from the publisher and label.
public enum MusicLibrary {
    public struct Track: Codable {
        public var id: String
        public var title: String
        public var artist: String
        public var source: String
        public var file: String?
        public var url: String?
        public var bpm: Double?
        public var duration: Double?
        public var feel: [String]
        public var genre: String?
        public var instruments: String?
        public var description: String?
        public var famous: Bool
        public var license: MusicLicense
        public var score: Double? = nil
    }

    public struct Query {
        public var mood: String? = nil
        public var feel: [String] = []
        public var bpm: ClosedRange<Double>? = nil
        public var minDuration: Double? = nil
        public var text: String? = nil
        public var famousOnly = false
        public var source: String? = nil
        public var exclude: [String] = []
        public init() {}

        public init(json d: [String: Any]) {
            mood = d["mood"] as? String
            feel = (d["feel"] as? [String]) ?? ((d["feel"] as? String).map { [$0] } ?? [])
            if let b = d["bpm"] as? [Double], b.count == 2 { bpm = min(b[0], b[1])...max(b[0], b[1]) }
            else if let b = d["bpm"] as? Double { bpm = (b - 8)...(b + 8) }
            minDuration = d["minDuration"] as? Double
            text = d["text"] as? String ?? d["query"] as? String
            famousOnly = d["famous"] as? Bool ?? false
            source = d["source"] as? String
            exclude = d["exclude"] as? [String] ?? []
        }
    }

    // MARK: Moods

    /// Mood → incompetech "feel" tags wanted / avoided.
    public static let moods: [String: (want: [String], avoid: [String], bpm: ClosedRange<Double>?)] = [
        "upbeat": (["Bright", "Uplifting", "Bouncy", "Grooving", "Driving"], ["Dark", "Eerie", "Unnerving", "Somber", "Humorous", "Suspenseful"], 96...132),
        "confident": (["Grooving", "Driving", "Bright", "Uplifting"], ["Humorous", "Eerie", "Somber", "Unnerving"], 95...128),
        "corporate": (["Bright", "Uplifting", "Calming", "Relaxed"], ["Dark", "Eerie", "Humorous", "Aggressive", "Unnerving"], 85...125),
        "chill": (["Relaxed", "Calming", "Grooving"], ["Aggressive", "Intense", "Dark", "Humorous", "Action"], 70...105),
        "playful": (["Humorous", "Bouncy", "Bright"], ["Dark", "Somber", "Eerie", "Aggressive"], nil),
        "cinematic": (["Epic", "Intense", "Uplifting", "Driving"], ["Humorous", "Bouncy"], nil),
        "dramatic": (["Intense", "Dark", "Suspenseful", "Driving"], ["Humorous", "Bouncy"], nil),
        "minimal": (["Calming", "Relaxed"], ["Aggressive", "Intense", "Humorous", "Action"], nil),
    ]

    /// Tracks most people have heard (YouTube, podcasts, streams) — preferred when they fit.
    static let famousTitles: Set<String> = [
        "Monkeys Spinning Monkeys", "Sneaky Snitch", "Fluffing a Duck", "Carefree", "Wallpaper", "Inspired", "Life of Riley",
        "Happy Alley", "Funkorama", "Cipher", "Cheery Monday", "Werq", "Vibe Ace", "Hyperfun", "Easy Lemon",
        "Local Forecast - Elevator", "Investigations", "Pixel Peeker Polka - faster", "Hitman", "Merry Go", "Kool Kats",
        "Wholesome", "Breaktime", "Daily Beetle", "Bright Wish", "Gonna Start", "Spazzmatica Polka", "Cut and Run", "Run Amok",
        "Quirky Dog", "Blip Stream", "Bit Quest", "Vivacity", "Fig Leaf Times Two", "Gaslamp Funworks", "Dreamer",
        "Airport Lounge", "Bossa Antigua", "Overcast", "Heroic Age", "Five Armies", "Impact Moderato", "Sovereign", "Ether Vox",
        "Volatile Reaction", "Ouroboros", "Rollin at 5", "The Lift", "Hep Cats", "Funky Chunk", "Hustle", "Electrodoodle",
        "Lobby Time", "Mining by Moonlight", "Pamgaea", "Basic Implosion", "Ice Flow", "Slow Burn",
    ]

    static let genres = ["2": "World", "3": "Blues", "4": "Classical", "5": "Contemporary", "6": "Disco", "7": "Electronica",
                         "8": "Funk", "9": "Holiday", "10": "Horror", "11": "Jazz", "12": "Latin", "13": "Ambient", "15": "Polka",
                         "16": "Pop", "18": "Reggae", "19": "Rock", "20": "Silent Film", "21": "Ska", "22": "Soundtrack",
                         "23": "Stings", "24": "Unclassifiable", "25": "World", "26": "Hip Hop"]

    // MARK: Kevin MacLeod (incompetech.com), CC BY 4.0

    static let catalogURL = URL(string: "https://incompetech.com/music/royalty-free/pieces.json")!
    static let fileBase = "https://incompetech.com/music/royalty-free/mp3-royaltyfree/"

    public static func ccByLicense(title: String) -> MusicLicense {
        MusicLicense(name: "CC BY 4.0", url: "https://creativecommons.org/licenses/by/4.0/",
                     credit: "\"\(title)\" Kevin MacLeod (incompetech.com)\nLicensed under Creative Commons: By Attribution 4.0 License\nhttp://creativecommons.org/licenses/by/4.0/",
                     requiresCredit: true, source: "incompetech",
                     notes: "Publish the credit with the video (description or on screen). YouTube Content ID may flag it; the credit and license resolve claims. Commercial use and sync are allowed.")
    }

    public static func incompetech(refresh: Bool = false) throws -> [Track] {
        let cache = Paths.cache.appendingPathComponent("incompetech-pieces.json")
        var fresh = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cache.path), let m = attrs[.modificationDate] as? Date {
            fresh = Date().timeIntervalSince(m) < 30 * 86400
        }
        if refresh || !fresh {
            do { try HTTP.download(catalogURL, to: cache, timeout: 60) }
            catch { if !FileManager.default.fileExists(atPath: cache.path) { throw error } }
        }
        guard let arr = (try? JSONSerialization.jsonObject(with: Data(contentsOf: cache))) as? [[String: Any]] else {
            throw fail("incompetech catalog unreadable")
        }
        let local = Paths.musicLibrary.appendingPathComponent("incompetech")
        return arr.compactMap { d in
            guard let title = d["title"] as? String, let filename = d["filename"] as? String else { return nil }
            let feel = ((d["feel"] as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let f = local.appendingPathComponent(filename)
            return Track(id: "incompetech:\(title)", title: title, artist: "Kevin MacLeod", source: "incompetech",
                         file: FileManager.default.fileExists(atPath: f.path) ? f.path : nil,
                         url: fileBase + (filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename),
                         bpm: (d["bpm"] as? String).flatMap(Double.init) ?? (d["bpm"] as? Double),
                         duration: parseLength(d["length"] as? String), feel: feel, genre: (d["genre"] as? String).flatMap { genres[$0] },
                         instruments: d["instruments"] as? String, description: d["description"] as? String,
                         famous: famousTitles.contains(title), license: ccByLicense(title: title))
        }
    }

    static func parseLength(_ s: String?) -> Double? {
        guard let s else { return nil }
        let p = s.split(separator: ":").compactMap { Double($0) }
        return p.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: Licensed library

    static let services: [(String, String)] = [("epidemic", "Epidemic Sound"), ("artlist", "Artlist"), ("musicbed", "Musicbed"),
                                               ("soundstripe", "Soundstripe"), ("audiojungle", "AudioJungle (Envato)"),
                                               ("envato", "Envato Elements"), ("uppbeat", "Uppbeat"), ("motionarray", "Motion Array")]
    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "flac", "caf", "aac"]

    public static var licensedFolder: URL? {
        if let f = AppSettings.load().music.licensedFolder, !f.isEmpty { return URL(fileURLWithPath: (f as NSString).expandingTildeInPath) }
        let d = Paths.musicLibrary.appendingPathComponent("Licensed")
        return FileManager.default.fileExists(atPath: d.path) ? d : nil
    }

    public static func licensed() -> [Track] {
        guard let root = licensedFolder, let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Track] = []
        for case let u as URL in e where audioExts.contains(u.pathExtension.lowercased()) {
            let rel = String(u.path.dropFirst(root.path.count + 1))
            var title = u.deletingPathExtension().lastPathComponent, artist = "", bpm: Double? = nil, feel: [String] = []
            var lic: MusicLicense
            let sidecar = u.deletingPathExtension().appendingPathExtension("license.json")
            let folderLicense = u.deletingLastPathComponent().appendingPathComponent("license.json")
            if let d = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any])
                ?? ((try? JSONSerialization.jsonObject(with: Data(contentsOf: folderLicense))) as? [String: Any]) {
                title = d["title"] as? String ?? title; artist = d["artist"] as? String ?? ""
                bpm = d["bpm"] as? Double
                feel = (d["mood"] as? [String]) ?? ((d["mood"] as? String).map { [$0] } ?? [])
                lic = MusicLicense(name: d["license"] as? String ?? (d["source"] as? String).map { "\($0) license" } ?? "licensed",
                                   url: d["url"] as? String, credit: d["credit"] as? String, requiresCredit: d["credit"] != nil,
                                   source: "licensed", notes: d["notes"] as? String)
            } else if let svc = services.first(where: { rel.lowercased().contains($0.0) }) {
                lic = MusicLicense(name: "\(svc.1) subscription", credit: nil, requiresCredit: false, source: "licensed",
                                   notes: "Licensed through your \(svc.1) subscription — the account must be active when you publish, and the channel/ad account may need to be cleared with \(svc.1).")
            } else {
                lic = MusicLicense(name: "unknown", source: "licensed",
                                   notes: "No license info. Add \(sidecar.lastPathComponent) (or keep it in a folder named after the service) before publishing.")
            }
            // "Artist - Title" filenames.
            if artist.isEmpty, let r = title.range(of: " - ") { artist = String(title[..<r.lowerBound]); title = String(title[r.upperBound...]) }
            out.append(Track(id: "licensed:\(rel)", title: title, artist: artist, source: "licensed", file: u.path, url: nil,
                             bpm: bpm, duration: nil, feel: feel, genre: nil, instruments: nil, description: nil, famous: false, license: lic))
        }
        return out.sorted { $0.id < $1.id }
    }

    // MARK: Search

    public static func search(_ q: Query, limit: Int = 12) throws -> [Track] {
        let settings = AppSettings.load().music
        var pool: [Track] = []
        if q.source == nil || q.source == "licensed" { pool += licensed() }
        if (q.source == nil && settings.useIncompetech) || q.source == "incompetech" { pool += (try? incompetech()) ?? [] }
        let m = q.mood.flatMap { moods[$0.lowercased()] }
        let want = Set(q.feel + (m?.want ?? []))
        let avoid = Set(m?.avoid ?? [])
        let bpm = q.bpm ?? m?.bpm
        var scored: [Track] = []
        for var t in pool {
            if q.exclude.contains(t.id) || q.exclude.contains(t.title) { continue }
            if q.famousOnly && !t.famous { continue }
            if t.license.name == "unknown" { continue }
            if let md = q.minDuration, let d = t.duration, d < md { continue }
            if let d = t.duration, d < 25 && (q.minDuration ?? 25) > d { continue } // stingers
            var s = 0.0
            let fs = Set(t.feel)
            s += Double(fs.intersection(want).count) * 2
            s -= Double(fs.intersection(avoid).count) * 3
            if let b = bpm, let tb = t.bpm { s += b.contains(tb) ? 2 : -min(3, abs(tb - (tb < b.lowerBound ? b.lowerBound : b.upperBound)) / 10) }
            if t.famous { s += 2.5 }
            if t.source == "licensed" { s += 1.5 }
            if let text = q.text?.lowercased(), !text.isEmpty {
                let hay = "\(t.title) \(t.artist) \(t.description ?? "") \(t.instruments ?? "") \(t.genre ?? "") \(t.feel.joined(separator: " "))".lowercased()
                let terms = text.split(separator: " ").map(String.init)
                let hits = terms.filter { hay.contains($0) }.count
                if hits == 0 && q.mood == nil && want.isEmpty { continue }
                s += Double(hits) * 2
                if t.title.lowercased() == text { s += 20 }
            }
            if (t.description ?? "").lowercased().contains("voice-over") || (t.description ?? "").lowercased().contains("voiceover") { s += 0.5 }
            t.score = round3(s)
            scored.append(t)
        }
        return Array(scored.sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(limit))
    }

    /// Look up "incompetech:Carefree", "licensed:Folder/File.mp3", or a bare title.
    public static func find(_ ref: String) throws -> Track {
        let r = ref.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("licensed:") {
            guard let t = licensed().first(where: { $0.id == r }) else { throw fail("not in your licensed folder: \(r)") }
            return t
        }
        let title = r.hasPrefix("incompetech:") ? String(r.dropFirst("incompetech:".count)) : r
        let all = try incompetech()
        if let t = all.first(where: { $0.title.lowercased() == title.lowercased() }) { return t }
        if let t = all.first(where: { $0.title.lowercased().hasPrefix(title.lowercased()) }) { return t }
        throw fail("no incompetech track called '\(title)' — try `pretty music search \"\(title)\"`")
    }

    /// Make sure the track is on disk (downloads incompetech tracks into the music library).
    public static func fetch(_ t: Track) throws -> URL {
        if let f = t.file, FileManager.default.fileExists(atPath: f) { return URL(fileURLWithPath: f) }
        guard let s = t.url, let u = URL(string: s) else { throw fail("track \(t.id) has no file") }
        let dst = Paths.musicLibrary.appendingPathComponent("incompetech").appendingPathComponent(URL(fileURLWithPath: u.path).lastPathComponent)
        Log.info("downloading \"\(t.title)\" (Kevin MacLeod, CC BY 4.0)…")
        try HTTP.download(u, to: dst)
        return dst
    }

    /// A ready-to-use music spec: file on disk, tempo grid, credit, and a start offset that skips a quiet intro.
    public static func spec(for t: Track, duration: Double? = nil) throws -> MusicSpec {
        let file = try fetch(t)
        var m = MusicSpec()
        m.path = file.path; m.track = t.id; m.title = t.title; m.artist = t.artist; m.license = t.license
        if let r = try? BeatDetect.analyze(file) {
            m.bpm = r.confidence >= 0.2 ? r.bpm : t.bpm
            m.beatOffset = r.firstBeat
            if r.confidence < 0.2, let b = t.bpm { m.bpm = b }
        } else { m.bpm = t.bpm }
        m.offset = smartOffset(file, grid: m.bpm.map { BeatGrid(bpm: $0, firstBeat: m.beatOffset ?? 0) })
        return m
    }

    /// Skip a quiet or sparse intro: start on the downbeat where the track reaches its working level.
    public static func smartOffset(_ file: URL, grid: BeatGrid?) -> Double {
        let sr = 2000.0
        guard let data = try? Media.runData(Media.ffmpeg, ["-hide_banner", "-loglevel", "error", "-t", "40", "-i", file.path, "-ac", "1", "-ar", "\(Int(sr))", "-f", "f32le", "-"]) else { return 0 }
        let x: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let win = Int(sr * 0.5)
        guard x.count > win * 8 else { return 0 }
        var rms: [Double] = []
        var i = 0
        while i + win <= x.count {
            var e = 0.0
            for k in i..<(i + win) { e += Double(x[k] * x[k]) }
            rms.append(sqrt(e / Double(win))); i += win
        }
        let sorted = rms.sorted()
        let working = sorted[Int(Double(sorted.count) * 0.7)]
        guard working > 0, let first = rms.firstIndex(where: { $0 >= working * 0.55 }) else { return 0 }
        let t = Double(first) * 0.5
        guard t >= 1.5 else { return 0 } // the intro is fine as is
        guard let g = grid else { return round3(t) }
        // The bar line at or just before the lift.
        let bar = g.nextBar(atOrAfter: t) - (g.nextBar(atOrAfter: t) - t > 0.05 ? g.bar : 0)
        return round3(max(0, bar))
    }

    // MARK: Credits

    /// Credit text for a project's soundtrack (music, and voice where the provider asks for it).
    public static func credits(music: MusicSpec?, usedMusic: Bool, voiceProvider: String?, sfx: Bool = false) -> (text: String, lines: [String], onScreen: String?) {
        var lines: [String] = []
        var onScreen: String? = nil
        if usedMusic, let m = music {
            if let lic = m.license {
                if let c = lic.credit, lic.requiresCredit {
                    lines.append("Music: " + c.replacingOccurrences(of: "\n", with: " · "))
                    onScreen = "Music: \u{201C}\(m.title ?? "Untitled")\u{201D} by \(m.artist ?? "") · \(lic.name)".replacingOccurrences(of: "by  ·", with: "·")
                    if lic.source == "incompetech" { onScreen = "Music: \u{201C}\(m.title ?? "")\u{201D} Kevin MacLeod (incompetech.com) · CC BY 4.0" }
                } else if lic.source == "generated" {
                    lines.append("Music: original score generated by Pretty Studio (no attribution required)")
                } else {
                    lines.append("Music: \(m.title ?? "track")\(m.artist.map { " — \($0)" } ?? "") (\(lic.name); no credit required)")
                }
                if let n = lic.notes { lines.append("  note: \(n)") }
            } else if m.generate != nil {
                lines.append("Music: original score generated by Pretty Studio (no attribution required)")
            } else if let p = m.path {
                lines.append("Music: \(URL(fileURLWithPath: p).lastPathComponent) — license not recorded; confirm you have sync rights before publishing")
            }
        }
        if voiceProvider == "elevenlabs" || (music?.license?.source == "composed") || sfx {
            if Score.tier() == "free" {
                lines.append("Audio by ElevenLabs (elevenlabs.io) — free plan: credit required, non-commercial use only. Upgrade before publishing an ad.")
            } else if voiceProvider == "elevenlabs" {
                lines.append("Voice: ElevenLabs (covered by your paid plan's commercial license)")
            }
        } else if voiceProvider == "openai" {
            lines.append("Voice: AI-generated voice (OpenAI). OpenAI's usage policy asks you to disclose that the voice is AI-generated.")
        }
        return (lines.joined(separator: "\n"), lines, onScreen)
    }
}
