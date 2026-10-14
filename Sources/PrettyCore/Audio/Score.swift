import Foundation
import CryptoKit

/// An original score and sound design for each video, made with ElevenLabs (the same key as the
/// narrator). The music follows the edit section by section — a quiet hook, a build through the
/// demo, a lift at the reveal, a warm resolve on the end card — so it moves with the picture
/// instead of sounding like stock music laid underneath.
public enum Score {
    public struct Section: Codable {
        public var name: String
        public var start: Double
        public var duration: Double
        /// intro | build | lift | resolve
        public var role: String
    }

    static var base: URL { HTTP.base("PRETTY_ELEVENLABS_BASE", "https://api.elevenlabs.io") }

    public static var available: Bool { Secrets.get("elevenlabs") != nil }

    static func key() throws -> String {
        guard let k = Secrets.get("elevenlabs") else {
            throw fail("composed scores and sound design use ElevenLabs — add the key in Pretty Studio → Settings → Voice (or `pretty keys set elevenlabs`)")
        }
        return k
    }

    static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    static func roleStyles(_ role: String) -> [String] {
        switch role {
        case "intro": return ["sparse intro", "a single memorable motif", "atmospheric", "no drums yet"]
        case "build": return ["steady pulse", "light modern drums enter", "forward momentum", "building anticipation"]
        case "lift": return ["fuller arrangement", "emotional lift", "wide and bright", "confident peak"]
        default: return ["warm resolve", "sustained final chord", "gentle ending that rings out", "no abrupt stop"]
        }
    }

    /// Compose (or reuse) a score for these sections. Returns the file and a human description.
    public static func compose(sections raw: [Section], treatment: Treatment, bpm: Double, mood: String?, seed: Int, to dir: URL) throws -> (URL, String) {
        let k = try key()
        // Chunks must be 3-120 s: fold short sections into their neighbours.
        var sections: [Section] = []
        for s in raw where s.duration > 0.05 {
            if var last = sections.last, last.duration < 3.0 || s.duration < 3.0 {
                last.duration += s.duration
                if s.role == "resolve" || s.role == "lift" { last.role = s.role; last.name = s.name }
                sections[sections.count - 1] = last
            } else { sections.append(s) }
        }
        if let last = sections.last, last.duration < 3.0, sections.count > 1 {
            sections[sections.count - 2].duration += last.duration
            sections[sections.count - 2].role = last.role
            sections.removeLast()
        }
        guard !sections.isEmpty else { throw fail("nothing to score") }
        var global = treatment.musicStyles + ["instrumental", "about \(Int(bpm.rounded())) BPM", "steady tempo throughout"]
        if let m = mood, !m.isEmpty { global.append(m) }
        let negatives = treatment.musicAvoid + ["vocals", "singing", "lyrics", "humming", "choir", "spoken words", "vinyl crackle", "lo-fi hiss"]
        let chunks: [[String: Any]] = sections.map { s in
            ["text": "[\(s.name.capitalized)]", "duration_ms": Int((max(3.0, min(120, s.duration)) * 1000).rounded()),
             "positive_styles": global + roleStyles(s.role), "negative_styles": negatives]
        }
        let body: [String: Any] = ["model_id": "music_v2_5", "composition_plan": ["chunks": chunks], "seed": seed]
        let cacheKey = hash([(try? String(data: JSONSerialization.data(withJSONObject: body, options: .sortedKeys), encoding: .utf8)) ?? "", base.absoluteString])
        let cacheDir = Paths.cache.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent("\(cacheKey).mp3")
        let desc = "Original score (ElevenLabs Music, \(treatment.name)): " + sections.map { "\($0.name) \(String(format: "%.1f", $0.duration))s" }.joined(separator: " → ")
        if !FileManager.default.fileExists(atPath: cached.path) {
            Log.info("composing an original score (\(sections.count) sections, \(String(format: "%.1f", sections.map(\.duration).reduce(0, +)))s) with ElevenLabs Music…")
            var r = try HTTP.json(base.appendingPathComponent("v1/music"), headers: ["xi-api-key": k], body: body, timeout: 300)
            if !r.ok && (r.status == 400 || r.status == 422) {
                // Fall back to a described prompt (instrumental guaranteed).
                let arc = sections.map { "\($0.name) (\(String(format: "%.0f", $0.duration))s): \(roleStyles($0.role).joined(separator: ", "))" }.joined(separator: "; ")
                let prompt = "Instrumental score for a premium product video. \(global.joined(separator: ", ")). Structure: \(arc). Avoid: \(negatives.joined(separator: ", "))."
                let total = Int(sections.map(\.duration).reduce(0, +) * 1000)
                r = try HTTP.json(base.appendingPathComponent("v1/music"), headers: ["xi-api-key": k],
                                  body: ["model_id": "music_v2_5", "prompt": String(prompt.prefix(4000)), "music_length_ms": total, "force_instrumental": true], timeout: 300)
            }
            if r.status == 402 && r.errorMessage.lowercased().contains("free") { rememberTier("free") }
            guard r.ok, !r.data.isEmpty else { throw fail("ElevenLabs Music (\(r.status)): \(r.errorMessage)\(r.status == 401 || r.status == 403 ? " — the key may need the Music permission" : "")") }
            try r.data.write(to: cached)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("score.mp3")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: cached, to: dst)
        return (dst, desc)
    }

    public static func license() -> MusicLicense {
        MusicLicense(name: "Original score (ElevenLabs Music)", credit: nil, requiresCredit: false, source: "composed",
                     notes: "Composed for this video. Paid ElevenLabs plans cover commercial use including ads and social; film, TV, radio and large games need Enterprise. Free-plan output is non-commercial.")
    }

    // MARK: Sound design

    static func sfxPrompt(_ kind: String, _ t: Treatment) -> (String, Double) {
        let character = t.sfx
        switch kind {
        case "whoosh": return ("Short clean transition whoosh for a premium product video, \(character), smooth air movement, no music, no voice", 0.9)
        case "impact": return ("Soft deep cinematic impact with a short warm tail, premium and clean, \(character), no music, no voice", 1.8)
        case "shimmer": return ("Subtle glassy light shimmer, a quick sparkle sweep across glass, delicate and clean, no music", 1.1)
        case "riser": return ("Short tension riser swelling smoothly into a hit, clean and modern, \(character), no music", 1.6)
        default: return ("Very soft, subtle UI tap click on glass, minimal and clean, no music", 0.5)
        }
    }

    /// A cached sound effect for this treatment.
    public static func sfx(_ kind: String, treatment: Treatment) throws -> URL {
        let (text, dur) = sfxPrompt(kind, treatment)
        let cacheDir = Paths.cache.appendingPathComponent("sfx")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let f = cacheDir.appendingPathComponent("\(kind)-\(hash([text, String(dur), base.absoluteString])).mp3")
        if FileManager.default.fileExists(atPath: f.path) { return f }
        let k = try key()
        let r = try HTTP.json(base.appendingPathComponent("v1/sound-generation"), headers: ["xi-api-key": k],
                              body: ["text": text, "duration_seconds": dur, "prompt_influence": 0.55], timeout: 120)
        guard r.ok, !r.data.isEmpty else { throw fail("ElevenLabs sound effects (\(r.status)): \(r.errorMessage)") }
        try r.data.write(to: f)
        return f
    }

    // MARK: Account

    /// The ElevenLabs plan tier ("free", "starter", "creator", ...), cached for an hour. nil when
    /// unknown (no key, or the key can't read the subscription).
    static func rememberTier(_ t: String) {
        try? JSONSerialization.data(withJSONObject: ["tier": t, "inferred": true]).write(to: Paths.cache.appendingPathComponent("elevenlabs-tier.json"))
    }

    public static func tier() -> String? {
        guard let k = Secrets.get("elevenlabs") else { return nil }
        let f = Paths.cache.appendingPathComponent("elevenlabs-tier.json")
        // A tier inferred from an API refusal holds for a day (restricted keys can't read the subscription).
        if let a = try? FileManager.default.attributesOfItem(atPath: f.path), let m = a[.modificationDate] as? Date,
           let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           (j["inferred"] as? Bool) == true, Date().timeIntervalSince(m) < 86400, let t = j["tier"] as? String { return t }
        if let a = try? FileManager.default.attributesOfItem(atPath: f.path), let m = a[.modificationDate] as? Date, Date().timeIntervalSince(m) < 3600,
           let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let t = j["tier"] as? String {
            return t
        }
        guard let r = try? HTTP.request(base.appendingPathComponent("v1/user/subscription"), headers: ["xi-api-key": k], timeout: 15) else { return nil }
        guard r.ok, let j = r.json(), let t = j["tier"] as? String else {
            if ProcessInfo.processInfo.environment["PRETTY_DEBUG"] != nil { Log.warn("subscription lookup: \(r.status) \(r.errorMessage)") }
            return nil
        }
        try? JSONSerialization.data(withJSONObject: ["tier": t]).write(to: f)
        return t
    }

    /// What the plan tier means for publishing.
    public static func tierNote() -> String? {
        guard let t = tier() else { return nil }
        if t == "free" {
            return "ElevenLabs free plan: voice and sound effects are for non-commercial use and need \"elevenlabs.io\" credit, and composed scores aren't available. Starter (about $5/month) adds commercial rights and the Music API."
        }
        return nil
    }
}
