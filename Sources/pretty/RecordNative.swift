import Foundation
import PrettyCore
import AppKit

// MARK: - Recording state (one active recording at a time)

struct RecordingState: Codable {
    var bundle: String
    var pid: Int32
    var type: String
    var started: Double
    /// Epoch seconds of the first video frame (marks are relative to this).
    var t0: Double?
    var pointScale: Double?

    static var file: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pretty-studio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("recording.json")
    }
    static func load() -> RecordingState? {
        guard let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(RecordingState.self, from: d) else { return nil }
        if kill(s.pid, 0) != 0 { try? FileManager.default.removeItem(at: file); return nil } // stale
        return s
    }
    func save() { try? JSONEncoder().encode(self).write(to: RecordingState.file) }
    static func clear() { try? FileManager.default.removeItem(at: file) }
}

/// Run async work from synchronous CLI code while keeping the main run loop alive
/// (ScreenCaptureKit and the key event tap need it).
func runAsync<T>(_ f: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>?
    let done = DispatchSemaphore(value: 0)
    Task.detached { do { result = .success(try await f()) } catch { result = .failure(error) }; done.signal() }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
    return try result!.get()
}

/// Wait for duration or SIGINT/SIGTERM, keeping the run loop serviced.
func waitForStop(duration: Double?) {
    var stop = false
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let s1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main); s1.setEventHandler { stop = true }; s1.resume()
    let s2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main); s2.setEventHandler { stop = true }; s2.resume()
    let end = duration.map { Date().addingTimeInterval($0) }
    while !stop {
        if let end, Date() >= end { break }
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
}

/// Re-launch this command in its own session so it survives the caller (agents' shells).
func detachSelf(bundle: URL, type: String) throws {
    var argv = CommandLine.arguments.filter { $0 != "--detach" }
    if !argv.contains("--force") { argv.append("--force") } // target already validated by the parent
    // Pin the bundle path so parent and child agree.
    if !argv.contains("-o") && !argv.contains("--out") { argv += ["-o", bundle.path] }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("sources"), withIntermediateDirectories: true)
    let log = bundle.appendingPathComponent("sources/recorder.log").path
    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var pid: pid_t = 0
    let cargs = ([exe] + argv.dropFirst()).map { strdup($0) } + [nil]
    defer { cargs.forEach { free($0) } }
    let rc = posix_spawn(&pid, exe, &fa, &attr, cargs, environ)
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr)
    guard rc == 0 else { throw fail("could not start background recorder (\(rc))") }
    // Wait until the child reports it is recording (state file with its pid and t0).
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let s = RecordingState.load(), s.pid == pid, s.t0 != nil {
            emit(["ok": true, "recording": true, "type": type, "bundle": bundle.path, "pid": Int(pid),
                  "stop": "pretty record stop", "log": log])
            return
        }
        if kill(pid, 0) != 0 { break }
        usleep(100_000)
    }
    let tail = (try? String(contentsOfFile: log, encoding: .utf8))?.suffix(800) ?? ""
    throw fail("background recorder did not start: \(tail)")
}

// MARK: - record screen

func parseTarget(_ a: Args) throws -> ScreenRecorder.Target {
    if let w = a.str("window") {
        let parts = w.split(separator: ":", maxSplits: 1).map(String.init)
        return .window(app: parts[0], title: parts.count > 1 ? parts[1] : nil)
    }
    if let r = a.str("region") {
        let p = r.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 4 else { throw fail("--region x,y,w,h (points, display-local)") }
        return .region(CGRect(x: p[0], y: p[1], width: p[2], height: p[3]), display: a.int("display"))
    }
    return .display(a.int("display"))
}

func recordScreen(_ a: Args) throws {
    if let s = RecordingState.load() { throw fail("a recording is already running (\(s.type), pid \(s.pid)); `pretty record stop` first") }
    let target = try parseTarget(a)
    let name = a.str("name") ?? {
        if case .window(let app, _) = target { return "\(app) recording" }
        return "screen recording"
    }()
    let bundle = try Home.newBundleURL(name: name, project: a.str("project"), out: a.str("out"))
    try Home.prepareTarget(bundle, force: a.has("force"))
    if a.has("detach") { try detachSelf(bundle: bundle, type: "screen"); return }

    _ = NSApplication.shared // connect to the window server for cursor/screen APIs
    let sources = bundle.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let video = sources.appendingPathComponent("screen.mov")
    try? FileManager.default.removeItem(at: video)
    let rec = ScreenRecorder(target: target, out: video, fps: a.int("fps") ?? 60, systemAudio: a.has("system-audio"), mic: a.has("mic"))
    try runAsync { try await rec.start() }
    let startedEpoch = Date().timeIntervalSince1970
    RecordingState(bundle: bundle.path, pid: getpid(), type: "screen", started: startedEpoch, t0: startedEpoch, pointScale: nil).save()
    Log.info("recording screen → \(bundle.path)  (stop: Ctrl-C or `pretty record stop`)")
    waitForStop(duration: a.double("duration"))
    let r = try runAsync { try await rec.stop() }
    var events = r.events
    mergeMarks(into: &events, sources: sources, t0Epoch: startedEpoch, pointScale: r.pointScale, touch: false)
    try events.save(sources.appendingPathComponent("events.json"))

    var o = ProjectIO.NewOptions()
    o.video = video
    o.events = sources.appendingPathComponent("events.json")
    if case .window = target { o.kind = "window" } else { o.kind = "desktop" }
    o.name = name
    o.look = a.str("look"); o.preset = a.str("preset")
    o.compressIdle = a.has("compress-idle")
    try ProjectIO.create(at: bundle, o)
    var p = try ProjectIO.load(bundle)
    p.source.pointScale = r.pointScale
    if let t = r.title { p.source.title = t }
    if case .window = target {
        // Window captures already have their own chrome; round to match macOS windows.
        p.layout.corners = 0.012
    }
    try ProjectIO.save(p, to: bundle)
    try convertMarkers(bundle)
    RecordingState.clear()
    var extra: [String: Any] = ["recorded": true, "keysCaptured": r.keysCaptured]
    if !r.keysCaptured { extra["note"] = "keystrokes not captured (grant Input Monitoring to the host app, or log them with `pretty mark key`)" }
    try summarize(bundle, extra: extra)
}

// MARK: - record sim

func recordSim(_ a: Args) throws {
    if let s = RecordingState.load() { throw fail("a recording is already running (\(s.type), pid \(s.pid)); `pretty record stop` first") }
    let device = a.str("device") ?? "booted"
    let bundle = try Home.newBundleURL(name: a.str("name") ?? "simulator recording", project: a.str("project"), out: a.str("out"))
    try Home.prepareTarget(bundle, force: a.has("force"))
    if a.has("detach") { try detachSelf(bundle: bundle, type: "sim"); return }

    let sources = bundle.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let video = sources.appendingPathComponent("screen.mov")
    try? FileManager.default.removeItem(at: video)
    // simctl can't write to external volumes without a privacy prompt: capture to the internal
    // temp folder, then move the file into the bundle.
    let capture = FileManager.default.temporaryDirectory.appendingPathComponent("pretty-sim-\(UUID().uuidString.prefix(8)).mov")
    let cleanBar = !a.has("keep-status-bar")
    if cleanBar {
        // Marketing status bar: 9:41, full (not charging) battery, full signal.
        _ = try? Media.run("/usr/bin/xcrun", ["simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "discharging",
                                              "--batteryLevel", "100", "--cellularMode", "active", "--cellularBars", "4", "--wifiBars", "3", "--dataNetwork", "wifi"])
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["simctl", "io", device, "recordVideo", "--codec=h264", "--force", capture.path]
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = FileHandle.nullDevice
    var t0: Double? = nil
    var errText = ""
    errPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil; return }
        let s = String(decoding: d, as: UTF8.self)
        errText += s
        if t0 == nil && s.lowercased().contains("recording started") { t0 = Date().timeIntervalSince1970 }
    }
    try p.run()
    let deadline = Date().addingTimeInterval(15)
    while t0 == nil && p.isRunning && Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    guard p.isRunning else { throw fail("simctl recordVideo failed: \(errText.trimmingCharacters(in: .whitespacesAndNewlines)) — is a simulator booted?") }
    let start = t0 ?? Date().timeIntervalSince1970
    RecordingState(bundle: bundle.path, pid: getpid(), type: "sim", started: start, t0: start, pointScale: nil).save()
    Log.info("recording simulator \(device) → \(bundle.path)  (log taps with `pretty mark tap X Y`; stop with `pretty record stop`)")
    waitForStop(duration: a.double("duration"))
    p.interrupt()
    p.waitUntilExit()
    if cleanBar { _ = try? Media.run("/usr/bin/xcrun", ["simctl", "status_bar", device, "clear"]) }
    if FileManager.default.fileExists(atPath: capture.path) {
        try? FileManager.default.removeItem(at: video)
        try FileManager.default.moveItem(at: capture, to: video)
    }
    guard FileManager.default.fileExists(atPath: video.path), let probe = try? Media.probe(video), probe.width > 0 else {
        RecordingState.clear()
        throw fail("simulator video missing or empty")
    }
    let portraitRatio = Double(min(probe.width, probe.height)) / Double(max(probe.width, probe.height))
    let iPad = portraitRatio > 0.62
    let ps = iPad ? 2.0 : 3.0
    var events = InputEvents()
    events.width = Double(probe.width); events.height = Double(probe.height); events.pointScale = ps
    mergeMarks(into: &events, sources: sources, t0Epoch: start, pointScale: ps, touch: true)
    try events.save(sources.appendingPathComponent("events.json"))

    var o = ProjectIO.NewOptions()
    o.video = video
    o.events = sources.appendingPathComponent("events.json")
    o.kind = "ios"
    o.name = a.str("name") ?? "simulator recording"
    o.look = a.str("look"); o.preset = a.str("preset")
    o.compressIdle = a.has("compress-idle")
    try ProjectIO.create(at: bundle, o)
    var proj = try ProjectIO.load(bundle)
    proj.source.pointScale = ps
    try ProjectIO.save(proj, to: bundle)
    try convertMarkers(bundle)
    RecordingState.clear()
    try summarize(bundle, extra: ["recorded": true, "device": device, "iPad": iPad])
}

// MARK: - stop / mark

func recordStop(_ a: Args) throws {
    guard let s = RecordingState.load() else { throw fail("no recording is running") }
    kill(s.pid, SIGINT)
    let deadline = Date().addingTimeInterval(180)
    while kill(s.pid, 0) == 0 && Date() < deadline { usleep(150_000) }
    let bundle = URL(fileURLWithPath: s.bundle)
    guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("project.json").path) else {
        let log = (try? String(contentsOf: bundle.appendingPathComponent("sources/recorder.log"), encoding: .utf8)) ?? ""
        throw fail("recording stopped but no project was built. Log tail: \(log.suffix(800))")
    }
    try summarize(bundle, extra: ["stopped": true])
}

/// pretty mark [bundle] tap X Y [--pixels|--norm] | key "cmd+k" | zoom [--duration S] [--rect x,y,w,h] [--level L] | caption "text" [--duration S]
func cmdMark(_ a: Args) throws {
    var pos = a.positionals
    var bundle: URL
    if let first = pos.first, first.hasSuffix(".prettystudio") || FileManager.default.fileExists(atPath: url(first).appendingPathComponent("sources").path) {
        bundle = url(first); pos.removeFirst()
    } else {
        guard let s = RecordingState.load() else { throw fail("no active recording; pass the bundle path") }
        bundle = URL(fileURLWithPath: s.bundle)
    }
    guard let kind = pos.first else { throw fail("mark what? tap | click | key | zoom | caption | title") }
    var m: [String: Any] = ["t": Date().timeIntervalSince1970, "type": kind]
    switch kind {
    case "tap", "click":
        guard pos.count >= 3, let x = Double(pos[1]), let y = Double(pos[2]) else { throw fail("mark tap X Y") }
        m["x"] = x; m["y"] = y
        m["units"] = a.has("pixels") ? "pixels" : a.has("norm") ? "norm" : (a.str("units") ?? "points")
        if let d = a.double("hold") { m["hold"] = d }
    case "key":
        guard pos.count >= 2 else { throw fail("mark key \"cmd+k\"") }
        m["combo"] = pos[1]
    case "zoom", "spotlight", "highlight":
        m["duration"] = a.double("duration") ?? 2.5
        if let r = a.rect("rect") { m["rect"] = ["x": r.x, "y": r.y, "w": r.w, "h": r.h] }
        if let l = a.double("level") { m["level"] = l }
    case "caption", "title":
        guard pos.count >= 2 else { throw fail("mark caption \"text\"") }
        m["text"] = pos[1]; m["duration"] = a.double("duration") ?? 2.5
    default: throw fail("unknown mark type \(kind)")
    }
    if let at = a.double("at") { m["t"] = at; m["relative"] = true }
    let file = bundle.appendingPathComponent("sources/marks.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = String(data: try JSONSerialization.data(withJSONObject: m), encoding: .utf8)! + "\n"
    if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try h.close() }
    else { try line.write(to: file, atomically: true, encoding: .utf8) }
    emit(["ok": true, "marked": kind, "bundle": bundle.path])
}

/// Fold `pretty mark` lines into the event log.
func mergeMarks(into ev: inout InputEvents, sources: URL, t0Epoch: Double, pointScale: Double, touch: Bool) {
    guard let text = try? String(contentsOf: sources.appendingPathComponent("marks.jsonl"), encoding: .utf8) else { return }
    for line in text.split(separator: "\n") {
        guard let m = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let type = m["type"] as? String,
              let tRaw = m["t"] as? Double else { continue }
        let t = (m["relative"] as? Bool) == true ? tRaw : tRaw - t0Epoch
        switch type {
        case "tap", "click":
            var x = m["x"] as? Double ?? 0, y = m["y"] as? Double ?? 0
            switch m["units"] as? String ?? "points" {
            case "norm": x *= ev.width; y *= ev.height
            case "pixels": break
            default: x *= pointScale; y *= pointScale
            }
            let hold = m["hold"] as? Double ?? 0.08
            ev.clicks.append(ClickEvent(t: t, x: x, y: y, up: t + hold, button: "left", touch: touch))
            if !touch { ev.mouse.append([t, x, y]) }
        case "key":
            let combo = (m["combo"] as? String ?? "").lowercased().split(separator: "+").map(String.init)
            guard let key = combo.last else { continue }
            let mods = combo.dropLast().map { ["command": "cmd", "meta": "cmd", "option": "opt", "alt": "opt", "control": "ctrl"][$0] ?? $0 }
            ev.keys.append(KeyEvent(t: t, key: key, mods: Array(mods)))
        default:
            var r: NRect? = nil
            if let d = m["rect"] as? [String: Double], let x = d["x"], let y = d["y"], let w = d["w"], let h = d["h"] { r = NRect(x: x, y: y, w: w, h: h) }
            ev.markers.append(Marker(t: t, type: type, duration: m["duration"] as? Double, level: m["level"] as? Double, rect: r, text: m["text"] as? String))
        }
    }
    ev.sortAll()
}
