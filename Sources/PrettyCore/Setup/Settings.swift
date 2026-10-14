import Foundation
import Security

/// User-level setup shared by the app (onboarding / Settings) and the CLI (agents).
/// Lives on the internal disk (~/Library/Application Support/Pretty Studio/settings.json);
/// secrets never do — they go to the Keychain (see `Secrets`).
public struct AppSettings: Codable, Equatable {
    public var onboardingComplete = false
    /// Where `<project>/video` folders go (default: Master Storage/Projects when mounted).
    public var projectsRoot: String? = nil
    public var voice = VoiceSettings()
    public var music = MusicSettings()
    public init() {}

    enum CodingKeys: String, CodingKey { case onboardingComplete, projectsRoot, voice, music }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = AppSettings()
        onboardingComplete = try c.v(.onboardingComplete, z.onboardingComplete)
        projectsRoot = try c.decodeIfPresent(String.self, forKey: .projectsRoot)
        voice = try c.v(.voice, z.voice); music = try c.v(.music, z.music)
    }

    public static var directory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pretty Studio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    public static var file: URL { directory.appendingPathComponent("settings.json") }

    public static func load() -> AppSettings {
        guard let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }

    public func save() throws {
        try prettyJSON(self).write(to: AppSettings.file, options: .atomic)
    }
}

/// Narration voice. There is deliberately no "system voice" option: narration is either a
/// studio-grade neural voice (ElevenLabs, OpenAI) or nothing — on-screen type carries the story.
public struct VoiceSettings: Codable, Equatable {
    /// none | elevenlabs | openai
    public var provider = "none"
    public var voiceId: String? = nil
    public var voiceName: String? = nil
    /// ElevenLabs: eleven_v4 (default, most natural), eleven_multilingual_v2. OpenAI: gpt-4o-mini-tts.
    public var model: String? = nil
    /// ElevenLabs voice settings.
    public var stability = 0.45
    public var similarity = 0.8
    public var style = 0.25
    public var speed = 1.0
    /// OpenAI delivery direction, e.g. "Warm, confident product narrator. Smile in the voice."
    public var instructions: String? = nil
    public init() {}

    enum CodingKeys: String, CodingKey { case provider, voiceId, voiceName, model, stability, similarity, style, speed, instructions }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = VoiceSettings()
        provider = try c.v(.provider, z.provider); voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId)
        voiceName = try c.decodeIfPresent(String.self, forKey: .voiceName); model = try c.decodeIfPresent(String.self, forKey: .model)
        stability = try c.v(.stability, z.stability); similarity = try c.v(.similarity, z.similarity)
        style = try c.v(.style, z.style); speed = try c.v(.speed, z.speed)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions)
    }

    public var isConfigured: Bool { provider != "none" && voiceId != nil && Secrets.get(provider) != nil }
}

public struct MusicSettings: Codable, Equatable {
    /// Your licensed library (Epidemic Sound / Artlist / Musicbed downloads, with license sidecars).
    public var licensedFolder: String? = nil
    /// An original score composed for each video with ElevenLabs Music, following the edit's sections.
    public var useComposed = true
    /// Kevin MacLeod's catalog (incompetech.com), CC BY 4.0 — widely known but can read as stock music;
    /// a fallback when nothing else is available.
    public var useIncompetech = false
    /// Procedurally generated beds (exact beat grid) — off by default.
    public var useGenerated = false
    /// Show the music credit on screen at the end when the license asks for attribution.
    public var creditsOnScreen = true
    /// Sound design (whooshes, impacts, shimmers) from ElevenLabs sound effects.
    public var useSfx = true
    public init() {}

    enum CodingKeys: String, CodingKey { case licensedFolder, useComposed, useIncompetech, useGenerated, creditsOnScreen, useSfx, catalogV2 }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = MusicSettings()
        licensedFolder = try c.decodeIfPresent(String.self, forKey: .licensedFolder)
        useComposed = try c.v(.useComposed, z.useComposed)
        // Settings saved before 1.2 defaulted the catalog on; it's opt-in now.
        let migrated = try c.decodeIfPresent(Bool.self, forKey: .catalogV2) ?? false
        useIncompetech = migrated ? try c.v(.useIncompetech, z.useIncompetech) : false
        useGenerated = try c.v(.useGenerated, z.useGenerated)
        creditsOnScreen = try c.v(.creditsOnScreen, z.creditsOnScreen)
        useSfx = try c.v(.useSfx, z.useSfx)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(licensedFolder, forKey: .licensedFolder)
        try c.encode(useComposed, forKey: .useComposed); try c.encode(useIncompetech, forKey: .useIncompetech)
        try c.encode(useGenerated, forKey: .useGenerated); try c.encode(creditsOnScreen, forKey: .creditsOnScreen)
        try c.encode(useSfx, forKey: .useSfx); try c.encode(true, forKey: .catalogV2)
    }
}

/// API keys in the login Keychain (service "Pretty Studio", account = provider).
/// Items are written with an any-application ACL (`security -A`) so agents running the CLI on a
/// headless Mac never hit a Keychain prompt. Environment variables override (ELEVENLABS_API_KEY,
/// OPENAI_API_KEY). Keys never touch disk files, argv, or logs.
public enum Secrets {
    public static let service = "Pretty Studio"
    static let envNames = ["elevenlabs": "ELEVENLABS_API_KEY", "openai": "OPENAI_API_KEY", "gemini": "GEMINI_API_KEY", "fal": "FAL_KEY"]

    private static var memo: [String: String] = [:]
    private static let memoLock = NSLock()

    /// Read through Apple's `security` tool: the item's partition list trusts Apple tools, so the
    /// ad-hoc-signed CLI and app never trigger a Keychain approval prompt (headless agents can't click one).
    public static func get(_ account: String) -> String? {
        if let env = envNames[account], let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        memoLock.lock(); defer { memoLock.unlock() }
        if let m = memo[account] { return m.isEmpty ? nil : m }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        memo[account] = s
        return s.isEmpty ? nil : s
    }

    static func forget(_ account: String) { memoLock.lock(); memo[account] = nil; memoLock.unlock() }

    /// API keys are plain ASCII. Pasting from a web page can bring along invisible characters
    /// (zero-width spaces, non-breaking spaces, quotes, "Bearer "), which make a good key fail.
    public static func sanitize(_ key: String) -> String {
        // Real keys never contain quotes or backslashes; dropping them also keeps the `security -i`
        // command line (which quotes the key) from ever being split into extra arguments.
        var k = String(String.UnicodeScalarView(key.unicodeScalars.filter { $0.isASCII && $0.value > 32 && $0.value < 127 && !"\"'`\\".unicodeScalars.contains($0) }))
        for p in ["Bearer", "xi-api-key:", "ELEVENLABS_API_KEY=", "OPENAI_API_KEY=", "GEMINI_API_KEY=", "FAL_KEY="] where k.hasPrefix(p) { k = String(k.dropFirst(p.count)) }
        return k
    }

    /// A key's shape, safe to show: length and first three characters.
    public static func shape(_ key: String) -> String { "\(key.count)-character key starting with \u{201C}\(key.prefix(3))\u{201D}" }

    /// Store via `security -i` so the key goes over stdin, never through argv.
    public static func set(_ account: String, key: String) throws {
        let clean = sanitize(key)
        guard envNames[account] != nil else { throw fail("unknown key account \(account)") }
        guard !clean.isEmpty, !clean.contains("\""), !clean.contains("\n") else { throw fail("that doesn't look like an API key") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let label = "Pretty Studio — \(account) API key"
        let cmd = "add-generic-password -U -A -a \"\(account)\" -s \"\(service)\" -l \"\(label)\" -w \"\(clean)\"\n"
        input.fileHandleForWriting.write(Data(cmd.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        forget(account)
        guard p.terminationStatus == 0, get(account) != nil else { throw fail("couldn't save the key to the Keychain") }
    }

    public static func remove(_ account: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", service, "-a", account]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        forget(account)
    }

    /// For display only: "sk_…a1b2".
    public static func masked(_ account: String) -> String? {
        guard let k = get(account), k.count > 8 else { return nil }
        return "\(k.prefix(3))…\(k.suffix(4))"
    }
}
