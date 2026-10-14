import Foundation

/// Directed storyboards. Each beat pairs what is SAID with what is DONE and WHY, and every
/// action is cued — to a spoken word, the start/end of the line, or the music's beat grid.
/// The plan is computed before recording (narration synthesized first, so its word timings
/// are known), the recorder executes it on the clock, and the project is assembled from it.
public enum Director {
    public struct PlannedBeat: Codable {
        public var index: Int
        public var start: Double
        public var end: Double
        public var say: String?
    }

    public struct PlannedLine: Codable {
        public var beat: Int
        public var text: String
        public var start: Double
        public var duration: Double
        /// Synthesized narration file (nil when the line is shown as on-screen text only).
        public var file: String?
        public var words: [WordTime]
        /// voice | headline | caption | none (a scene shows it)
        public var show: String? = nil
    }

    public struct PlannedAction: Codable {
        public var beat: Int
        public var index: Int
        public var kind: String
        public var target: String?
        public var why: String?
        public var cue: String
        /// When the action's effect happens (click press, typing start, scroll start), in
        /// seconds from the first recorded frame.
        public var anchor: Double
        public var duration: Double
        public var onBeat: Bool
        /// The storyboard step, verbatim (JSON), for the recorder.
        public var step: String
    }

    public struct Plan: Codable {
        public var version = 1
        public var mode: String
        public var reason: String
        public var voice: String?
        public var grid: BeatGrid?
        public var music: MusicSpec?
        public var leadIn: Double
        public var duration: Double
        public var beats: [PlannedBeat]
        public var lines: [PlannedLine]
        public var actions: [PlannedAction]
        public var warnings: [String]
        /// Informational (not problems): e.g. narration shown as captions because the mode has no voice.
        public var notes: [String]? = nil
        /// Narration voice settings from the storyboard (carried into the project).
        public var voiceSpec: VoiceSpec? = nil
        /// Full-screen kinetic type scenes (output time).
        public var scenes: [TextScene]? = nil
        /// The product's brand kit (colors, font, icon, tagline) from the storyboard.
        public var brand: BrandSpec? = nil
        /// Project background derived from the brand when the storyboard didn't choose a look.
        public var background: BackgroundSpec? = nil
        /// Credits the published video must carry (music license, AI voice disclosure).
        public var credits: [String]? = nil
        /// Room above the device for headlines (fraction of the output height), when there are any.
        public var headroom: Double? = nil
        /// Creative treatment (look, motion and sound direction) and what it set.
        public var treatment: String? = nil
        public var moves: [DeviceMove]? = nil
        public var shots: [DeviceShot]? = nil
        public var sfx: [SfxClip]? = nil
        public var frameColor: String? = nil
        public var frameTheme: String? = nil
        public var shadow: Double? = nil
        public var seed: UInt64? = nil
    }

    public struct Options {
        public var preset: String?
        /// Where synthesized narration (vo/) and generated music go.
        public var assetsDir: URL
        /// Base directory for relative paths in the storyboard (music files).
        public var baseDir: URL
        /// Earlier videos for this project (treatments and music to avoid repeating).
        public var historyURL: URL? = nil
        /// Fixed variation seed (default: derived from the storyboard name and the project's history).
        public var seed: UInt64? = nil
        /// Generate paid media (AI B-roll) while planning. Off → a placeholder backdrop, no spend.
        public var generate: Bool = true
        public init(preset: String?, assetsDir: URL, baseDir: URL, historyURL: URL? = nil) {
            self.preset = preset; self.assetsDir = assetsDir; self.baseDir = baseDir; self.historyURL = historyURL
        }
    }

    static let markerKinds: Set<String> = ["zoom", "spotlight", "highlight", "caption", "title"]
    static let pointerKinds: Set<String> = ["click", "doubleClick", "rightClick", "tap", "hover", "move", "drag", "select"]
    static let meta: Set<String> = ["why", "at", "after", "optional", "note", "hold"]

    public static func actionKind(_ step: [String: Any]) -> String {
        step.keys.filter { !meta.contains($0) }.sorted().first ?? "wait"
    }

    static func targetText(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { return (d["selector"] as? String) ?? (d["target"] as? String) }
        return nil
    }

    /// The human-readable label inside a selector ("text=New task" → "New task").
    static func label(of selector: String?) -> String? {
        guard var s = selector else { return nil }
        if s.hasPrefix("text=") { s = String(s.dropFirst(5)) }
        else if let r = s.range(of: "name=") { s = String(s[r.upperBound...]) }
        else if let r = s.range(of: ":has-text(") { s = String(s[r.upperBound...]) }
        else { return nil }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]( "))
    }

    /// Seconds the action takes after its anchor.
    static func estimate(_ kind: String, _ step: [String: Any]) -> Double {
        let v = step[kind]
        switch kind {
        case "click", "tap", "rightClick": return 0.3
        case "doubleClick": return 0.45
        case "type":
            let text = (v as? String) ?? ((v as? [String: Any])?["text"] as? String) ?? ""
            let delay = ((v as? [String: Any])?["delay"] as? Double) ?? 0.075
            return Double(text.count) * (delay + 0.01) + Double(text.filter { $0 == " " }.count) * 0.03 + 0.15
        case "press": return 0.3
        case "scroll":
            if let d = v as? [String: Any] {
                if let dur = d["duration"] as? Double { return dur + 0.15 }
                if let y = d["y"] as? Double { return clamp(abs(y) / 1000, 0.5, 2) + 0.15 }
            }
            return 1.1
        case "hover", "move": return 0.35
        case "drag": return ((v as? [String: Any])?["duration"] as? Double ?? 0.9) + 0.3
        case "wait", "pause": return (v as? Double) ?? 1
        case "goto": return 1.6
        case "waitFor": return 0.5
        case "select": return 0.4
        default: return 0.05
        }
    }

    /// Time the cursor needs before the anchor (travel + settle), used to keep actions from colliding.
    static func lead(_ kind: String, _ step: [String: Any]) -> Double {
        switch kind {
        // Worst-case pointer travel (0.95s) + settle; the recorder starts the approach this early.
        case "click", "doubleClick", "rightClick", "hover", "move", "drag", "select": return 1.1
        case "tap": return 0.35
        case "type": return targetText((step["type"] as? [String: Any])?["selector"]) != nil ? 1.55 : 0.2
        default: return 0.25
        }
    }

    // MARK: Plan

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    static func setMusic(_ sb: [String: Any], _ music: [String: Any]?) -> [String: Any] {
        var sb = sb
        var cfg = sb["audio"] as? [String: Any] ?? [:]
        cfg["music"] = music
        sb["audio"] = cfg
        return sb
    }

    /// Plan a directed storyboard. Picks a creative treatment (varying from the project's recent
    /// videos), and when the score is composed, plans twice: once to learn the edit's sections, then
    /// again on the composed track's real beat grid.
    public static func plan(storyboard sbIn: [String: Any], options o: Options) throws -> Plan {
        let history = History.load(o.historyURL)
        let name = (sbIn["name"] as? String) ?? (sbIn["url"] as? String) ?? "video"
        let seed = o.seed ?? (fnv(name) &+ UInt64(history.entries.count) &* 0x9E3779B97F4A7C15)
        let treatment = (sbIn["treatment"] as? String).flatMap(Treatment.named) ?? Treatment.pick(seed: seed, avoid: history.recentTreatments)
        var sb = sbIn
        sb["treatment"] = treatment.name
        let settings = AppSettings.load()
        let cfg = sb["audio"] as? [String: Any] ?? [:]
        let musicAny = cfg["music"]
        let explicitCompose = (musicAny as? String) == "compose" || (musicAny as? [String: Any])?["compose"] != nil
        let autoCompose = musicAny == nil && settings.music.useComposed && Score.available && MusicLibrary.licensed().isEmpty
        let probe = AudioPlan.resolve({ var a = AudioSpec(); a.mode = cfg["mode"] as? String ?? "auto"; return a }(), preset: o.preset, hasVoice: false, hasMusic: true)
        guard (explicitCompose || autoCompose) && probe.music else { return try planPass(sb, o, treatment, seed) }

        var rng = SeedRNG(seed: seed &+ 99)
        let compCfg = (musicAny as? [String: Any])?["compose"] as? [String: Any]
        let lo = treatment.bpm.lowerBound, hi = treatment.bpm.upperBound
        let bpm = (compCfg?["bpm"] as? Double) ?? (lo + (hi - lo) * rng.unit()).rounded()
        // Pass 1: the edit on a nominal grid.
        let p1 = try planPass(setMusic(sb, ["grid": ["bpm": bpm]]), o, treatment, seed)
        var sections: [Score.Section] = []
        let lastDevice = p1.beats.last { b in !(p1.scenes ?? []).contains { abs($0.start - b.start) < 0.01 } }?.index
        for (k, b) in p1.beats.enumerated() {
            let start = k == 0 ? 0 : b.start
            let end = k + 1 < p1.beats.count ? p1.beats[k + 1].start : p1.duration + 1.6
            let scene = (p1.scenes ?? []).first { abs($0.start - b.start) < 0.01 }
            let role = scene?.style == "lockup" ? "resolve" : k == 0 ? "intro" : b.index == lastDevice || (k + 2 >= p1.beats.count && scene != nil) ? "lift" : "build"
            sections.append(Score.Section(name: role == "intro" ? "intro" : role == "resolve" ? "outro" : role == "lift" ? "lift" : "verse \(k)", start: start, duration: end - start, role: role))
        }
        do {
            let (file, desc) = try Score.compose(sections: sections, treatment: treatment, bpm: bpm, mood: compCfg?["mood"] as? String ?? (sb["mood"] as? String),
                                                 seed: Int(seed % 1_000_000), to: o.assetsDir)
            let lic = (try? JSONSerialization.jsonObject(with: prettyJSON(Score.license()))) ?? [:]
            var m: [String: Any] = ["path": file.path, "license": lic, "title": "Original score", "artist": "Composed for this video (ElevenLabs Music)"]
            if let v = (musicAny as? [String: Any])?["volume"] { m["volume"] = v }
            var p2 = try planPass(setMusic(sb, m), o, treatment, seed)
            p2.notes = (p2.notes ?? []) + [desc]
            return p2
        } catch {
            var p = try planPass(setMusic(sb, settings.music.useIncompetech ? ["find": ["mood": treatment.catalogMood]] : ["auto": "none"]), o, treatment, seed)
            p.warnings.append("couldn't compose the score (\(error)) — \(settings.music.useIncompetech ? "used a catalog track instead" : "no music")")
            return p
        }
    }

    static func planPass(_ sb: [String: Any], _ o: Options, _ treatment: Treatment, _ seed: UInt64) throws -> Plan {
        var rng = SeedRNG(seed: seed)
        guard let beatsRaw = sb["beats"] as? [[String: Any]], !beatsRaw.isEmpty else {
            throw fail("storyboard has no \"beats\" (directed mode). Use \"steps\" for a plain run, or add beats with say/do.")
        }
        let cfg = sb["audio"] as? [String: Any] ?? [:]
        var audio = AudioSpec()
        audio.mode = cfg["mode"] as? String ?? "auto"
        var voice = VoiceSpec()
        if let v = cfg["voice"] as? String { voice.voice = v }
        if let v = cfg["voice"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: v),
           let vs = try? JSONDecoder().decode(VoiceSpec.self, from: d) { voice = vs }
        var warnings: [String] = []
        var notes: [String] = []
        let settings = AppSettings.load()
        let musicCfg: [String: Any]? = (cfg["music"] as? [String: Any]) ?? ((cfg["music"] as? String).map { $0 == "auto" || $0 == "none" ? ["auto": $0] : ["track": $0] })
        let musicOff = (musicCfg?["auto"] as? String) == "none"
        let genCfg = musicCfg?["generate"] as? [String: Any]
        let musicPath = (musicCfg?["path"] as? String).map { Backgrounds.resolve($0, o.baseDir) }
        let hasSay = beatsRaw.contains { !(($0["say"] as? String) ?? "").isEmpty }
        let voiceReady = Narrator.resolve(voice, settings: settings)
        let realMusicAvailable = settings.music.useIncompetech || !MusicLibrary.licensed().isEmpty
        let gridStub = musicCfg?["grid"] as? [String: Any]
        let hasMusic = !musicOff && (genCfg != nil || gridStub != nil || musicCfg?["track"] != nil || musicCfg?["find"] != nil
            || musicPath.map { FileManager.default.fileExists(atPath: $0.path) } == true
            || (musicPath == nil && (realMusicAvailable || settings.music.useGenerated)))
        let ap = AudioPlan.resolve(audio, preset: o.preset, hasVoice: hasSay && voiceReady != nil, hasMusic: hasMusic)
        if musicPath != nil && !hasMusic { warnings.append("music file not found: \(musicPath!.path)") }
        if hasSay && voiceReady == nil && ["voiceover", "both"].contains(audio.mode) {
            warnings.append("narration requested but unavailable: \(Narrator.unavailableReason(voice)). The lines will appear as on-screen type instead.")
        }

        // Brand kit.
        var brand: BrandSpec? = nil
        if let bp = sb["brand"] as? String {
            let u = Backgrounds.resolve(bp, o.baseDir)
            if let d = try? Data(contentsOf: u), var b = try? JSONDecoder().decode(BrandSpec.self, from: d) {
                let dir = u.deletingLastPathComponent()
                for kp in [\BrandSpec.icon, \BrandSpec.logo, \BrandSpec.font] {
                    if let v = b[keyPath: kp], !v.hasPrefix("/"), v.contains(".") { b[keyPath: kp] = dir.appendingPathComponent(v).path }
                }
                brand = b
            } else { warnings.append("brand file not found or invalid: \(u.path) (make one with `pretty brand <site|app>`)") }
        } else if let bd = sb["brand"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: bd) {
            brand = try? JSONDecoder().decode(BrandSpec.self, from: d)
            for kp in [\BrandSpec.icon, \BrandSpec.logo] {
                if let v = brand?[keyPath: kp], !v.hasPrefix("/") { brand?[keyPath: kp] = o.baseDir.appendingPathComponent(v).path }
            }
        }

        // Soundtrack: real music first (your licensed library, then Kevin MacLeod's CC BY catalog),
        // generated only when asked. The grid comes from the track itself.
        var grid: BeatGrid? = nil
        var music: MusicSpec? = nil
        var gen: MusicGenSpec? = nil
        let mood = (musicCfg?["mood"] as? String) ?? (sb["mood"] as? String) ?? (cfg["mood"] as? String) ?? treatment.catalogMood
        if ap.music {
            if let g = gridStub {
                grid = BeatGrid(bpm: g["bpm"] as? Double ?? 100, firstBeat: 0)
            } else if let g = genCfg {
                var s = MusicGenSpec()
                s.mood = g["mood"] as? String ?? s.mood
                s.bpm = g["bpm"] as? Double
                s.key = g["key"] as? String
                s.seed = g["seed"] as? Int ?? s.seed
                s.energy = g["energy"] as? Double ?? s.energy
                gen = s
                grid = BeatGrid(bpm: s.bpm ?? MusicGen.style(s.mood).bpm, firstBeat: 0)
                notes.append("music: generated \(s.mood) bed — original, no attribution needed, but not a known track")
            } else if let m = musicPath {
                let r = try BeatDetect.analyze(m)
                var spec = MusicSpec(); spec.path = m.path; spec.bpm = r.bpm; spec.beatOffset = r.firstBeat
                if let l = musicCfg?["license"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: l) {
                    spec.license = try? JSONDecoder().decode(MusicLicense.self, from: d)
                }
                spec.title = musicCfg?["title"] as? String; spec.artist = musicCfg?["artist"] as? String
                if spec.license == nil { warnings.append("music \(m.lastPathComponent) has no license recorded — add \"license\" to audio.music, or keep licensed tracks in the library folder with a .license.json") }
                music = spec
                if r.confidence >= 0.2 { grid = BeatGrid(bpm: r.bpm, firstBeat: r.firstBeat) }
                else { warnings.append("music beat detection is unsure (confidence \(r.confidence)); actions won't snap to beats") }
            } else {
                do {
                    var track: MusicLibrary.Track
                    if let ref = musicCfg?["track"] as? String {
                        track = try MusicLibrary.find(ref)
                    } else {
                        var q = MusicLibrary.Query(json: (musicCfg?["find"] as? [String: Any]) ?? [:])
                        if q.mood == nil && q.feel.isEmpty && q.text == nil { q.mood = mood }
                        guard let best = try MusicLibrary.search(q, limit: 1).first else { throw fail("no track matched \(q.mood ?? "the search")") }
                        track = best
                    }
                    var spec = try MusicLibrary.spec(for: track)
                    if let off = musicCfg?["offset"] as? Double { spec.offset = off }
                    music = spec
                    if let bpm = spec.bpm { grid = BeatGrid(bpm: bpm, firstBeat: (spec.beatOffset ?? 0) - spec.offset) }
                    notes.append("music: \"\(track.title)\" — \(track.artist) (\(track.license.name))" + (track.license.requiresCredit ? "; credit required (credits.txt is written next to every render)" : ""))
                } catch {
                    if settings.music.useGenerated {
                        var s = MusicGenSpec(); s.mood = MusicGen.moods.contains(mood) ? mood : "upbeat"
                        gen = s; grid = BeatGrid(bpm: MusicGen.style(s.mood).bpm, firstBeat: 0)
                        warnings.append("couldn't get real music (\(error)); using a generated bed")
                    } else {
                        warnings.append("couldn't get music: \(error). The video will have no music bed.")
                    }
                }
            }
        }
        let sync = (cfg["sync"] as? String ?? "beats") != "none"
        let useGrid = sync ? grid : nil

        let vo = o.assetsDir.appendingPathComponent("vo")
        if ap.voice { try FileManager.default.createDirectory(at: vo, withIntermediateDirectories: true) }

        let leadIn = sb["leadIn"] as? Double ?? 0.8
        var t = leadIn
        let opensOnScene = beatsRaw.first?["scene"] != nil
        if opensOnScene { t = 0 } // the hook is on screen from frame one (it covers the page load); its words land on the beat
        else if let g = useGrid { t = g.next(atOrAfter: max(leadIn, g.period * 2 - 0.01)) } // let the music breathe for two beats
        var beats: [PlannedBeat] = [], lines: [PlannedLine] = [], actions: [PlannedAction] = []
        var scenes: [TextScene] = []
        // Without narration, `say` lines become headlines in the space around the device (or pills: "caption").
        let textStyle = (cfg["text"] as? String) ?? "headline"
        var voiceName: String? = nil
        var lastPointer = -10.0

        for (i, b) in beatsRaw.enumerated() {
            let say = (b["say"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var start = t + (b["gap"] as? Double ?? 0)
            if let g = useGrid, !(i == 0 && opensOnScene) {
                // Start story beats on the grid: the next bar if it's within a beat, else the next beat.
                let bar = g.nextBar(atOrAfter: start), nb = g.next(atOrAfter: start)
                start = bar - start <= g.period * 1.01 ? bar : nb
            }
            // Narration
            let lineStart = start + 0.12
            var lineDur = 0.0, words: [WordTime] = [], file: String? = nil
            var sceneSpec = parseScene(b["scene"]).map { styled($0, raw: b["scene"], treatment: treatment, index: scenes.count, previous: scenes.last?.transition, rng: &rng) }
            // AI B-roll: a generated clip plays full-screen under this beat's words (or alone).
            var brollSeconds = 0.0
            if let br = b["broll"] {
                let d = (br as? [String: Any]) ?? ["prompt": (br as? String) ?? ""]
                if sceneSpec == nil {
                    var t = TextScene(); t.style = "statement"; t.text = d["text"] as? String
                    sceneSpec = styled(t, raw: ["background": "x"], treatment: treatment, index: scenes.count, previous: scenes.last?.transition, rng: &rng)
                }
                let provider = (d["provider"] as? String) ?? VideoAI.available().first
                let portraitOut = ["tiktok", "reels", "shorts", "story", "instagram-story"].contains((o.preset ?? "").lowercased()) || (o.preset ?? "").hasPrefix("app-store-iphone")
                if !o.generate {
                    notes.append("beat \(i): B-roll not generated (planning without --generate); a placeholder backdrop stands in")
                    sceneSpec?.background = "glow"
                } else if let pv = provider {
                    var req = VideoAI.Request(prompt: (d["prompt"] as? String) ?? "", provider: pv)
                    req.model = d["model"] as? String
                    req.seconds = (d["seconds"] as? Int) ?? Int((d["seconds"] as? Double) ?? 6)
                    req.aspect = (d["aspect"] as? String) ?? (portraitOut ? "9:16" : "16:9")
                    req.image = (d["image"] as? String).map { Backgrounds.resolve($0, o.baseDir) }
                    if (d["styled"] as? Bool) != false { let st = VideoAI.styled(req.prompt, treatment: treatment); req.prompt = st.0; req.negative = st.1 }
                    do {
                        let clip = try VideoAI.generate(req, to: o.assetsDir.appendingPathComponent("broll"))
                        sceneSpec?.background = "clip:" + clip.file
                        brollSeconds = (d["duration"] as? Double) ?? clip.seconds
                        notes.append("beat \(i): B-roll by \(clip.provider) (\(clip.model)) — AI-generated footage; disclose it where the platform requires")
                    } catch {
                        warnings.append("beat \(i): B-roll skipped — \(error)")
                        sceneSpec?.background = "glow"
                    }
                } else {
                    warnings.append("beat \(i): B-roll needs a video key (Veo via Gemini, Sora via OpenAI, or fal) — Settings → Video, or `pretty keys set gemini|openai|fal`")
                    sceneSpec?.background = "glow"
                }
            }
            if sceneSpec != nil && b["do"] != nil {
                warnings.append("beat \(i) has a scene and actions — the actions would happen behind the full-screen type. Move them to the next beat.")
            }
            if let say {
                var shown = say
                if ap.voice, let vr = voiceReady {
                    let url = vo.appendingPathComponent(String(format: "line_%02d", i))
                    let sp = try Narrator.synthesize(say, voice: vr, to: url)
                    lineDur = sp.duration; words = sp.words; file = sp.file; voiceName = "\(sp.voice) (\(sp.provider))"; shown = sp.text
                } else {
                    // Shown as on-screen type: give viewers reading time (~2.6 words/s).
                    shown = Narrator.displayText(say)
                    let n = shown.split(separator: " ").count
                    lineDur = max(1.4, Double(n) / 2.6 + 0.5)
                    words = Voice.estimateWords(shown, duration: lineDur)
                }
                if lineDur > 8 { warnings.append("beat \(i): the line runs \(String(format: "%.1f", lineDur))s — split it so the visuals can keep up") }
                let show = file != nil ? "voice" : sceneSpec != nil ? "none" : textStyle
                lines.append(PlannedLine(beat: i, text: shown, start: round3(lineStart), duration: round3(lineDur), file: file, words: words, show: show))
            }
            let lineEnd = lineStart + lineDur
            var sceneEnd: Double? = nil
            if var sc = sceneSpec {
                sc.start = round3(start)
                let items = sceneItems(sc)
                var ts: [Double] = []
                if file != nil && !words.isEmpty {
                    // Each word / chunk / line lands as it's spoken.
                    let spoken = matchTimes(items, words)
                    ts = spoken.enumerated().map { k, v in (v.map { lineStart - start + $0 } ?? (Double(k) * 0.3 + 0.1)) }
                    for k in 1..<max(1, ts.count) where ts[k] < ts[k - 1] + 0.05 { ts[k] = ts[k - 1] + 0.05 }
                } else if let g = useGrid, ["punch", "stack"].contains(sc.style) {
                    let minGap = sc.style == "punch" ? 0.36 : 0.5
                    let k = max(1, (minGap / g.period).rounded(.up))
                    ts = items.indices.map { Double($0) * k * g.period }
                } else {
                    ts = Kinetic.defaultTimes(sc, count: items.count)
                }
                if ["type", "count", "lockup"].contains(sc.style) { ts = [ts.first ?? 0.15] }
                if i == 0 && opensOnScene, file == nil {
                    // The hook reads on frame one (feeds autoplay muted and judge the first frame): its first
                    // line is already settling in at t=0; what follows lands on the music's first beats.
                    if let g = useGrid { let first = g.next(atOrAfter: 0.12); ts = ts.map { $0 + first } }
                    if !ts.isEmpty { ts[0] = -0.4 }
                }
                sc.times = ts.map(round3)
                if let g = useGrid { sc.transitionDuration = round3(clamp(g.period * 0.75, 0.25, 0.45)) }
                var natural = sceneLength(sc, items: items)
                if brollSeconds > 0 { natural = max(items.joined().isEmpty ? 0 : natural, brollSeconds) }
                if file != nil { natural = max(natural, lineEnd - start + 0.4) }
                var e = start + natural
                if let g = useGrid { e = g.next(atOrAfter: e) }
                sc.duration = round3(e - start)
                sceneEnd = e
                sceneSpec = sc
                scenes.append(sc)
            }

            // Actions
            var prevEnd = start + 0.1
            var steps = b["do"] as? [[String: Any]] ?? []
            // Beat-level direction markers run at the beat start.
            for k in ["zoom", "spotlight", "highlight", "caption", "title"] where b[k] != nil {
                steps.insert([k: b[k]!, "at": "start", "why": "direction"], at: 0)
            }
            var firstReal = true
            for (k, step) in steps.enumerated() {
                let kind = actionKind(step)
                let isMarker = markerKinds.contains(kind)
                var cue: String
                if let at = step["at"] as? String { cue = at }
                else if let at = step["at"] as? Double { cue = String(format: "%.2f", at) }
                else { cue = firstReal && !isMarker ? (say != nil ? "auto" : "start") : (isMarker ? "start" : "after") }
                var anchor: Double
                switch cue {
                case "start": anchor = start + (isMarker ? 0 : 0.35)
                case "end": anchor = lineEnd + 0.15
                case "after": anchor = prevEnd + 0.35
                case "beat":
                    // The first beat the action can actually make (after the pointer's travel).
                    let earliest = prevEnd + (isMarker ? 0.2 : max(0.3, lead(kind, step)))
                    anchor = useGrid?.next(atOrAfter: earliest) ?? (prevEnd + 0.35)
                case "auto":
                    // Land on the spoken label when the line names it ("Tap *New task*").
                    let lbl = label(of: targetText(step[kind]) ?? targetText((step[kind] as? [String: Any])?["selector"]))
                    let tokens = (lbl ?? "").split(separator: " ").map(String.init).filter { $0.filter(\.isLetter).count >= 2 }
                    if let wt = tokens.lazy.compactMap({ Voice.time(of: $0, in: words) }).first {
                        anchor = lineStart + wt + 0.05
                    } else {
                        anchor = lineStart + min(0.7, lineDur * 0.4)
                    }
                default:
                    if cue.hasPrefix("word:") {
                        let w = String(cue.dropFirst(5))
                        if let wt = Voice.time(of: w, in: words) { anchor = lineStart + wt }
                        else {
                            anchor = lineStart + lineDur * 0.5
                            warnings.append("beat \(i) action \(k): word '\(w)' isn't in the line — cued mid-line instead")
                        }
                    } else if let n = Double(cue) { anchor = start + n }
                    else { anchor = prevEnd + 0.35; warnings.append("beat \(i) action \(k): unknown cue '\(cue)'") }
                }
                // The pointer can't start toward this target until the previous action (click, typing,
                // scroll) is done, so reserve its full travel time after it.
                let ld = isMarker ? 0 : lead(kind, step)
                let requested = anchor
                anchor = max(anchor, prevEnd + (isMarker ? 0 : max(0.3, ld)))
                let lateBy = anchor - requested
                if !isMarker && cue != "after" && cue != "beat" && (lateBy > (cue == "auto" ? 0.5 : 0.15)) {
                    warnings.append(String(format: "beat %d action %d (%@ %@) is cued '%@' but lands %.2fs late: the cursor needs time to get there after the previous action. Add \"gap\": %.1f to this beat, or give the previous beat less to do.",
                                           i, k, kind, targetText(step[kind]) ?? "", cue, anchor - requested, (anchor - requested + 0.1).rounded(.up)))
                }
                var onBeat = false
                if let g = useGrid, pointerKinds.contains(kind) || kind == "press" || kind == "type" {
                    let snapped = g.snap(anchor, tolerance: 0.22, subdivision: 2)
                    if snapped >= prevEnd + max(0.3, ld) - 0.05 { anchor = snapped }
                    onBeat = abs(g.nearest(anchor, subdivision: 2) - anchor) < 0.01
                }
                let dur = isMarker ? 0 : estimate(kind, step)
                let why = step["why"] as? String
                if why == nil && !isMarker && !["wait", "pause"].contains(kind) {
                    warnings.append("beat \(i) action \(k) (\(kind)) has no \"why\" — every click, tap and swipe should have a reason")
                }
                if !isMarker && pointerKinds.contains(kind) && anchor - lastPointer < 0.6 && lastPointer > 0 {
                    warnings.append("beat \(i) action \(k): only \(String(format: "%.2f", anchor - lastPointer))s after the previous action — hard to follow")
                }
                let stepJSON = (try? JSONSerialization.data(withJSONObject: step)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                actions.append(PlannedAction(beat: i, index: k, kind: kind, target: targetText(step[kind]), why: why, cue: cue,
                                             anchor: round3(anchor), duration: round3(dur), onBeat: onBeat, step: stepJSON))
                if !isMarker {
                    prevEnd = anchor + dur
                    if pointerKinds.contains(kind) || kind == "type" { lastPointer = anchor + dur }
                    firstReal = false
                }
            }
            var end = max(lineEnd, prevEnd) + (b["hold"] as? Double ?? 0.5)
            if let se = sceneEnd { end = max(se, prevEnd) + (b["hold"] as? Double ?? 0) }
            if let m = b["minDuration"] as? Double { end = max(end, start + m) }
            // Markers without a duration last for the beat.
            for idx in actions.indices where actions[idx].beat == i && markerKinds.contains(actions[idx].kind) {
                if var st = (try? JSONSerialization.jsonObject(with: Data(actions[idx].step.utf8))) as? [String: Any] {
                    var v = st[actions[idx].kind]
                    if let s = v as? String { v = actions[idx].kind == "caption" || actions[idx].kind == "title" ? ["text": s] : ["target": s] }
                    if var d = v as? [String: Any], d["duration"] == nil {
                        d["duration"] = round3(max(0.8, end - actions[idx].anchor)); st[actions[idx].kind] = d
                        actions[idx].step = (try? JSONSerialization.data(withJSONObject: st)).flatMap { String(data: $0, encoding: .utf8) } ?? actions[idx].step
                    }
                }
            }
            beats.append(PlannedBeat(index: i, start: round3(start), end: round3(end), say: say))
            t = end
        }
        let endsOnScene = beatsRaw.last.map { $0["scene"] != nil } ?? false
        var duration = t + (endsOnScene ? 0 : (sb["tailOut"] as? Double ?? 1.0))
        if let g = useGrid { duration = endsOnScene ? g.nextBar(atOrAfter: t - 0.02) : g.nextBar(atOrAfter: t + 0.4) + 0.05 } // end on a bar line
        duration = max(duration, t)
        // Scenes run up to the next beat (the device returns exactly on it); a closing scene holds to the end.
        for k in scenes.indices {
            let s0 = scenes[k].start
            guard let bi = beats.firstIndex(where: { abs($0.start - s0) < 0.002 }) else { continue }
            if bi + 1 < beats.count {
                let next = beats[bi + 1].start
                if next > scenes[k].end && next - scenes[k].end <= 1.5 { scenes[k].duration = round3(next - s0) }
            } else {
                scenes[k].duration = round3(duration - s0)
            }
        }

        // Music: render the generated track at the final length.
        if let g = gen {
            try FileManager.default.createDirectory(at: o.assetsDir, withIntermediateDirectories: true)
            let url = o.assetsDir.appendingPathComponent("music.wav")
            let r = try MusicGen.render(g, duration: duration, to: url)
            var spec = MusicSpec(); spec.path = url.path; spec.bpm = r.bpm; spec.beatOffset = r.beatOffset; spec.generate = g
            spec.license = MusicLicense(name: "Generated (Pretty Studio)", source: "generated")
            music = spec
        }
        if var m = music {
            m.volume = (musicCfg?["volume"] as? Double) ?? (ap.voice ? 0.2 : 0.6)
            m.fadeOut = min(2.5, (useGrid?.bar ?? 2) * 0.75)
            if let sc = musicCfg?["showCredit"] as? Bool { m.showCredit = sc }
            music = m
        }
        if !ap.voice && hasSay {
            notes.append("narration is off (\(ap.reason)); say lines appear as \(textStyle == "caption" ? "captions" : "headlines") (scene beats show their own type)")
        }
        let platform = (o.preset ?? "").lowercased()
        if platform.hasPrefix("app-store") && (duration < 15 || duration > 30) {
            warnings.append(String(format: "%.1fs is outside the App Store's 15-30s range", duration))
        }
        if ["tiktok", "reels", "shorts"].contains(platform) && duration > 45 {
            warnings.append(String(format: "%.0fs is long for short-form social; 15-35s performs best", duration))
        }
        warnings += lintCopy(sb, brand: brand, preset: o.preset)

        // The device sits on the treatment's stage (lit with the brand's colors) unless a look was chosen.
        var background: BackgroundSpec? = nil
        let bgChoice = sb["background"] as? String
        if (bgChoice == nil || bgChoice == "stage") && sb["look"] == nil {
            var bg = BackgroundSpec(); bg.type = "stage"; bg.preset = treatment.stage
            background = bg
        } else if Backgrounds.stages.contains(bgChoice ?? "") {
            var bg = BackgroundSpec(); bg.type = "stage"; bg.preset = bgChoice!
            background = bg
        } else if let b = brand, b.colors.count >= 1, bgChoice == "brand" {
            let cs = b.colors.compactMap { RGBA.parse($0) }
            if let c0 = cs.first {
                let c1 = cs.count > 1 ? cs[1] : c0.mixed(RGBA(0, 0, 0), 0.4)
                var bg = BackgroundSpec(); bg.type = "gradient"; bg.angle = 120
                bg.colors = [hex(Kinetic.darken(c0, to: 0.16)), hex(Kinetic.darken(c0.mixed(c1, 0.5), to: 0.2)), hex(Kinetic.darken(c1, to: 0.14))]
                background = bg
            }
        } else if let bgName = bgChoice, bgName != "brand" {
            var bg = BackgroundSpec(); bg.type = "gradient"; bg.preset = bgName; background = bg
        }
        // 3D shots: explicit `shot` beats, plus (on phones, when Blender is available) a hero shot the
        // first time the device appears — real depth instead of a flat screenshot.
        var shots: [DeviceShot] = []
        let phone = ["iphone", "iphone-max", "android"].contains((sb["device"] as? String) ?? "") || (sb["kind"] as? String) == "ios"
        let canShoot = Shots.defaultTools?.blender != nil
        for (i, b) in beatsRaw.enumerated() where i < beats.count {
            guard let raw = b["shot"] else { continue }
            var d = (raw as? [String: Any]) ?? [:]
            if let m = raw as? String { d["move"] = m }
            if (raw as? Bool) == false { continue }
            let bt = beats[i]
            var sh = DeviceShot(start: bt.start, duration: round3(min((d["duration"] as? Double) ?? (bt.end - bt.start), bt.end - bt.start)),
                                move: d["move"] as? String ?? treatment.choose(treatment.shotMoves, &rng))
            sh.finish = d["finish"] as? String
            sh.reflection = (d["reflection"] as? Bool) ?? treatment.reflection
            sh.offset = d["offset"] as? Double
            if let f = d["focus"] as? [Double], f.count == 2 { sh.focus = NPoint(x: f[0], y: f[1]) }
            if sh.move == "macro" && d["duration"] == nil {
                // Let the beat's line land on the full screen first; the push-in is the payoff.
                let lead = round3(min(1.3, (bt.end - bt.start) * 0.3))
                sh.start = round3(bt.start + lead); sh.duration = round3(max(1.5, sh.duration - lead))
            }
            shots.append(sh)
        }
        // A shot that ends where a scene begins stays under the scene's dissolve.
        for k in shots.indices where scenes.contains(where: { abs($0.start - shots[k].end) < 0.6 }) {
            if let sc = scenes.first(where: { abs($0.start - shots[k].end) < 0.6 }) { shots[k].duration = round3(sc.start + sc.transitionDuration + 0.1 - shots[k].start) }
        }
        if phone && canShoot && (sb["shots"] as? Bool) != false {
            if let first = beats.first(where: { b in !scenes.contains { abs($0.start - b.start) < 0.002 } }),
               !shots.contains(where: { $0.start < first.end && $0.end > first.start - 0.5 }) {
                let move = treatment.choose(treatment.shotMoves.filter { !["closeup", "duo"].contains($0) }, &rng)
                // Start as the hook's words leave; hand off to the flat device once it has landed.
                let st = max(0, first.start - (first.start > 0.1 ? 0.42 : 0))
                var sh = DeviceShot(start: round3(st), duration: round3(min(3.0, first.end - st)), move: move)
                sh.reflection = treatment.reflection
                shots.append(sh)
                shots.sort { $0.start < $1.start }
            }
        }

        // Device moves: an entrance whenever the device (re)appears, then a slow hold move.
        var moves: [DeviceMove] = []
        if (sb["moves"] as? Bool) != false {
            var prevWasScene = true
            for b in beats {
                let isScene = scenes.contains { abs($0.start - b.start) < 0.002 }
                if isScene { prevWasScene = true; continue }
                if let sh = shots.first(where: { $0.start < b.end && $0.end > b.start }) {
                    // The 3D shot is the beat's motion (a macro may wait for the line to land: the device
                    // holds still until then, so the shot starts exactly where the flat device is). A gentle
                    // push after it lands.
                    if sh.end < b.end - 0.6 { moves.append(DeviceMove(start: round3(sh.end), end: round3(b.end), type: "push", amount: 0.6)) }
                    prevWasScene = false; continue
                }
                let end = b.end
                if prevWasScene {
                    let entrance = treatment.choose(treatment.entrances, &rng)
                    // Overlap the scene's exit so the device arrives as the words leave.
                    let st = max(0, b.start - (b.start > 0.1 ? 0.42 : 0))
                    moves.append(DeviceMove(start: round3(st), end: round3(end), type: entrance))
                } else {
                    moves.append(DeviceMove(start: round3(b.start), end: round3(end), type: treatment.choose(treatment.holds, &rng), amount: 0.8))
                }
                prevWasScene = false
            }
        }

        // Sound design: whooshes on scene changes, a shimmer when the device lands, an impact on the end card.
        var sfx: [SfxClip] = []
        let settingsNow = AppSettings.load()
        if (ap.music || ap.voice) && settingsNow.music.useSfx && (sb["sfx"] as? Bool) != false && Score.available {
            var cues: [(String, Double, Double)] = []
            for (k, sc) in scenes.enumerated() {
                let prevAdj = scenes.indices.contains { $0 != k && abs(scenes[$0].end - sc.start) < 0.06 }
                let nextAdj = scenes.indices.contains { $0 != k && abs(scenes[$0].start - sc.end) < 0.06 }
                if sc.start > 0.1 { cues.append(("whoosh", sc.start - 0.28, prevAdj ? 0.22 : 0.34)) }
                // Handing back to the device gets its own (quieter) air.
                if !nextAdj && sc.end < duration - 0.3 { cues.append(("whoosh", sc.end - 0.36, 0.26)) }
                if sc.style == "lockup" {
                    cues.append(("riser", max(0, sc.start - 1.45), 0.22))
                    cues.append(("impact", sc.start + 0.02, 0.5))
                }
            }
            for m in moves where ["rise", "tilt"].contains(m.type) { cues.append(("shimmer", m.start + 0.55, 0.2)) }
            for sh in shots { cues.append(("whoosh", sh.start + 0.05, 0.24)); cues.append(("shimmer", sh.start + sh.duration * 0.62, 0.2)) }
            if treatment.name != "cinematic" {
                for a in actions where ["click", "tap", "select"].contains(a.kind) { cues.append(("tap", a.anchor - 0.01, 0.16)) }
            }
            // One sound per moment: the same kind within 0.4s collapses to the louder cue.
            cues.sort { $0.1 < $1.1 }
            var deduped: [(String, Double, Double)] = []
            for c in cues {
                if let i = deduped.lastIndex(where: { $0.0 == c.0 && abs($0.1 - c.1) < 0.4 }) {
                    if c.2 > deduped[i].2 { deduped[i] = c }
                } else { deduped.append(c) }
            }
            cues = deduped
            let sfxDir = o.assetsDir.appendingPathComponent("sfx")
            for kind in Set(cues.map(\.0)) {
                do {
                    let src = try Score.sfx(kind, treatment: treatment)
                    try FileManager.default.createDirectory(at: sfxDir, withIntermediateDirectories: true)
                    let dst = sfxDir.appendingPathComponent("\(kind).mp3")
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: src, to: dst)
                    for c in cues where c.0 == kind { sfx.append(SfxClip(path: dst.path, at: round3(max(0, c.1)), volume: c.2, kind: kind)) }
                } catch {
                    warnings.append("sound design skipped for \(kind): \(error)")
                }
            }
            sfx.sort { $0.at < $1.at }
        }
        notes.append("treatment: \(treatment.name) — \(treatment.summary)")
        if (ap.voice && voiceReady?.provider == "elevenlabs") || !sfx.isEmpty, let n = Score.tierNote() { warnings.append(n) }
        let credits = MusicLibrary.credits(music: music, usedMusic: ap.music && music != nil, voiceProvider: ap.voice ? voiceReady?.provider : nil, sfx: !sfx.isEmpty).lines

        return Plan(mode: ap.mode, reason: ap.reason, voice: voiceName, grid: useGrid, music: music, leadIn: leadIn,
                    duration: round3(duration), beats: beats, lines: lines, actions: actions, warnings: warnings,
                    notes: notes.isEmpty ? nil : notes, voiceSpec: voice, scenes: scenes.isEmpty ? nil : scenes,
                    brand: brand, background: background, credits: credits.isEmpty ? nil : credits,
                    headroom: ["tiktok", "reels", "shorts", "instagram-story", "story"].contains(platform) || platform.hasPrefix("app-store") ? 0.2 : 0.14,
                    treatment: treatment.name, moves: moves.isEmpty ? nil : moves, shots: shots.isEmpty ? nil : shots, sfx: sfx.isEmpty ? nil : sfx,
                    frameColor: sb["look"] == nil ? treatment.frameColor : nil, frameTheme: sb["look"] == nil ? treatment.frameTheme : nil,
                    shadow: sb["look"] == nil ? treatment.shadow : nil, seed: seed)
    }

    /// Dress a scene in the treatment: background, type face/weight/alignment, reveal, transition,
    /// and Apple-style two-tone for two-sentence statements. Anything the storyboard set wins.
    static func styled(_ sc: TextScene, raw: Any?, treatment t: Treatment, index: Int, previous: String? = nil, rng: inout SeedRNG) -> TextScene {
        var s = sc
        let d = raw as? [String: Any] ?? [:]
        if d["background"] == nil {
            s.background = s.style == "lockup" ? t.sceneBackgrounds[0] : t.sceneBackgrounds[index % t.sceneBackgrounds.count]
        }
        if d["transition"] == nil {
            // Vary within the treatment's vocabulary: never the same transition twice in a row.
            let fresh = t.transitions.filter { $0 != previous }
            s.transition = t.choose(fresh.isEmpty ? t.transitions : fresh, &rng)
        }
        if d["align"] == nil && ["statement", "stack", "reveal"].contains(s.style) { s.align = t.choose(t.aligns, &rng) }
        if d["reveal"] == nil { s.reveal = t.reveal }
        if d["weight"] == nil && ["statement", "stack", "reveal"].contains(s.style) { s.weight = t.weight }
        if d["font"] == nil && t.serif && ["statement", "reveal"].contains(s.style) { s.font = "serif" }
        if s.style == "statement" && s.accent.isEmpty && s.secondary.isEmpty && d["secondary"] == nil, let text = s.text {
            // "Your cards. All together." → the second sentence in the quieter tone.
            let parts = text.split(separator: " ").map(String.init)
            if let cut = parts.dropLast().lastIndex(where: { $0.last.map { ".!?".contains($0) } ?? false }) {
                s.secondary = Array(parts[(cut + 1)...])
            }
        }
        return s
    }

    static func hex(_ c: RGBA) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    // MARK: Scenes

    /// `"scene": "Text"` (a statement) or `"scene": {style, text, ...}`.
    static func parseScene(_ v: Any?) -> TextScene? {
        if let s = v as? String { var sc = TextScene(); sc.text = s; return sc }
        guard let d = v as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        return try? JSONDecoder().decode(TextScene.self, from: data)
    }

    /// The things that land one by one: words (statement, punch), lines (stack, reveal), or one block.
    static func sceneItems(_ s: TextScene) -> [String] {
        switch s.style {
        case "stack", "reveal": return s.allLines
        case "punch": return s.lines ?? (s.text ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        case "type", "count", "lockup": return [s.text ?? s.allLines.first ?? ""]
        default: return (s.text ?? s.allLines.joined(separator: " ")).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        }
    }

    /// How long a scene needs on screen to be read (no narration).
    static func sceneLength(_ s: TextScene, items: [String]) -> Double {
        let last = s.times?.last ?? 0
        let words = items.joined(separator: " ").split(separator: " ").count
        switch s.style {
        case "punch": return last + 0.85
        case "stack": return last + 1.15
        case "reveal": return last + 0.6 + max(1.0, Double(words) * 0.2)
        case "type": return 0.15 + Double((s.text ?? "").count) / 20 + 1.1
        case "count": return 2.4
        case "lockup": return 3.0
        default: return last + 0.6 + max(1.25, Double(words) * 0.27)
        }
    }

    /// When each item's first word is spoken (nil when it isn't).
    static func matchTimes(_ items: [String], _ spoken: [WordTime]) -> [Double?] {
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var j = 0
        return items.map { item in
            guard let first = item.split(separator: " ").first.map({ norm(String($0)) }), !first.isEmpty else { return nil }
            for k in j..<spoken.count where norm(spoken[k].w) == first || (first.count >= 4 && norm(spoken[k].w).hasPrefix(first)) {
                j = k + 1
                return spoken[k].t
            }
            return nil
        }
    }

    // MARK: Copy

    /// Ad-speak that makes every product sound the same. Say what actually happens instead.
    static let genericPhrases = ["seamless", "effortless", "streamline", "game-changer", "game changer", "revolutioniz", "revolutionary",
                                 "unlock", "supercharge", "next level", "next-level", "elevate", "empower", "cutting-edge", "cutting edge",
                                 "state-of-the-art", "all-in-one", "one-stop", "say goodbye to", "look no further", "take control",
                                 "boost your productivity", "boost productivity", "in just a few clicks", "with just a few clicks",
                                 "like never before", "best-in-class", "world-class", "harness the power", "leverage", "robust",
                                 "innovative", "intuitive", "user-friendly", "powerful yet simple", "simple yet powerful",
                                 "transform the way", "made easy", "at your fingertips", "the future of", "redefin", "reimagin",
                                 "hassle-free", "stress-free", "with ease", "unleash", "skyrocket", "level up your"]

    public static func lintCopy(_ sb: [String: Any], brand: BrandSpec?, preset: String?) -> [String] {
        guard let beats = sb["beats"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        var allText = ""
        for (i, b) in beats.enumerated() {
            var texts: [String] = []
            if let s = b["say"] as? String { texts.append(s) }
            if let sc = parseScene(b["scene"]) { texts += [sc.text, sc.sub].compactMap { $0 } + (sc.lines ?? []) }
            for k in ["title", "caption"] {
                if let s = b[k] as? String { texts.append(s) } else if let d = b[k] as? [String: Any], let s = d["text"] as? String { texts.append(s) }
            }
            for text in texts {
                allText += " " + text
                let low = text.lowercased()
                for g in genericPhrases where low.contains(g) {
                    out.append("copy: beat \(i) says \"\(g)\" — generic ad-speak. Name what the viewer sees happen (the screen, the number, the result).")
                }
            }
            if let sc = parseScene(b["scene"]) {
                let n = sceneItems(sc).joined(separator: " ").split(separator: " ").count
                if sc.style == "punch" && sceneItems(sc).count > 5 { out.append("copy: beat \(i) punches \(sceneItems(sc).count) words — 2-4 hits land harder") }
                if sc.style == "statement" && n > 12 { out.append("copy: beat \(i)'s statement is \(n) words — cut to 10 or fewer, or split it") }
            }
        }
        if let first = beats.first {
            let hook = (first["say"] as? String) ?? parseScene(first["scene"])?.text ?? ""
            let n = Narrator.displayText(hook).split(separator: " ").count
            if n > 9 { out.append("copy: the opening line is \(n) words — a hook lands in 7 or fewer (the first second decides whether people stay)") }
        }
        let lockupNames = beats.contains { parseScene($0["scene"]).map { $0.style == "lockup" && $0.text == nil } ?? false }
        if let name = brand?.name, !name.isEmpty, !lockupNames, !allText.lowercased().contains(name.lowercased()) {
            out.append("copy: \(name) is never named on screen or in the narration — say it at least once, ideally in a closing lockup")
        }
        let p = (preset ?? "").lowercased()
        let ad = ["tiktok", "reels", "shorts", "instagram", "square", "x"].contains(p) || p.hasPrefix("app-store")
        if ad, !(beats.last.flatMap { parseScene($0["scene"]) }.map { $0.style == "lockup" } ?? false) {
            out.append("copy: end on a lockup scene (icon + name + promise + where to get it) — it's what people remember")
        }
        return out
    }

    /// A readable timeline for agents to review before recording.
    public static func timeline(_ p: Plan) -> String {
        var rows: [String] = []
        var head = "audio: \(p.mode) (\(p.reason))"
        if let g = p.grid { head += String(format: " · %.0f BPM, beat %.3fs", g.bpm, g.period) }
        if let v = p.voice { head += " · voice \(v)" }
        rows.append(head)
        rows.append(String(format: "total %.2fs", p.duration))
        for b in p.beats {
            let onBar = p.grid.map { $0.isDownbeat(b.start) } == true ? " ♪bar" : ""
            rows.append(String(format: "%6.2f  ▶ beat %d%@", b.start, b.index, onBar) + (b.say.map { "  \"\($0)\"" } ?? ""))
            if let l = p.lines.first(where: { $0.beat == b.index }) {
                rows.append(String(format: "%6.2f    🎙 %.2fs%@", l.start, l.duration, l.file == nil ? " (caption only)" : ""))
            }
            for a in p.actions where a.beat == b.index {
                let tgt = a.target.map { " \($0)" } ?? ""
                let why = a.why.map { " — \($0)" } ?? ""
                rows.append(String(format: "%6.2f    • %@%@%@  [%@%@]", a.anchor, a.kind, tgt, why, a.cue, a.onBeat ? ", on beat" : ""))
            }
        }
        if let n = p.notes, !n.isEmpty { rows.append("notes:"); rows += n.map { "  - \($0)" } }
        if !p.warnings.isEmpty { rows.append("warnings:"); rows += p.warnings.map { "  - \($0)" } }
        return rows.joined(separator: "\n")
    }

    // MARK: Assembly

    /// Put the plan's soundtrack into a project recorded on the plan's clock (web).
    /// Narration follows actual beat starts (beat markers), so a slow page load can't desync it.
    public static func apply(_ plan: Plan, to p: inout Project, beatMarkers: [Marker], bundle: URL) {
        var offsets: [Int: Double] = [:]
        for m in beatMarkers where m.type == "beat" {
            if let i = m.index, let b = plan.beats.first(where: { $0.index == i }) { offsets[i] = m.t - b.start }
        }
        p.audio.mode = plan.mode
        if let v = plan.voiceSpec { p.audio.voice = v }
        p.audio.voiceover = []
        var captions: [CaptionItem] = []
        var headlines: [Overlay] = []
        for l in plan.lines {
            let at = l.start + (offsets[l.beat] ?? 0)
            if let f = l.file {
                p.audio.voiceover.append(VoiceClip(path: relative(f, to: bundle), at: round3(at), volume: 1, text: l.text,
                                                   duration: l.duration, words: l.words, time: "source"))
            } else if l.show == "caption" {
                captions.append(CaptionItem(start: round3(at), end: round3(at + l.duration), text: l.text))
            } else if l.show != "none" {
                let beatEnd = (plan.beats.first { $0.index == l.beat }?.end ?? (l.start + l.duration)) + (offsets[l.beat] ?? 0)
                headlines.append(headline(l.text, start: at - 0.05, end: max(at + l.duration, beatEnd - 0.1)))
            }
        }
        p.captions.items = captions
        p.overlays = p.overlays.filter { $0.id != "headline" } + headlines
        if var m = plan.music {
            m.path = m.path.map { relative($0, to: bundle) }
            p.audio.music = m
        } else { p.audio.music = MusicSpec() }
        applyLook(plan, to: &p, offset: { i in offsets[i] ?? 0 })
    }

    /// A headline in the free band above the device (narration-free videos).
    static func headline(_ text: String, start: Double, end: Double) -> Overlay {
        var o = Overlay()
        o.id = "headline"; o.type = "text"; o.text = text; o.style = "title"; o.position = "top"
        o.start = round3(max(0, start)); o.end = round3(end); o.animation = "rise"; o.size = 0.8; o.maxWidth = 0.86; o.weight = "semibold"
        return o
    }

    /// Scenes, brand and background from the plan.
    static func applyLook(_ plan: Plan, to p: inout Project, offset: @escaping (Int) -> Double) {
        if let b = plan.brand { p.brand = b }
        if let bg = plan.background { p.background = bg }
        if let sc = plan.scenes {
            p.scenes = sc.map { s in
                var s = s
                if let bi = plan.beats.first(where: { abs($0.start - s.start) < 0.002 })?.index { s.start = round3(s.start + offset(bi)) }
                return s
            }
        }
        // Headlines need room above the device.
        if p.overlays.contains(where: { $0.id == "headline" }) { p.layout.headroom = max(p.layout.headroom, plan.headroom ?? 0.14) }
        if let c = plan.frameColor { p.frame.color = c }
        if let th = plan.frameTheme { p.frame.theme = th }
        if let sh = plan.shadow { p.layout.shadow = sh }
        let shift: (Double) -> Double = { t in
            let bi = plan.beats.last(where: { $0.start <= t + 0.5 })?.index ?? 0
            return t + offset(bi)
        }
        if let ms = plan.moves { p.moves = ms.map { var m = $0; m.start = round3(shift(m.start)); m.end = round3(shift(m.end)); return m } }
        p.shots = (plan.shots ?? []).map { var x = $0; x.start = round3(shift(x.start)); return x }
        if let fx = plan.sfx { p.audio.sfx = fx.map { var c = $0; c.at = round3(shift(c.at)); return c } }
        if p.background.type == "stage" { p.background.grain = 0 }
        // Directed videos move calmly: a lighter shutter keeps the UI legible through zooms.
        if plan.treatment != nil { p.motion.blur = "low" }
    }

    /// Keep automatic zooms out of the moments that already move: scenes (the device is hidden) and
    /// device entrances (a zoom during a tilt reads as chaos). Zooms are source time; moves/scenes output.
    public static func tidyZooms(_ p: inout Project, sourceDuration: Double) {
        let map = TimeMap(sourceDuration: sourceDuration, timeline: p.timeline)
        var busy: [(Double, Double)] = p.scenes.map { ($0.start - 0.2, $0.end + 0.2) }
        busy += p.moves.filter { ["rise", "tilt"].contains($0.type) }.map { ($0.start, $0.start + 1.5) }
        busy += p.shots.map { ($0.start, $0.end + 0.3) }
        // A headline gets read before a zoom pushes the device over it.
        busy += p.overlays.filter { $0.id == "headline" }.map { ($0.start - 0.2, $0.start + 1.3) }
        p.zoom.segments = p.zoom.segments.compactMap { z in
            guard z.auto else { return z }
            let a = map.output(atSource: z.start), b = map.output(atSource: z.end)
            var z = z
            for (s, e) in busy where a < e && s < b {
                // Trim the zoom to start after the busy window if enough remains, else drop it.
                if e < b - 1.2 { z.start = map.source(atOutput: e + 0.1) } else { return nil }
            }
            return z
        }
    }

    /// Remember what this video used, so the next one for the project looks and sounds different.
    public static func remember(_ plan: Plan, name: String, historyURL: URL?) {
        guard let u = historyURL else { return }
        var h = History.load(u)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let music = plan.music?.track ?? plan.music?.title.map { "\($0)#\(plan.seed ?? 0)" } ?? plan.music?.path.map { URL(fileURLWithPath: $0).lastPathComponent }
        // Re-recording or re-conforming the same video updates its entry instead of adding one.
        h.entries.removeAll { $0.name == name }
        h.entries.append(History.Entry(date: f.string(from: Date()), name: name, treatment: plan.treatment ?? "?", music: music,
                                       styles: (plan.scenes ?? []).map { "\($0.style)/\($0.background)" }))
        h.save(u)
    }

    /// Retime a loosely captured recording (simulator, desktop) so its clicks land on the
    /// plan's cues: cut or speed up dead time, freeze-frame where the plan needs more room.
    /// Returns notes for the agent.
    public static func conform(_ p: inout Project, events: InputEvents, sourceDuration: Double, plan: Plan, bundle: URL) -> [String] {
        var notes: [String] = []
        let planned = plan.actions.filter { ["click", "doubleClick", "rightClick", "tap", "select"].contains($0.kind) }
        let recorded = events.clicks.filter { $0.button == "left" }.sorted { $0.t < $1.t }
        // Match planned clicks to recorded ones: same target selector when both are known (web),
        // otherwise the next click in order (simulator / desktop marks).
        var pairs: [(Double, Double)] = []
        var next = 0
        for a in planned {
            guard next < recorded.count else { break }
            var j = next
            if let tgt = a.target, recorded[next...].contains(where: { $0.target != nil }) {
                if let k = recorded[next...].firstIndex(where: { $0.target == tgt }) { j = k }
            }
            pairs.append((recorded[j].t, a.anchor))
            next = j + 1
        }
        let clicks = pairs.map(\.0), cues = pairs.map(\.1)
        let n = pairs.count
        if planned.count != n || recorded.count != n {
            notes.append("plan has \(planned.count) clicks/taps, recording has \(recorded.count): aligned \(n)")
        }
        var cuts: [TimeRange] = [], speeds: [SpeedRange] = [], holds: [HoldRange] = []
        var trimStart = 0.0, trimEnd: Double? = nil
        if n > 0 {
            // Before the first click.
            if clicks[0] > cues[0] { trimStart = clicks[0] - cues[0] }
            else if cues[0] > clicks[0] { holds.append(HoldRange(at: 0, duration: round3(cues[0] - clicks[0]), auto: true)) }
            for k in 0..<(n - 1) {
                let s0 = clicks[k], s1 = clicks[k + 1], a0 = cues[k], a1 = cues[k + 1]
                let ds = s1 - s0, da = a1 - a0
                if ds - da > 0.12 {
                    // Cut dead time from the middle, keeping the click's aftermath and the glide into the next one.
                    let cutStart = s0 + 0.7, cutEnd = s1 - 0.95
                    var c = 0.0
                    if cutEnd - cutStart > 0.05 {
                        c = min(ds - da, cutEnd - cutStart)
                        cuts.append(TimeRange(start: round3(cutStart), end: round3(cutStart + c), auto: true))
                    }
                    // Whatever is still too long plays faster.
                    let remaining = ds - c
                    if remaining - da > 0.05 {
                        let rate = remaining / da
                        speeds.append(SpeedRange(start: round3(s0), end: round3(s1), rate: round3(min(rate, 8)), auto: true))
                        if rate > 4 { notes.append(String(format: "click %d→%d needed a %.1fx speed-up; give that action more time in the plan", k, k + 1, rate)) }
                    }
                } else if da - ds > 0.12 {
                    let at = max(s0 + 0.3, s1 - 0.95)
                    holds.append(HoldRange(at: round3(at), duration: round3(da - ds), auto: true))
                }
            }
            let tailNeeded = plan.duration - cues[n - 1]
            let tailHave = sourceDuration - clicks[n - 1]
            if tailHave > tailNeeded { trimEnd = round3(clicks[n - 1] + tailNeeded) }
            else if tailNeeded - tailHave > 0.1 { holds.append(HoldRange(at: round3(max(0, sourceDuration - 0.05)), duration: round3(tailNeeded - tailHave), auto: true)) }
        } else {
            notes.append("no clicks to align — only the soundtrack was applied")
        }
        p.timeline.trimStart = round3(trimStart)
        p.timeline.trimEnd = trimEnd
        p.timeline.cuts = p.timeline.cuts.filter { !$0.auto } + cuts
        p.timeline.speed = p.timeline.speed.filter { !$0.auto } + speeds
        p.timeline.holds = p.timeline.holds.filter { !$0.auto } + holds
        // Soundtrack in OUTPUT time: after conforming, output time == plan time.
        p.audio.mode = plan.mode
        if let v = plan.voiceSpec { p.audio.voice = v }
        p.audio.voiceover = plan.lines.compactMap { l in
            l.file.map { VoiceClip(path: relative($0, to: bundle), at: l.start, volume: 1, text: l.text, duration: l.duration, words: l.words, time: "output") }
        }
        p.captions.items = plan.lines.filter { $0.file == nil && $0.show == "caption" }.map { CaptionItem(start: $0.start, end: round3($0.start + $0.duration), text: $0.text) }
        let heads = plan.lines.filter { $0.file == nil && $0.show != "caption" && $0.show != "none" }.map { l in
            headline(l.text, start: l.start - 0.05, end: max(l.start + l.duration, (plan.beats.first { $0.index == l.beat }?.end ?? 0) - 0.1))
        }
        p.overlays = p.overlays.filter { $0.id != "headline" } + heads
        if var m = plan.music { m.path = m.path.map { relative($0, to: bundle) }; p.audio.music = m } else { p.audio.music = MusicSpec() }
        applyLook(plan, to: &p, offset: { _ in 0 })
        return notes
    }

    static func relative(_ path: String, to bundle: URL) -> String {
        let base = bundle.standardizedFileURL.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
