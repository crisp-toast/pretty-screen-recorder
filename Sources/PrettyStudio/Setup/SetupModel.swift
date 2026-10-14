import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import PrettyCore

/// State behind the onboarding window and Settings: environment checks, the narration voice
/// (provider, Keychain key, voice, model), music sources, and agent tooling.
@MainActor
final class SetupModel: ObservableObject {
    // MARK: Settings (saved as they change)

    @Published var settings: AppSettings { didSet { if settings != oldValue { try? settings.save() } } }

    init() { settings = AppSettings.load() }

    // MARK: Essentials

    struct Check: Identifiable {
        enum State { case ok, warn, missing, checking }
        let id: String
        var title: String
        var detail: String
        var state: State
        var symbol: String
        var fix: String? = nil
        var fixCommand: String? = nil
    }

    @Published var checks: [Check] = []
    @Published var checking = false

    func runChecks() {
        checking = true
        let projects = projectsFolder
        Task.detached {
            var cs: [Check] = []
            let ff = Media.which("ffmpeg")
            cs.append(Check(id: "ffmpeg", title: "ffmpeg", detail: ff.map { "Encodes and mixes video — \($0)" } ?? "Encodes and mixes every video. Install it with Homebrew.",
                            state: ff != nil ? .ok : .missing, symbol: "film.stack", fix: ff == nil ? "Copy Install Command" : nil, fixCommand: "brew install ffmpeg"))
            let node = Media.which("node")
            cs.append(Check(id: "node", title: "Node.js", detail: node.map { "Drives the browser for web recordings — \($0)" } ?? "Drives the browser for web recordings.",
                            state: node != nil ? .ok : .missing, symbol: "chevron.left.forwardslash.chevron.right", fix: node == nil ? "Copy Install Command" : nil, fixCommand: "brew install node"))
            let browsers = SetupModel.browsers()
            cs.append(Check(id: "browser", title: "Browser", detail: browsers.isEmpty ? "Chrome, Chromium or Edge records web demos." : "Records web demos with \(browsers.joined(separator: ", "))",
                            state: browsers.isEmpty ? .missing : .ok, symbol: "safari", fix: browsers.isEmpty ? "Get Chrome" : nil, fixCommand: "https://www.google.com/chrome/"))
            let screen = CGPreflightScreenCaptureAccess()
            cs.append(Check(id: "screen", title: "Screen Recording", detail: screen ? "Allowed — Pretty Studio can record your Mac's screen." : "Only needed to record your Mac's own screen. Web and simulator recordings work without it.",
                            state: screen ? .ok : .warn, symbol: "rectangle.dashed.badge.record", fix: screen ? nil : "Open Privacy Settings",
                            fixCommand: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDir) && isDir.boolValue
            cs.append(Check(id: "projects", title: "Projects folder", detail: projects.path, state: exists ? .ok : .warn, symbol: "folder", fix: "Choose…"))
            let simctl = FileManager.default.fileExists(atPath: "/Applications/Xcode.app") || FileManager.default.fileExists(atPath: "/Applications/Xcode-beta.app")
            cs.append(Check(id: "xcode", title: "iOS Simulator", detail: simctl ? "Xcode is installed — simulator recordings are available." : "Optional: install Xcode to record iPhone apps in the Simulator.",
                            state: simctl ? .ok : .warn, symbol: "iphone", fix: nil))
            let result = cs
            await MainActor.run { self.checks = result; self.checking = false }
        }
    }

    nonisolated static func browsers() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for (name, app) in [("Chrome", "Google Chrome.app"), ("Edge", "Microsoft Edge.app"), ("Chromium", "Chromium.app")] {
            if fm.fileExists(atPath: "/Applications/\(app)") || fm.fileExists(atPath: NSHomeDirectory() + "/Applications/\(app)") { out.append(name) }
        }
        let pw = NSHomeDirectory() + "/Library/Caches/ms-playwright"
        if let items = try? fm.contentsOfDirectory(atPath: pw), items.contains(where: { $0.hasPrefix("chromium") }) { out.append("Playwright Chromium") }
        return out
    }

    var projectsFolder: URL {
        if let p = settings.projectsRoot, !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        if FileManager.default.fileExists(atPath: Paths.masterStorage + "/Projects") { return URL(fileURLWithPath: Paths.masterStorage + "/Projects") }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pretty Studio")
    }

    func chooseProjectsFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Use Folder"
        p.message = "Recordings and renders go in <project>/video inside this folder."
        p.directoryURL = projectsFolder
        if p.runModal() == .OK, let u = p.url { settings.projectsRoot = u.path; runChecks() }
    }

    func perform(_ c: Check) {
        if c.id == "projects" { chooseProjectsFolder(); return }
        guard let cmd = c.fixCommand else { return }
        if cmd.hasPrefix("http") || cmd.hasPrefix("x-apple") {
            if let u = URL(string: cmd) { NSWorkspace.shared.open(u) }
            if c.id == "screen" { _ = CGRequestScreenCaptureAccess() }
        } else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            toast = "Copied “\(cmd)” — paste it into Terminal."
        }
    }

    @Published var toast: String? = nil

    // MARK: Voice

    enum KeyState: Equatable { case none, verifying, valid(String), invalid(String) }

    @Published var keyInput = ""
    @Published var keyState: KeyState = .none
    @Published var voices: [Narrator.VoiceInfo] = []
    @Published var models: [String] = []
    @Published var loadingVoices = false
    @Published var voiceSearch = ""
    @Published var playingID: String? = nil
    @Published var sampleText = "Scan a card, and its price is already there."
    @Published var synthesizing = false
    private var player: AVPlayer?
    private var endObserver: Any?

    var provider: String {
        get { settings.voice.provider }
        set {
            guard newValue != settings.voice.provider else { return }
            settings.voice.provider = newValue
            settings.voice.voiceId = nil; settings.voice.voiceName = nil; settings.voice.model = nil
            keyInput = ""; voices = []; models = []
            refreshVoiceState()
        }
    }

    var hasStoredKey: Bool { Narrator.providers.contains(provider) && Secrets.get(provider) != nil }

    func refreshVoiceState() {
        guard Narrator.providers.contains(provider) else { keyState = .none; return }
        if let m = Secrets.masked(provider) {
            keyState = .valid(m)
            loadVoices()
        } else { keyState = .none }
    }

    func verifyKey() {
        let key = Secrets.sanitize(keyInput)
        let p = provider
        guard !key.isEmpty else { return }
        keyState = .verifying
        Task.detached {
            do {
                _ = try Narrator.test(provider: p, key: key)
                try Secrets.set(p, key: key)
                await MainActor.run {
                    self.keyInput = ""
                    self.keyState = .valid(Secrets.masked(p) ?? "saved")
                    self.loadVoices()
                }
            } catch {
                await MainActor.run { self.keyState = .invalid("\(error)") }
            }
        }
    }

    func removeKey() {
        Secrets.remove(provider)
        settings.voice.voiceId = nil; settings.voice.voiceName = nil
        voices = []; keyState = .none
    }

    func loadVoices() {
        let p = provider
        loadingVoices = true
        Task.detached {
            let vs = (try? Narrator.voices(provider: p, cachedOK: false)) ?? []
            let ms = Narrator.models(provider: p)
            await MainActor.run {
                self.loadingVoices = false
                self.voices = SetupModel.ranked(vs)
                self.models = ms
                if self.settings.voice.voiceId == nil || !vs.contains(where: { $0.id == self.settings.voice.voiceId }),
                   let pick = p == "openai" ? vs.first : Narrator.suggestedVoice(vs) {
                    self.choose(pick)
                }
                if self.settings.voice.model == nil { self.settings.voice.model = ms.first }
            }
        }
    }

    nonisolated static func ranked(_ vs: [Narrator.VoiceInfo]) -> [Narrator.VoiceInfo] {
        func score(_ v: Narrator.VoiceInfo) -> Int {
            let use = (v.labels["use_case"] ?? v.labels["use case"] ?? "").lowercased()
            var s = 0
            if ["narrat", "advert", "social", "informative", "conversational"].contains(where: { use.contains($0) }) { s += 10 }
            if v.category == "premade" { s += 3 }
            if v.category == "cloned" || v.category == "professional" { s += 5 } // the user's own voices
            return s
        }
        return vs.sorted { score($0) > score($1) }
    }

    var filteredVoices: [Narrator.VoiceInfo] {
        let q = voiceSearch.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return voices }
        return voices.filter { v in
            ([v.name, v.description ?? ""] + Array(v.labels.values)).joined(separator: " ").lowercased().contains(q)
        }
    }

    func choose(_ v: Narrator.VoiceInfo) {
        settings.voice.voiceId = v.id
        settings.voice.voiceName = v.name
    }

    /// Play a voice: ElevenLabs' hosted preview, or a short line synthesized with your key.
    func preview(_ v: Narrator.VoiceInfo) {
        if playingID == v.id { stopPlayback(); return }
        if let s = v.previewURL, let u = URL(string: s) { play(u, id: v.id); return }
        sample(voice: v)
    }

    func sample(voice v: Narrator.VoiceInfo? = nil) {
        guard let key = Secrets.get(provider) else { return }
        let vid = v?.id ?? settings.voice.voiceId ?? (provider == "openai" ? "marin" : "")
        guard !vid.isEmpty else { return }
        let r = Narrator.Resolved(provider: provider, voiceId: vid, voiceName: v?.name ?? settings.voice.voiceName ?? vid,
                                  model: settings.voice.model ?? Narrator.defaultModel[provider]!, key: key,
                                  stability: settings.voice.stability, similarity: settings.voice.similarity, style: settings.voice.style,
                                  speed: settings.voice.speed, instructions: settings.voice.instructions)
        let text = sampleText
        synthesizing = true
        playingID = vid
        Task.detached {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("pretty-voice-sample")
            let result = Result { try Narrator.synthesize(text, voice: r, to: out) }
            await MainActor.run {
                self.synthesizing = false
                switch result {
                case .success(let sp): self.play(URL(fileURLWithPath: sp.file), id: vid)
                case .failure(let e): self.playingID = nil; self.toast = "\(e)"
                }
            }
        }
    }

    func play(_ u: URL, id: String) {
        stopPlayback()
        let item = AVPlayerItem(url: u)
        let p = AVPlayer(playerItem: item)
        player = p
        playingID = id
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playingID = nil }
        }
        p.play()
    }

    func stopPlayback() {
        player?.pause(); player = nil; playingID = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }

    static func modelName(_ m: String) -> String {
        switch m {
        case "eleven_v4": return "Eleven v4 — most natural"
        case "eleven_v3": return "Eleven v3 — expressive"
        case "eleven_multilingual_v2": return "Multilingual v2 — steady"
        case "eleven_flash_v2_5": return "Flash v2.5 — fastest"
        case "eleven_turbo_v2_5": return "Turbo v2.5"
        case "gpt-4o-mini-tts": return "GPT-4o mini TTS"
        default: return m
        }
    }

    // MARK: Music

    @Published var famousTracks: [MusicLibrary.Track] = []
    @Published var licensedCount = 0

    func loadMusic() {
        Task.detached {
            let picks = ["Carefree", "Life of Riley", "Wallpaper", "Inspired", "Funky Chunk", "Happy Alley"]
            let all = (try? MusicLibrary.incompetech()) ?? []
            let tracks = picks.compactMap { p in all.first { $0.title == p } }
            let n = MusicLibrary.licensed().count
            await MainActor.run { self.famousTracks = tracks; self.licensedCount = n }
        }
    }

    func chooseLicensedFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Use Folder"
        p.message = "Music you've licensed (Epidemic Sound, Artlist, Musicbed…). Subfolders named after the service are recognized."
        if p.runModal() == .OK, let u = p.url { settings.music.licensedFolder = u.path; loadMusic() }
    }

    // MARK: Video & 3D

    @Published var videoKeyInput: [String: String] = [:]
    @Published var videoKeyState: [String: KeyState] = [:]
    @Published var blenderPath: String? = nil
    @Published var planNote: String? = nil

    func refreshVideo() {
        let tools = Shots.Tools.find(script: URL(fileURLWithPath: "/dev/null"))
        blenderPath = tools.blender
        for a in ["gemini", "openai", "fal"] {
            if let m = Secrets.masked(a) { videoKeyState[a] = .valid(m) } else if videoKeyState[a] == nil || videoKeyState[a] == .verifying { videoKeyState[a] = KeyState.none }
        }
        Task.detached {
            let note = Score.tierNote()
            await MainActor.run { self.planNote = note }
        }
    }

    func connectVideo(_ account: String) {
        let key = Secrets.sanitize(videoKeyInput[account] ?? "")
        guard !key.isEmpty else { return }
        videoKeyState[account] = .verifying
        Task.detached {
            do {
                _ = try VideoAI.test(account: account, key: key)
                try Secrets.set(account, key: key)
                await MainActor.run { self.videoKeyInput[account] = ""; self.videoKeyState[account] = .valid(Secrets.masked(account) ?? "saved") }
            } catch {
                await MainActor.run { self.videoKeyState[account] = .invalid("\(error)") }
            }
        }
    }

    func removeVideoKey(_ account: String) { Secrets.remove(account); videoKeyState[account] = KeyState.none }

    // MARK: Agents

    var bundledCLI: URL? { Bundle.main.url(forAuxiliaryExecutable: "pretty") }
    var cliLink: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/pretty") }
    var skillFile: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.claude/skills/pretty-studio/SKILL.md") }

    var cliInstalled: String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cliLink.path) else { return nil }
        return (try? fm.destinationOfSymbolicLink(atPath: cliLink.path)) ?? cliLink.path
    }
    var skillInstalled: Bool { FileManager.default.fileExists(atPath: skillFile.path) }
    @Published var pathHasLocalBin = true

    func checkShellPath() {
        Task.detached {
            let shellPath = (try? Media.run("/bin/zsh", ["-lc", "echo $PATH"]))?.out ?? ""
            let ok = shellPath.contains("/.local/bin")
            await MainActor.run { self.pathHasLocalBin = ok }
        }
    }

    @Published var agentsVersion = 0 // bump to refresh

    func installCLI() {
        guard let cli = bundledCLI else { toast = "This build has no bundled command-line tool."; return }
        do {
            try FileManager.default.createDirectory(at: cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? cliLink.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path)) != nil {
                try FileManager.default.removeItem(at: cliLink)
            }
            try FileManager.default.createSymbolicLink(at: cliLink, withDestinationURL: cli)
            agentsVersion += 1
        } catch { toast = "Couldn't install: \(error.localizedDescription)" }
    }

    func installSkill() {
        let src = Bundle.main.resourceURL?.appendingPathComponent("docs/SKILL.md")
        do {
            guard let s = src, FileManager.default.fileExists(atPath: s.path) else { throw PrettyError.message("skill not bundled") }
            try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: skillFile)
            try FileManager.default.copyItem(at: s, to: skillFile)
            let codex = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/skills")
            if FileManager.default.fileExists(atPath: codex.path) {
                let link = codex.appendingPathComponent("pretty-studio")
                try? FileManager.default.removeItem(at: link)
                try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: skillFile.deletingLastPathComponent())
            }
            agentsVersion += 1
        } catch { toast = "Couldn't install the skill: \(error)" }
    }

    func copy(_ s: String, note: String = "Copied") {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        toast = note
    }

    func finish() {
        settings.onboardingComplete = true
        stopPlayback()
    }
}
