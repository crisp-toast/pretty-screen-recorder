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
    let bundle = try Home.newBundleURL(name: name, project: a.str("project") ?? (sb["project"] as? String), out: a.str("out"))
    try Home.prepareTarget(bundle, force: a.has("force"))
    let sources = bundle.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: sources.appendingPathComponent("storyboard.json"))
    try FileManager.default.copyItem(at: sbURL, to: sources.appendingPathComponent("storyboard.json"))

    guard let node = Media.which("node") else { throw fail("node not found") }
    Log.info("recording \(sb["url"] as? String ?? "(html)") → \(bundle.path)")
    // Run with the storyboard's own directory so relative URLs resolve; stream recorder stderr.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: node)
    p.arguments = [Home.recorderScript.path, sbURL.path, sources.path]
    p.currentDirectoryURL = Home.root.appendingPathComponent("web-recorder")
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = FileHandle.standardError
    try p.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let metaLine = String(decoding: outData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "{}"
    let meta = (try? JSONSerialization.jsonObject(with: Data(metaLine.utf8)) as? [String: Any]) ?? [:]
    guard FileManager.default.fileExists(atPath: sources.appendingPathComponent("screen.mp4").path) else {
        throw fail("web recording failed (exit \(p.terminationStatus))")
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
    if p.terminationStatus != 0 { extra["recorderExit"] = Int(p.terminationStatus) }
    try summarize(bundle, extra: extra)
}

// MARK: placeholders filled in by ScreenRecord.swift / SimRecord.swift

func recordStatus() throws {
    let state = RecordingState.load()
    emit(["recording": state != nil, "state": state.map { ["bundle": $0.bundle, "pid": $0.pid, "type": $0.type, "started": $0.started] } ?? NSNull()])
}
