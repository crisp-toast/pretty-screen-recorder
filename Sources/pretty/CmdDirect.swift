import Foundation
import PrettyCore

// MARK: plan

/// pretty plan <storyboard.json> [-p preset] [--out dir]
func cmdPlan(_ a: Args) throws {
    let sbURL = url(try a.requirePos(0, "storyboard.json (with \"beats\")"))
    guard let sb = try JSONSerialization.jsonObject(with: Data(contentsOf: sbURL)) as? [String: Any] else { throw fail("storyboard must be a JSON object") }
    let out = a.str("out").map(url) ?? sbURL.deletingPathExtension().appendingPathExtension("plan")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let preset = a.str("preset") ?? (sb["preset"] as? String)
    var opts = Director.Options(preset: preset, assetsDir: out, baseDir: sbURL.deletingLastPathComponent(),
                                historyURL: Home.historyURL(project: a.str("project") ?? (sb["project"] as? String)))
    if let s = a.str("seed") { guard let seed = UInt64(s) else { throw fail("--seed must be a whole number ≥ 0") }; opts.seed = seed }
    opts.generate = !a.has("no-generate")
    let plan = try Director.plan(storyboard: sb, options: opts)
    let planURL = out.appendingPathComponent("plan.json")
    try prettyJSON(plan).write(to: planURL)
    let text = Director.timeline(plan)
    Log.info(text)
    emit(["ok": true, "plan": planURL.path, "mode": plan.mode, "reason": plan.reason, "duration": plan.duration, "treatment": orNull(plan.treatment),
          "bpm": plan.grid.map { $0.bpm } ?? NSNull(), "voice": plan.voice ?? NSNull(),
          "timeline": text.split(separator: "\n").map(String.init), "warnings": plan.warnings])
}

/// Plan + record a directed web storyboard into `bundle`. Returns notes for the summary.
func recordDirected(sb: [String: Any], sbURL: URL, bundle: URL, preset: String?, project: String? = nil, seed: Int? = nil) throws -> (planURL: URL, plan: Director.Plan) {
    let sources = bundle.appendingPathComponent("sources")
    var opts = Director.Options(preset: preset, assetsDir: sources, baseDir: sbURL.deletingLastPathComponent(),
                                historyURL: Home.historyURL(project: project ?? (sb["project"] as? String)))
    if let seed { opts.seed = UInt64(seed) }
    let plan = try Director.plan(storyboard: sb, options: opts)
    let planURL = sources.appendingPathComponent("plan.json")
    try prettyJSON(plan).write(to: planURL)
    Log.info(Director.timeline(plan))
    return (planURL, plan)
}

// MARK: conform

/// pretty conform <bundle> --plan plan.json
func cmdConform(_ a: Args) throws {
    let b = try bundleArg(a)
    guard let planPath = a.str("plan") else { throw fail("conform needs --plan plan.json (from `pretty plan`)") }
    var plan = try JSONDecoder().decode(Director.Plan.self, from: Data(contentsOf: url(planPath)))
    let base = Studio.locate(b).base
    // Bring narration and music into the bundle so it stays self-contained.
    let fm = FileManager.default
    let vo = base.appendingPathComponent("sources/vo")
    try fm.createDirectory(at: vo, withIntermediateDirectories: true)
    for i in plan.lines.indices {
        guard let f = plan.lines[i].file else { continue }
        let dst = vo.appendingPathComponent(URL(fileURLWithPath: f).lastPathComponent)
        if f != dst.path { try? fm.removeItem(at: dst); try fm.copyItem(at: URL(fileURLWithPath: f), to: dst) }
        plan.lines[i].file = dst.path
    }
    if let mp = plan.music?.path {
        let src = URL(fileURLWithPath: mp)
        let dst = base.appendingPathComponent("sources/music." + (src.pathExtension.isEmpty ? "wav" : src.pathExtension))
        if src.path != dst.path { try? fm.removeItem(at: dst); try fm.copyItem(at: src, to: dst) }
        plan.music?.path = dst.path
    }
    let studio = try Studio(url: b)
    var p = studio.project
    // Bring the sound design into the bundle too.
    if var fx = plan.sfx {
        let dir = base.appendingPathComponent("sources/sfx")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for k in fx.indices {
            let src = URL(fileURLWithPath: fx[k].path), dst = dir.appendingPathComponent(src.lastPathComponent)
            if src.path != dst.path && fm.fileExists(atPath: src.path) { try? fm.removeItem(at: dst); try? fm.copyItem(at: src, to: dst) }
            fx[k].path = dst.path
        }
        plan.sfx = fx
    }
    let notes = Director.conform(&p, events: studio.events, sourceDuration: studio.sourceDuration, plan: plan, bundle: base)
    p.zoom.segments = p.zoom.segments.filter { !$0.auto } + AutoEdit.smartZooms(events: studio.events, duration: studio.sourceDuration, level: p.zoom.level,
                                                                              mode: p.zoom.mode, kind: p.source.kind).filter { z in !p.zoom.segments.contains { !$0.auto && $0.start < z.end && z.start < $0.end } }
    Director.tidyZooms(&p, sourceDuration: studio.sourceDuration)
    try ProjectIO.save(p, to: b)
    // The project is the folder above <project>/video/<bundle> when the bundle lives in the projects root.
    var inferred: String? = nil
    if let root = Home.projectsRoot?.standardizedFileURL.path, base.standardizedFileURL.path.hasPrefix(root + "/") {
        inferred = base.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    }
    Director.remember(plan, name: p.name, historyURL: Home.historyURL(project: a.str("project") ?? inferred))
    try prettyJSON(plan).write(to: base.appendingPathComponent("sources/plan.json"))
    try summarize(b, extra: ["conformed": true, "conformNotes": notes, "planDuration": plan.duration])
}

// MARK: voice

/// Narration spec from flags (--provider, --voice, --model, --speed, --style, --instructions).
func voiceSpecArgs(_ a: Args, base: VoiceSpec = VoiceSpec()) -> VoiceSpec {
    var v = base
    if let x = a.str("provider") { v.provider = x }
    if let x = a.str("voice") { v.voice = x }
    if let x = a.str("model") { v.model = x }
    if let x = a.double("speed") ?? a.double("rate") { v.speed = x }
    if let x = a.double("style") { v.style = x }
    if let x = a.str("instructions") { v.instructions = x }
    return v
}

/// pretty voice list [--provider p] | say "text" [-o f] | add <bundle> "text" --at T | add <bundle> --file f --at T [--text] | clear <bundle>
func cmdVoice(_ a: Args) throws {
    let sub = a.pos(0) ?? "list"
    switch sub {
    case "list", "voices":
        let settings = AppSettings.load()
        let provider = a.str("provider") ?? (settings.voice.provider == "none" ? "elevenlabs" : settings.voice.provider)
        guard Secrets.get(provider) != nil || provider == "openai" else {
            emit(["ok": false, "provider": provider, "voices": [],
                  "error": Narrator.unavailableReason(VoiceSpec()), "setup": "Open Pretty Studio → Settings → Voice, or: pretty keys set \(provider)"])
            exit(3)
        }
        let vs = try Narrator.voices(provider: provider, cachedOK: !a.has("refresh"))
        let current = Narrator.resolve(nil)
        emit(["ok": true, "provider": provider, "current": current.map { ["provider": $0.provider, "voice": $0.voiceName, "id": $0.voiceId, "model": $0.model] } ?? NSNull(),
              "models": Narrator.models(provider: provider),
              "voices": vs.map { v -> [String: Any] in
                  var d: [String: Any] = ["id": v.id, "name": v.name]
                  if let c = v.category { d["category"] = c }
                  if !v.labels.isEmpty { d["labels"] = v.labels }
                  if let x = v.description, !x.isEmpty { d["description"] = String(x.prefix(160)) }
                  return d
              },
              "tip": "Pick a default in Pretty Studio → Settings → Voice (with previews), or `pretty setup voice --provider \(provider) --voice NAME`. Per storyboard: audio.voice = {provider, voice, model, speed, style}."])
    case "say":
        let text = try a.requirePos(1, "text")
        let spec = voiceSpecArgs(a)
        let out = a.str("out").map(url) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("voice")
        let sp = try Narrator.synthesize(text, spec: spec, to: out)
        emit(["ok": true, "file": sp.file, "duration": sp.duration, "voice": sp.voice, "provider": sp.provider, "text": sp.text,
              "words": sp.words.map { [$0.w, $0.t] as [Any] }])
    case "add":
        let b = url(try a.requirePos(1, "bundle"))
        guard let at = a.double("at") else { throw fail("voice add needs --at SECONDS") }
        var p = try ProjectIO.load(b)
        let base = Studio.locate(b).base
        let dir = base.appendingPathComponent("sources/vo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var clip: VoiceClip
        if let f = a.str("file") {
            let src = url(f)
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if src.path != dst.path { try? FileManager.default.removeItem(at: dst); try FileManager.default.copyItem(at: src, to: dst) }
            let dur = (try? Media.probe(dst).duration) ?? 0
            let text = a.str("text") ?? a.pos(2)
            clip = VoiceClip(path: "sources/vo/\(dst.lastPathComponent)", at: at, text: text, duration: round3(dur),
                             words: text.map { Voice.estimateWords($0, duration: dur) })
        } else {
            let text = try a.requirePos(2, "text to speak (or --file)")
            let spec = voiceSpecArgs(a, base: p.audio.voice)
            let name = String(format: "vo_%02d", p.audio.voiceover.count)
            let sp = try Narrator.synthesize(text, spec: spec, to: dir.appendingPathComponent(name))
            clip = VoiceClip(path: "sources/vo/\(URL(fileURLWithPath: sp.file).lastPathComponent)", at: at, text: sp.text, duration: sp.duration, words: sp.words)
        }
        clip.time = a.str("time") ?? "output"
        p.audio.voiceover.append(clip)
        p.audio.voiceover.sort { $0.at < $1.at }
        if p.audio.mode == "music" || p.audio.mode == "none" { Log.warn("audio.mode is \(p.audio.mode) — the narration won't be heard until you set audio.mode=voiceover or both") }
        try ProjectIO.save(p, to: b)
        emit(["ok": true, "clip": clip.path, "at": clip.at, "duration": clip.duration ?? 0, "clips": p.audio.voiceover.count])
    case "clear":
        let b = url(try a.requirePos(1, "bundle"))
        var p = try ProjectIO.load(b)
        let n = p.audio.voiceover.count
        p.audio.voiceover = []
        try ProjectIO.save(p, to: b)
        emit(["ok": true, "removed": n])
    default:
        throw fail("voice subcommands: list | say | add | clear")
    }
}

// MARK: music

func trackJSON(_ t: MusicLibrary.Track) -> [String: Any] {
    var d: [String: Any] = ["id": t.id, "title": t.title, "artist": t.artist, "source": t.source, "license": t.license.name,
                            "creditRequired": t.license.requiresCredit, "famous": t.famous, "feel": t.feel]
    if let b = t.bpm { d["bpm"] = b }
    if let x = t.duration { d["duration"] = x }
    if let g = t.genre { d["genre"] = g }
    if let i = t.instruments { d["instruments"] = i }
    if let x = t.description { d["description"] = String(x.prefix(140)) }
    if let s = t.score { d["score"] = s }
    d["downloaded"] = t.file != nil
    return d
}

/// pretty music search [text] [--mood M] [--bpm 100-125] [--min S] [--famous] | get <track> | use <bundle> <track>
///              | library | moods | analyze <file|bundle> | generate ... | <bundle> song.m4a
func cmdMusicDispatch(_ a: Args) throws {
    switch a.pos(0) {
    case "moods":
        emit(["moods": MusicLibrary.moods.keys.sorted(), "generatedMoods": MusicGen.moods,
              "note": "Search moods pick real tracks (Kevin MacLeod CC BY 4.0, or your licensed folder). `music generate` makes an original bed with an exact beat grid."])
    case "search", "find":
        var q = MusicLibrary.Query()
        q.text = a.pos(1)
        q.mood = a.str("mood")
        if let f = a.str("feel") { q.feel = f.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let b = a.str("bpm") {
            let parts = b.split(separator: "-").compactMap { Double($0) }
            if parts.count == 2 { q.bpm = parts[0]...parts[1] } else if let x = parts.first { q.bpm = (x - 8)...(x + 8) }
        }
        q.minDuration = a.double("min")
        q.famousOnly = a.has("famous")
        q.source = a.str("source")
        if q.text == nil && q.mood == nil && q.feel.isEmpty { q.mood = "upbeat" }
        let rs = try MusicLibrary.search(q, limit: a.int("limit") ?? 12)
        emit(["ok": true, "count": rs.count, "tracks": rs.map(trackJSON),
              "use": "Storyboard: \"audio\": {\"music\": {\"track\": \"<id>\"}}  ·  Project: pretty music use <bundle> <id>"])
    case "get":
        let t = try MusicLibrary.find(try a.requirePos(1, "track id or title"))
        let f = try MusicLibrary.fetch(t)
        var d = trackJSON(t); d["file"] = f.path; d["credit"] = t.license.credit ?? NSNull()
        emit(["ok": true, "track": d])
    case "use":
        let b = url(try a.requirePos(1, "bundle"))
        let t = try MusicLibrary.find(try a.requirePos(2, "track id or title"))
        var m = try MusicLibrary.spec(for: t)
        var p = try ProjectIO.load(b)
        // Keep the bundle self-contained.
        let base = Studio.locate(b).base
        let src = URL(fileURLWithPath: m.path!)
        let dst = base.appendingPathComponent("sources/music." + src.pathExtension)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        m.path = "sources/music.\(src.pathExtension)"
        m.volume = a.double("volume") ?? (p.audio.voiceover.isEmpty ? 0.6 : 0.2)
        if let o = a.double("offset") { m.offset = o }
        p.audio.music = m
        if p.audio.mode == "voiceover" || p.audio.mode == "none" { Log.warn("audio.mode is \(p.audio.mode) — set audio.mode=music or both to hear it") }
        try ProjectIO.save(p, to: b)
        emit(["ok": true, "track": trackJSON(t), "bpm": m.bpm ?? NSNull(), "offset": m.offset, "credit": t.license.credit ?? NSNull()])
    case "library":
        let ls = MusicLibrary.licensed()
        emit(["ok": true, "folder": MusicLibrary.licensedFolder?.path ?? NSNull(), "tracks": ls.map(trackJSON),
              "howto": "Put tracks from a subscription you hold (Epidemic Sound, Artlist, Musicbed...) in this folder. Name a subfolder after the service, or add <file>.license.json: {\"title\",\"artist\",\"source\",\"license\",\"credit\"?,\"bpm\"?,\"mood\"?}."])
    case "analyze":
        let target = url(try a.requirePos(1, "music file or bundle"))
        if target.pathExtension == ProjectIO.bundleExtension || FileManager.default.fileExists(atPath: target.appendingPathComponent("project.json").path) {
            var p = try ProjectIO.load(target)
            guard let mp = p.audio.music.path else { throw fail("project has no music") }
            let r = try BeatDetect.analyze(Backgrounds.resolve(mp, Studio.locate(target).base))
            p.audio.music.bpm = r.bpm; p.audio.music.beatOffset = r.firstBeat
            try ProjectIO.save(p, to: target)
            emit(["ok": true, "bpm": r.bpm, "firstBeat": r.firstBeat, "confidence": r.confidence])
        } else {
            let r = try BeatDetect.analyze(target)
            emit(["ok": true, "bpm": r.bpm, "firstBeat": r.firstBeat, "confidence": r.confidence])
        }
    case "generate":
        var g = MusicGenSpec()
        g.mood = a.str("mood") ?? g.mood
        guard MusicGen.moods.contains(g.mood) else { throw fail("mood must be one of \(MusicGen.moods.joined(separator: ", "))") }
        g.bpm = a.double("bpm"); g.key = a.str("key"); g.seed = a.int("seed") ?? g.seed; g.energy = a.double("energy") ?? g.energy
        if let bpath = a.pos(1) {
            let b = url(bpath)
            let studio = try Studio(url: b)
            let base = Studio.locate(b).base
            let out = base.appendingPathComponent("sources/music.wav")
            let r = try MusicGen.render(g, duration: a.double("duration") ?? studio.outputDuration, to: out)
            var p = try ProjectIO.load(b)
            p.audio.music = MusicSpec()
            p.audio.music.path = "sources/music.wav"; p.audio.music.bpm = r.bpm; p.audio.music.beatOffset = 0
            p.audio.music.offset = 0; p.audio.music.generate = g
            p.audio.music.license = MusicLicense(name: "Generated (Pretty Studio)", source: "generated")
            p.audio.music.volume = a.double("volume") ?? (p.audio.voiceover.isEmpty ? 0.6 : 0.2)
            try ProjectIO.save(p, to: b)
            emit(["ok": true, "music": out.path, "bpm": r.bpm, "key": r.key, "bars": r.bars, "duration": r.duration, "mood": r.mood])
        } else {
            let out = a.str("out").map(url) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("\(g.mood)-\(Int(g.bpm ?? MusicGen.style(g.mood).bpm))bpm.wav")
            let r = try MusicGen.render(g, duration: a.double("duration") ?? 30, to: out)
            emit(["ok": true, "music": out.path, "bpm": r.bpm, "key": r.key, "bars": r.bars, "duration": r.duration, "mood": r.mood])
        }
    default:
        try cmdMusic(a) // pretty music <bundle> song.m4a
    }
}

/// pretty credits <bundle> [-p preset]: the credit lines this video must carry.
func cmdCredits(_ a: Args) throws {
    let studio = try Studio(url: try bundleArg(a))
    let c = studio.credits(preset: a.str("preset") ?? studio.project.export.preset)
    emit(["ok": true, "credits": c.lines, "text": c.text, "onScreen": c.onScreen ?? NSNull()])
}

// MARK: broll

/// pretty broll "prompt" [--provider veo|sora|fal] [--model M] [--seconds 6] [--aspect 9:16] [--image still.png] [--treatment keynote] [--raw] [-o dir]
func cmdBroll(_ a: Args) throws {
    let prompt = try a.requirePos(0, "what the shot shows")
    guard let provider = a.str("provider") ?? VideoAI.available().first else {
        throw fail("no video provider set up — `pretty keys set gemini` (Veo), `openai` (Sora) or `fal`, or Pretty Studio → Settings → Video")
    }
    var r = VideoAI.Request(prompt: prompt, provider: provider)
    r.model = a.str("model"); r.seconds = a.int("seconds") ?? 6; r.aspect = a.str("aspect") ?? "9:16"
    r.image = a.str("image").map(url)
    if !a.has("raw") { let st = VideoAI.styled(prompt, treatment: a.str("treatment").flatMap(Treatment.named)); r.prompt = st.0; r.negative = st.1 }
    let dir: URL
    if let o = a.str("out") { dir = url(o) } else {
        dir = try Home.videoDir(project: a.str("project") ?? "pretty-studio").deletingLastPathComponent().appendingPathComponent("generated/broll")
    }
    let clip = try VideoAI.generate(r, to: dir)
    emit(["ok": true, "file": clip.file, "provider": clip.provider, "model": clip.model, "seconds": clip.seconds,
          "use": "In a storyboard beat: \"broll\": {\"prompt\": ...} (cached by prompt), or a scene with \"background\": \"clip:\(clip.file)\"",
          "note": "AI-generated footage: check it frame by frame (hands, faces, physics) before using it, and disclose AI content where the platform requires."])
}
