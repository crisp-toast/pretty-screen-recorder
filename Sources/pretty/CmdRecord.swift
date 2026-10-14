import Foundation
import PrettyCore

func cmdRecord(_ a: Args) throws {
    let sub = try a.requirePos(0, "record type: web | screen | sim | stop")
    let rest = Args(Array(CommandLine.arguments.dropFirst(3)))
    switch sub {
    case "web": try recordWeb(rest)
    case "screen": try recordScreen(rest)
    case "sim", "simulator": try recordSim(rest)
    case "stop": try recordStop(rest)
    case "status": try recordStatus()
    default: throw fail("unknown record type '\(sub)' (web | screen | sim | stop | status)")
    }
}

// MARK: web

func recordWeb(_ a: Args) throws {
    let sbURL = url(try a.requirePos(0, "storyboard.json"))
    guard FileManager.default.fileExists(atPath: sbURL.path) else { throw fail("storyboard not found: \(sbURL.path)") }
    let sbData = try Data(contentsOf: sbURL)
    guard let sb = try JSONSerialization.jsonObject(with: sbData) as? [String: Any] else { throw fail("storyboard must be a JSON object") }
    let name = a.str("name") ?? (sb["name"] as? String) ?? sbURL.deletingPathExtension().deletingPathExtension().lastPathComponent
    guard let node = Media.which("node") else { throw fail("node not found (looked on PATH, NVM, Volta, asdf, Homebrew)") }
    if a.has("check") {
        // Dry run: execute every step quickly in the browser, no capture — catches bad selectors before a take.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pretty-check-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try Media.run(node, [Home.recorderScript.path, sbURL.path, tmp.path, "--check"], cwd: Home.root.appendingPathComponent("web-recorder"))
        let line = r.out.split(separator: "\n").last.map(String.init) ?? "{}"
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? ["ok": false, "error": r.err.suffix(600)]
        emit(obj)
        if (obj["ok"] as? Bool) != true { exit(4) }
        return
    }
    let bundle = try Home.newBundleURL(name: name, project: a.str("project") ?? (sb["project"] as? String), out: a.str("out"))
    try Home.prepareTarget(bundle, force: a.has("force"))
    let sources = bundle.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: sources.appendingPathComponent("storyboard.json"))
    try FileManager.default.copyItem(at: sbURL, to: sources.appendingPathComponent("storyboard.json"))
    // Directed storyboard: plan narration, music and cues first; the recorder runs on that clock.
    var directed: (planURL: URL, plan: Director.Plan)? = nil
    if sb["beats"] != nil {
        if sb["steps"] != nil { Log.warn("storyboard has both beats and steps — steps are ignored in directed mode") }
        directed = try recordDirected(sb: sb, sbURL: sbURL, bundle: bundle, preset: a.str("preset") ?? (sb["preset"] as? String),
                                      project: a.str("project"), seed: a.int("seed"))
    }
    Log.info("recording \(sb["url"] as? String ?? "(html)") → \(bundle.path)")
    // Run with the storyboard's own directory so relative URLs resolve; stream recorder stderr.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: node)
    p.arguments = [Home.recorderScript.path, sbURL.path, sources.path] + (directed.map { [$0.planURL.path] } ?? [])
    p.currentDirectoryURL = Home.root.appendingPathComponent("web-recorder")
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = FileHandle.standardError
    try p.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let metaLine = String(decoding: outData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "{}"
    let meta = (try? JSONSerialization.jsonObject(with: Data(metaLine.utf8)) as? [String: Any]) ?? [:]
    guard p.terminationStatus != 3, p.terminationStatus != 5, p.terminationStatus != 2,
          FileManager.default.fileExists(atPath: sources.appendingPathComponent("screen.mp4").path) else {
        throw fail("web recording failed (recorder exit \(p.terminationStatus)); see the messages above")
    }

    var o = ProjectIO.NewOptions()
    o.video = sources.appendingPathComponent("screen.mp4")
    o.events = sources.appendingPathComponent("events.json")
    o.kind = meta["kind"] as? String ?? "web"
    o.url = meta["url"] as? String
    o.name = name
    o.look = a.str("look") ?? (sb["look"] as? String)
    o.preset = a.str("preset") ?? (sb["preset"] as? String)
    o.compressIdle = a.has("compress-idle")
    o.autoZoom = !a.has("no-zoom")
    try ProjectIO.create(at: bundle, o)
    try convertMarkers(bundle)
    var extra: [String: Any] = ["recorded": true, "recorder": meta]
    if let d = directed {
        let studio = try Studio(url: bundle)
        var proj = studio.project
        Director.apply(d.plan, to: &proj, beatMarkers: studio.events.markers, bundle: bundle)
        Director.tidyZooms(&proj, sourceDuration: studio.sourceDuration)
        try ProjectIO.save(proj, to: bundle)
        Director.remember(d.plan, name: name, historyURL: Home.historyURL(project: a.str("project") ?? (sb["project"] as? String)))
        extra["directed"] = ["plan": d.planURL.path, "mode": d.plan.mode, "reason": d.plan.reason, "duration": d.plan.duration,
                             "bpm": d.plan.grid.map { $0.bpm } ?? NSNull(), "lines": d.plan.lines.count, "actions": d.plan.actions.count,
                             "warnings": d.plan.warnings, "drift": meta["drift"] ?? 0]
    }
    let recErrors = meta["errors"] as? [Any] ?? []
    let nothingHappened = (meta["clicks"] as? Int ?? 0) == 0 && (meta["keys"] as? Int ?? 0) == 0 && (meta["markers"] as? Int ?? 0) == 0
        && ((sb["steps"] as? [Any])?.isEmpty == false || (sb["beats"] as? [Any])?.isEmpty == false)
    if p.terminationStatus != 0 || !recErrors.isEmpty || nothingHappened {
        extra["ok"] = false
        extra["recorderExit"] = Int(p.terminationStatus)
        extra["problem"] = nothingHappened ? "the take recorded no clicks, keys or markers — the storyboard probably failed early"
                                           : "some steps failed (see recorder.errors); the partial take is kept"
    }
    try summarize(bundle, extra: extra)
    if (extra["ok"] as? Bool) == false { exit(4) }
}

// MARK: placeholders filled in by ScreenRecord.swift / SimRecord.swift

func recordStatus() throws {
    let state = RecordingState.load()
    emit(["recording": state != nil, "state": state.map { ["bundle": $0.bundle, "pid": $0.pid, "type": $0.type, "started": $0.started] } ?? NSNull()])
}
