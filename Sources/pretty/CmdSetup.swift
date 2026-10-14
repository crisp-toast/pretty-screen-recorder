import Foundation
import PrettyCore

/// pretty setup [status] | setup voice --provider P --voice NAME [--model M] | setup music [--licensed DIR] [--incompetech on|off] [--generated on|off] [--credits on|off]
func cmdSetup(_ a: Args) throws {
    var s = AppSettings.load()
    switch a.pos(0) ?? "status" {
    case "status":
        let v = s.voice
        let resolved = Narrator.resolve(nil, settings: s)
        var voice: [String: Any] = ["provider": v.provider, "ready": resolved != nil]
        voice["voice"] = orNull(v.voiceName ?? v.voiceId)
        voice["model"] = orNull(v.model ?? Narrator.defaultModel[v.provider])
        voice["detail"] = resolved.map { "narration with \($0.voiceName) (\($0.provider), \($0.model))" } ?? Narrator.unavailableReason(nil)
        var keys: [[String: Any]] = []
        for p in ["elevenlabs", "openai", "gemini", "fal"] {
            let env = ProcessInfo.processInfo.environment[["openai": "OPENAI_API_KEY", "gemini": "GEMINI_API_KEY", "fal": "FAL_KEY"][p] ?? "ELEVENLABS_API_KEY"] != nil
            keys.append(["provider": p, "stored": Secrets.get(p) != nil, "masked": orNull(Secrets.masked(p)), "env": env])
        }
        var music: [String: Any] = ["incompetech": s.music.useIncompetech, "licensedTracks": MusicLibrary.licensed().count,
                                    "generatedFallback": s.music.useGenerated, "creditsOnScreen": s.music.creditsOnScreen, "library": Paths.musicLibrary.path]
        music["licensedFolder"] = orNull(MusicLibrary.licensedFolder?.path)
        voice["elevenlabsPlan"] = orNull(Score.tier())
        voice["planNote"] = orNull(Score.tierNote())
        let next = resolved == nil ? "Open Pretty Studio for guided setup, or `pretty keys set elevenlabs` then `pretty setup voice --provider elevenlabs --voice NAME`" : "ready"
        let tools = Shots.defaultTools
        let video: [String: Any] = ["providers": VideoAI.available(), "blender": orNull(tools?.blender)]
        emit(["ok": true, "settings": AppSettings.file.path, "onboardingComplete": s.onboardingComplete, "voice": voice, "keys": keys, "video": video,
              "music": music, "projectsRoot": orNull(Home.projectsRoot?.path), "next": next])
    case "voice":
        if let p = a.str("provider") {
            guard p == "none" || Narrator.providers.contains(p) else { throw fail("provider must be none, elevenlabs or openai") }
            s.voice.provider = p
        }
        if let m = a.str("model") { s.voice.model = m }
        if let x = a.double("speed") { s.voice.speed = x }
        if let x = a.double("style") { s.voice.style = x }
        if let x = a.double("stability") { s.voice.stability = x }
        if let x = a.str("instructions") { s.voice.instructions = x }
        if let name = a.str("voice") {
            let vs = try Narrator.voices(provider: s.voice.provider, cachedOK: true)
            guard let v = vs.first(where: { $0.id == name }) ?? vs.first(where: { $0.name.lowercased() == name.lowercased() })
                    ?? vs.first(where: { $0.name.lowercased().hasPrefix(name.lowercased()) }) else {
                throw fail("no \(s.voice.provider) voice called '\(name)' — see `pretty voice list`")
            }
            s.voice.voiceId = v.id; s.voice.voiceName = v.name
        }
        try s.save()
        let voice: [String: Any] = ["provider": s.voice.provider, "voice": orNull(s.voice.voiceName), "model": orNull(s.voice.model)]
        emit(["ok": true, "voice": voice, "ready": Narrator.resolve(nil, settings: s) != nil])
    case "music":
        func flag(_ k: String) -> Bool? { a.str(k).map { ["on", "true", "yes", "1"].contains($0.lowercased()) } }
        if let d = a.str("licensed") { s.music.licensedFolder = d == "none" ? nil : url(d).path }
        if let x = flag("incompetech") { s.music.useIncompetech = x }
        if let x = flag("generated") { s.music.useGenerated = x }
        if let x = flag("credits") { s.music.creditsOnScreen = x }
        try s.save()
        let music: [String: Any] = ["incompetech": s.music.useIncompetech, "licensedFolder": orNull(s.music.licensedFolder),
                                    "generatedFallback": s.music.useGenerated, "creditsOnScreen": s.music.creditsOnScreen]
        emit(["ok": true, "music": music])
    case "done":
        s.onboardingComplete = true
        try s.save()
        emit(["ok": true])
    default:
        throw fail("setup subcommands: status | voice | music")
    }
}

/// pretty keys set <provider> (key on stdin) | test [provider] | remove <provider> | status
func cmdKeys(_ a: Args) throws {
    switch a.pos(0) ?? "status" {
    case "set", "add":
        let p = try a.requirePos(1, "service (elevenlabs | openai | gemini | fal)")
        guard ["elevenlabs", "openai", "gemini", "fal"].contains(p) else { throw fail("service must be elevenlabs, openai (voice + Sora), gemini (Veo) or fal") }
        let tty = isatty(STDIN_FILENO) != 0
        var key: String
        if tty {
            // Hidden prompt; the key never appears in argv, shell history or logs.
            guard let k = getpass("Paste your \(["openai": "OpenAI", "gemini": "Google Gemini", "fal": "fal.ai"][p] ?? "ElevenLabs") API key (hidden): ") else { throw fail("no key entered") }
            key = String(cString: k)
        } else {
            key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        key = Secrets.sanitize(key)
        guard !key.isEmpty else { throw fail("no key on stdin") }
        let detail = try VideoAI.test(account: p, key: key)
        try Secrets.set(p, key: key)
        var s = AppSettings.load()
        if s.voice.provider == "none" && Narrator.providers.contains(p) { s.voice.provider = p; try s.save() }
        let next = s.voice.voiceId == nil ? "choose a voice: pretty voice list, then pretty setup voice --voice NAME (or use the app)" : "ready"
        emit(["ok": true, "provider": p, "stored": "login Keychain (service \"\(Secrets.service)\")", "masked": orNull(Secrets.masked(p)), "check": detail, "next": next])
    case "test":
        let ps = a.pos(1).map { [$0] } ?? ["elevenlabs", "openai", "gemini", "fal"].filter { Secrets.get($0) != nil }
        var out: [[String: Any]] = []
        for p in ps {
            guard let k = Secrets.get(p) else { out.append(["provider": p, "ok": false, "error": "no key stored"]); continue }
            do { out.append(["provider": p, "ok": true, "detail": try VideoAI.test(account: p, key: k)]) }
            catch { out.append(["provider": p, "ok": false, "error": "\(error)"]) }
        }
        emit(["ok": out.allSatisfy { ($0["ok"] as? Bool) == true } && !out.isEmpty, "results": out])
    case "remove", "rm", "delete":
        let p = try a.requirePos(1, "provider")
        Secrets.remove(p)
        emit(["ok": true, "removed": p, "stillSet": orNull(Secrets.get(p) != nil ? "an environment variable still provides a key" : nil)])
    case "status":
        let keys: [[String: Any]] = ["elevenlabs", "openai", "gemini", "fal"].map { ["provider": $0, "stored": Secrets.get($0) != nil, "masked": orNull(Secrets.masked($0))] }
        emit(["ok": true, "keys": keys])
    default:
        throw fail("keys subcommands: set <provider> | test [provider] | remove <provider> | status")
    }
}

/// JSON null for missing values.
func orNull(_ v: Any?) -> Any { v ?? NSNull() }
