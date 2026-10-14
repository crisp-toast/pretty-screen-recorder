import Foundation
import CryptoKit

/// Studio-grade narration. Two providers, both neural and expressive:
/// - ElevenLabs (default model `eleven_v4`): character-level timestamps → exact word timings.
/// - OpenAI `gpt-4o-mini-tts` (voices marin / cedar recommended): word timings recovered with
///   whisper-1 word timestamps.
/// There is deliberately no on-device fallback. With no provider configured, directed videos
/// carry their story with on-screen type instead of a robotic voice.
public enum Narrator {
    public struct Speech: Codable {
        public var file: String
        public var duration: Double
        public var words: [WordTime]
        public var voice: String
        public var provider: String
        /// The line as shown on screen (audio tags like [excited] removed).
        public var text: String
    }

    public struct VoiceInfo: Codable {
        public var id: String
        public var name: String
        public var provider: String
        public var category: String?
        public var description: String?
        public var labels: [String: String]
        public var previewURL: String?
    }

    public struct Resolved {
        public var provider: String
        public var voiceId: String
        public var voiceName: String
        public var model: String
        public var key: String
        public var stability: Double
        public var similarity: Double
        public var style: Double
        public var speed: Double
        public var instructions: String?
        public init(provider: String, voiceId: String, voiceName: String, model: String, key: String, stability: Double = 0.45,
                    similarity: Double = 0.8, style: Double = 0.25, speed: Double = 1, instructions: String? = nil) {
            self.provider = provider; self.voiceId = voiceId; self.voiceName = voiceName; self.model = model; self.key = key
            self.stability = stability; self.similarity = similarity; self.style = style; self.speed = speed; self.instructions = instructions
        }
    }

    public static let providers = ["elevenlabs", "openai"]
    public static let defaultModel = ["elevenlabs": "eleven_v4", "openai": "gpt-4o-mini-tts"]
    public static let openAIVoices: [(String, String)] = [
        ("marin", "Natural, warm, conversational — recommended"), ("cedar", "Grounded, rich, assured — recommended"),
        ("coral", "Bright and friendly"), ("sage", "Calm, even, thoughtful"), ("ash", "Clear, confident"),
        ("ballad", "Soft, expressive"), ("verse", "Lively, versatile"), ("nova", "Upbeat, youthful"),
        ("shimmer", "Light, gentle"), ("alloy", "Neutral, balanced"), ("echo", "Steady, resonant"),
        ("fable", "Storyteller"), ("onyx", "Deep, authoritative"),
    ]
    // Overridable for tests against a local mock (PRETTY_ELEVENLABS_BASE / PRETTY_OPENAI_BASE).
    static var elevenBase: URL { HTTP.base("PRETTY_ELEVENLABS_BASE", "https://api.elevenlabs.io") }
    static var openAIBase: URL { HTTP.base("PRETTY_OPENAI_BASE", "https://api.openai.com") }

    /// The narration voice for a project/storyboard, merged with the user's setup. nil = no narration.
    public static func resolve(_ spec: VoiceSpec?, settings: AppSettings = .load()) -> Resolved? {
        let s = settings.voice
        let provider = spec?.provider ?? s.provider
        guard providers.contains(provider), let key = Secrets.get(provider) else { return nil }
        var voiceId = spec?.voice ?? (provider == s.provider ? s.voiceId : nil)
        var voiceName = spec?.voice ?? s.voiceName ?? voiceId ?? ""
        if provider == "openai" {
            voiceId = (voiceId ?? "marin").lowercased(); voiceName = voiceId!
        } else if let v = voiceId, !looksLikeElevenID(v) {
            // A name ("Brian") → id, from the account's voice list.
            if let match = (try? voices(provider: "elevenlabs", key: key, cachedOK: true))?.first(where: { $0.name.lowercased().hasPrefix(v.lowercased()) }) {
                voiceId = match.id; voiceName = match.name
            } else { return nil }
        }
        guard let vid = voiceId else { return nil }
        let model = spec?.model ?? (provider == s.provider ? s.model : nil) ?? defaultModel[provider]!
        return Resolved(provider: provider, voiceId: vid, voiceName: voiceName.isEmpty ? vid : voiceName, model: model, key: key,
                        stability: spec?.stability ?? s.stability, similarity: s.similarity, style: spec?.style ?? s.style,
                        speed: spec?.speed ?? s.speed, instructions: spec?.instructions ?? s.instructions)
    }

    public static func isAvailable(_ spec: VoiceSpec? = nil) -> Bool { resolve(spec) != nil }

    /// Why narration isn't available, for agents.
    public static func unavailableReason(_ spec: VoiceSpec? = nil) -> String {
        let s = AppSettings.load().voice
        let provider = spec?.provider ?? s.provider
        if !providers.contains(provider) { return "no narration voice is set up — open Pretty Studio → Settings → Voice (or `pretty keys set elevenlabs`), or let on-screen type carry the story" }
        if Secrets.get(provider) == nil { return "no \(provider) API key — add one in Pretty Studio → Settings → Voice, or `pretty keys set \(provider)`" }
        return "no \(provider) voice chosen — pick one in Pretty Studio → Settings → Voice, or set audio.voice.voice"
    }

    static func looksLikeElevenID(_ s: String) -> Bool { s.count >= 18 && s.allSatisfy { $0.isLetter || $0.isNumber } && s.contains(where: \.isNumber) }

    // MARK: Synthesis

    /// Render `text` next to `url` (the extension is chosen by the provider). Cached by content.
    public static func synthesize(_ text: String, spec: VoiceSpec?, to url: URL) throws -> Speech {
        guard let r = resolve(spec) else { throw fail(unavailableReason(spec)) }
        return try synthesize(text, voice: r, to: url)
    }

    public static func synthesize(_ text: String, voice r: Resolved, to url: URL) throws -> Speech {
        let display = displayText(text)
        let key = cacheKey(text, r)
        let dir = Paths.cache.appendingPathComponent("voice")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = dir.appendingPathComponent("\(key).json")
        var speech: Speech
        if let d = try? Data(contentsOf: meta), let s = try? JSONDecoder().decode(Speech.self, from: d), FileManager.default.fileExists(atPath: s.file) {
            speech = s
        } else {
            switch r.provider {
            case "elevenlabs": speech = try elevenTTS(text, r, base: dir.appendingPathComponent(key))
            default: speech = try openAITTS(text, r, base: dir.appendingPathComponent(key))
            }
            speech.text = display
            try prettyJSON(speech).write(to: meta)
        }
        let dst = url.deletingPathExtension().appendingPathExtension(URL(fileURLWithPath: speech.file).pathExtension)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: speech.file), to: dst)
        speech.file = dst.path
        return speech
    }

    static func cacheKey(_ text: String, _ r: Resolved) -> String {
        let parts = [r.provider, r.model, r.voiceId, String(r.stability), String(r.similarity), String(r.style), String(r.speed), r.instructions ?? "", text, r.provider == "openai" ? openAIBase.absoluteString : elevenBase.absoluteString, "v1"]
        let h = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return h.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    /// Audio tags ([excited], [whispers]) steer ElevenLabs delivery but never appear on screen.
    public static func displayText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: ElevenLabs

    static func elevenTTS(_ text: String, _ r: Resolved, base: URL) throws -> Speech {
        var comps = URLComponents(url: elevenBase.appendingPathComponent("v1/text-to-speech/\(r.voiceId)/with-timestamps"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var body: [String: Any] = ["text": text, "model_id": r.model]
        body["voice_settings"] = ["stability": r.stability, "similarity_boost": r.similarity, "style": r.style,
                                  "use_speaker_boost": true, "speed": clamp(r.speed, 0.7, 1.2)]
        var resp = try HTTP.json(comps.url!, headers: ["xi-api-key": r.key, "Accept": "application/json"], body: body, timeout: 120)
        if !resp.ok && (resp.status == 400 || resp.status == 422) && resp.errorMessage.lowercased().contains("setting") {
            body["voice_settings"] = nil // some models take only their own presets
            resp = try HTTP.json(comps.url!, headers: ["xi-api-key": r.key, "Accept": "application/json"], body: body, timeout: 120)
        }
        guard resp.ok else { throw fail("ElevenLabs (\(resp.status)): \(resp.errorMessage)") }
        guard let j = resp.json(), let b64 = j["audio_base64"] as? String, let audio = Data(base64Encoded: b64) else {
            throw fail("ElevenLabs returned no audio")
        }
        let file = base.appendingPathExtension("mp3")
        try audio.write(to: file)
        let duration = (try? AssetInfo.load(file).duration) ?? 0
        var words: [WordTime] = []
        if let al = (j["alignment"] as? [String: Any]) ?? (j["normalized_alignment"] as? [String: Any]),
           let chars = al["characters"] as? [String], let starts = al["character_start_times_seconds"] as? [Double] {
            words = wordsFromCharacters(chars, starts, display: displayText(text))
        }
        if words.isEmpty { words = Voice.estimateWords(displayText(text), duration: duration) }
        return Speech(file: file.path, duration: round3(duration), words: words, voice: r.voiceName, provider: "elevenlabs", text: displayText(text))
    }

    /// Character timestamps → one start time per displayed word (audio tags skipped).
    static func wordsFromCharacters(_ chars: [String], _ starts: [Double], display: String) -> [WordTime] {
        var tokens: [(String, Double)] = []
        var cur = "", curStart = 0.0, depth = 0
        func flush() { if !cur.isEmpty { tokens.append((cur, curStart)) }; cur = "" }
        for (i, c) in chars.enumerated() where i < starts.count {
            if c == "[" { depth += 1; flush(); continue }
            if c == "]" { depth = max(0, depth - 1); continue }
            if depth > 0 { continue }
            if c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flush(); continue }
            if cur.isEmpty { curStart = starts[i] }
            cur += c
        }
        flush()
        let shown = display.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        if shown.count == tokens.count {
            return zip(shown, tokens).map { WordTime(w: $0, t: round3($1.1)) }
        }
        return tokens.map { WordTime(w: $0.0, t: round3($0.1)) }
    }

    // MARK: OpenAI

    static func openAITTS(_ text: String, _ r: Resolved, base: URL) throws -> Speech {
        let display = displayText(text)
        var body: [String: Any] = ["model": r.model, "voice": r.voiceId, "input": display, "response_format": "wav"]
        if r.model.contains("gpt-4o") {
            body["instructions"] = r.instructions ?? "Warm, confident product narrator. Natural pace, smile in the voice, crisp consonants. Not salesy."
        } else if abs(r.speed - 1) > 0.01 {
            body["speed"] = r.speed
        }
        let resp = try HTTP.json(openAIBase.appendingPathComponent("v1/audio/speech"), headers: ["Authorization": "Bearer \(r.key)"], body: body, timeout: 120)
        guard resp.ok, !resp.data.isEmpty else { throw fail("OpenAI speech (\(resp.status)): \(resp.errorMessage)") }
        let file = base.appendingPathExtension("wav")
        try resp.data.write(to: file)
        // OpenAI streams WAV with a placeholder length; rewrite it with a proper header.
        let fixed = base.appendingPathExtension("fixed.wav")
        if (try? Media.ffmpegRun(["-i", file.path, "-c:a", "pcm_s16le", fixed.path])) != nil {
            try? FileManager.default.removeItem(at: file); try? FileManager.default.moveItem(at: fixed, to: file)
        }
        let duration = (try? AssetInfo.load(file).duration) ?? 0
        var words = (try? whisperWords(file, key: r.key)).map { align(display, recognized: $0, duration: duration) } ?? []
        if words.isEmpty { words = Voice.estimateWords(display, duration: duration) }
        return Speech(file: file.path, duration: round3(duration), words: words, voice: r.voiceName, provider: "openai", text: display)
    }

    static func whisperWords(_ file: URL, key: String) throws -> [(String, Double)] {
        let resp = try HTTP.multipart(openAIBase.appendingPathComponent("v1/audio/transcriptions"), headers: ["Authorization": "Bearer \(key)"],
                                      fields: [("model", "whisper-1"), ("response_format", "verbose_json"), ("timestamp_granularities[]", "word")],
                                      file: (name: "file", filename: file.lastPathComponent, mime: "audio/wav", data: try Data(contentsOf: file)))
        guard resp.ok, let j = resp.json(), let ws = j["words"] as? [[String: Any]] else { throw fail("transcription failed (\(resp.status))") }
        return ws.compactMap { w in (w["word"] as? String).flatMap { s in (w["start"] as? Double).map { (s, $0) } } }
    }

    /// Map recognized words (with times) onto the script's words; unmatched words are interpolated.
    static func align(_ text: String, recognized: [(String, Double)], duration: Double) -> [WordTime] {
        let shown = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !shown.isEmpty, !recognized.isEmpty else { return [] }
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var times = [Double?](repeating: nil, count: shown.count)
        var j = 0
        for (i, w) in shown.enumerated() {
            let n = norm(w)
            guard !n.isEmpty else { continue }
            for k in j..<min(recognized.count, j + 4) {
                let r = norm(recognized[k].0)
                if r == n || (n.count >= 4 && (r.hasPrefix(n) || n.hasPrefix(r)) && !r.isEmpty) {
                    times[i] = recognized[k].1; j = k + 1; break
                }
            }
        }
        if times.compactMap({ $0 }).count < max(1, shown.count / 3) { return [] }
        var out: [WordTime] = []
        for i in shown.indices {
            var t = times[i]
            if t == nil {
                let prev = (0..<i).reversed().first { times[$0] != nil }.map { (idx: $0, t: times[$0]!) } ?? (idx: -1, t: 0)
                let next = ((i + 1)..<shown.count).first { times[$0] != nil }.map { (idx: $0, t: times[$0]!) } ?? (idx: shown.count, t: duration * 0.95)
                t = prev.t + (next.t - prev.t) * Double(i - prev.idx) / Double(max(1, next.idx - prev.idx))
            }
            out.append(WordTime(w: shown[i], t: round3(max(t!, out.last?.t ?? 0))))
        }
        return out
    }

    // MARK: Accounts

    /// Voices available to this key. ElevenLabs: the account's voices (premade + library); OpenAI: built-in voices.
    public static func voices(provider: String, key: String? = nil, cachedOK: Bool = false) throws -> [VoiceInfo] {
        if provider == "openai" {
            return openAIVoices.map { VoiceInfo(id: $0.0, name: $0.0.capitalized, provider: "openai", category: "built-in", description: $0.1, labels: [:], previewURL: nil) }
        }
        guard provider == "elevenlabs" else { throw fail("unknown voice provider '\(provider)' (elevenlabs | openai)") }
        let cacheFile = Paths.cache.appendingPathComponent("voices-elevenlabs.json")
        if cachedOK, let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) < 86400,
           let d = try? Data(contentsOf: cacheFile), let v = try? JSONDecoder().decode([VoiceInfo].self, from: d) { return v }
        guard let k = key ?? Secrets.get("elevenlabs") else { throw fail("no ElevenLabs API key") }
        var all: [VoiceInfo] = []
        var token: String? = nil
        for _ in 0..<5 {
            var comps = URLComponents(url: elevenBase.appendingPathComponent("v2/voices"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "page_size", value: "100")] + (token.map { [URLQueryItem(name: "next_page_token", value: $0)] } ?? [])
            let r = try HTTP.request(comps.url!, headers: ["xi-api-key": k])
            guard r.ok, let j = r.json(), let vs = j["voices"] as? [[String: Any]] else { throw fail("ElevenLabs voices (\(r.status)): \(r.errorMessage)") }
            for v in vs {
                guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { continue }
                var labels: [String: String] = [:]
                for (lk, lv) in (v["labels"] as? [String: Any]) ?? [:] { if let s = lv as? String { labels[lk] = s } }
                all.append(VoiceInfo(id: id, name: name, provider: "elevenlabs", category: v["category"] as? String,
                                     description: v["description"] as? String, labels: labels, previewURL: v["preview_url"] as? String))
            }
            token = j["next_page_token"] as? String
            if (j["has_more"] as? Bool) != true || token == nil { break }
        }
        try? prettyJSON(all).write(to: cacheFile)
        return all
    }

    /// Text-to-speech models this key can use (ElevenLabs), best first.
    public static func models(provider: String, key: String? = nil) -> [String] {
        guard provider == "elevenlabs", let k = key ?? Secrets.get("elevenlabs"),
              let r = try? HTTP.request(elevenBase.appendingPathComponent("v1/models"), headers: ["xi-api-key": k]), r.ok,
              let arr = (try? JSONSerialization.jsonObject(with: r.data)) as? [[String: Any]] else {
            return provider == "openai" ? ["gpt-4o-mini-tts"] : ["eleven_v4", "eleven_multilingual_v2"]
        }
        let ids = arr.filter { ($0["can_do_text_to_speech"] as? Bool) ?? true }.compactMap { $0["model_id"] as? String }
        let rank = ["eleven_v4", "eleven_v3", "eleven_multilingual_v2", "eleven_flash_v2_5", "eleven_turbo_v2_5"]
        return ids.sorted { (rank.firstIndex(of: $0) ?? 99) < (rank.firstIndex(of: $1) ?? 99) }
    }

    /// Check a key without spending credits. Returns a short description of what works.
    /// Errors say exactly why (invalid vs. restricted key), with the key's shape but never the key.
    public static func test(provider: String, key raw: String) throws -> String {
        let key = Secrets.sanitize(raw)
        let shape = Secrets.shape(key)
        switch provider {
        case "elevenlabs":
            if key.hasPrefix("sk-") { throw fail("That looks like an OpenAI key (it starts with \u{201C}sk-\u{201D}). ElevenLabs keys start with \u{201C}sk_\u{201D}.") }
            var comps = URLComponents(url: elevenBase.appendingPathComponent("v2/voices"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "page_size", value: "1")]
            let r = try HTTP.request(comps.url!, headers: ["xi-api-key": key], timeout: 20)
            if r.ok { return "ElevenLabs key works" }
            let detail = r.json()?["detail"] as? [String: Any]
            let status = (detail?["status"] as? String) ?? (detail?["code"] as? String) ?? ""
            let msg = r.errorMessage
            if status.contains("permission") || msg.lowercased().contains("permission") {
                throw fail("This ElevenLabs key is restricted — \(msg) In ElevenLabs → Developers → API Keys, edit the key and allow Text to Speech (Access), Voices (Read) and Models (Read), or create a key without restrictions.")
            }
            if r.status == 401 || status == "invalid_api_key" {
                var hint = "Copy the whole key from ElevenLabs → Developers → API Keys (it's shown only once, when the key is created — if you can't see it, create a new one)."
                if !key.hasPrefix("sk_") { hint = "ElevenLabs keys start with \u{201C}sk_\u{201D}. " + hint }
                throw fail("ElevenLabs says the key is invalid (\(msg)). Checked a \(shape). \(hint)")
            }
            throw fail("ElevenLabs (\(r.status)): \(msg)")
        case "openai":
            let r = try HTTP.request(openAIBase.appendingPathComponent("v1/models/gpt-4o-mini-tts"), headers: ["Authorization": "Bearer \(key)"], timeout: 20)
            if r.ok { return "OpenAI key works (gpt-4o-mini-tts)" }
            if r.status == 401 { throw fail("OpenAI says the key is invalid (\(r.errorMessage)). Checked a \(shape).") }
            if r.status == 403 || r.status == 404 { throw fail("This OpenAI key can't use gpt-4o-mini-tts (\(r.errorMessage)). Check the key's project permissions (Models: Read, Audio: Write).") }
            throw fail("OpenAI (\(r.status)): \(r.errorMessage)")
        default: throw fail("unknown provider '\(provider)' (elevenlabs | openai)")
        }
    }

    /// Pick a sensible default ElevenLabs voice: a premade narrator/advertising voice.
    public static func suggestedVoice(_ vs: [VoiceInfo]) -> VoiceInfo? {
        let wanted = ["narrat", "advert", "social", "conversational", "informative"]
        return vs.first { v in v.category == "premade" && wanted.contains { w in (v.labels["use_case"] ?? v.labels["use case"] ?? "").lowercased().contains(w) } }
            ?? vs.first { $0.category == "premade" } ?? vs.first
    }
}
