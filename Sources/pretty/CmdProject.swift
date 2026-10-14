import Foundation
import PrettyCore

func bundleArg(_ a: Args) throws -> URL { url(try a.requirePos(0, "project bundle (.prettystudio or project.json)")) }

// MARK: new

func cmdNew(_ a: Args) throws {
    var o = ProjectIO.NewOptions()
    if let v = a.pos(0), !a.has("card") { o.video = url(v) }
    o.events = a.str("events").map(url)
    o.camera = a.str("camera").map(url)
    o.kind = a.str("kind") ?? (a.has("card") ? "card" : nil)
    o.look = a.str("look")
    o.preset = a.str("preset")
    o.name = a.str("name")
    o.url = a.str("url")
    o.duration = a.double("duration")
    o.copySources = !a.has("symlink")
    o.compressIdle = a.has("compress-idle") || a.has("idle")
    o.autoZoom = !a.has("no-zoom")
    let name = o.name ?? o.video?.deletingPathExtension().lastPathComponent ?? "card"
    let b = try Home.newBundleURL(name: name, project: a.str("project"), out: a.str("out"))
    if a.has("force") { try Home.prepareTarget(b, force: true) }
    let bundle = try ProjectIO.create(at: b, o)
    try convertMarkers(bundle)
    try summarize(bundle, extra: ["created": true])
}

/// Storyboard markers (caption/title/spotlight/highlight) become source-time overlays.
func convertMarkers(_ bundle: URL) throws {
    let studio = try Studio(url: bundle)
    var p = studio.project
    var added = 0
    for m in studio.events.markers {
        var o = Overlay()
        o.start = round3(m.t); o.end = round3(m.t + (m.duration ?? 2.5)); o.time = "source"
        switch m.type {
        case "caption":
            o.type = "text"; o.style = "caption"; o.text = m.text; o.position = "bottom"; o.animation = "pop"
        case "title":
            o.type = "text"; o.style = "title"; o.text = m.text; o.position = "top"; o.animation = "rise"
        case "spotlight", "highlight":
            guard let r = m.rect else { continue }
            o.type = m.type; o.rect = r; o.start = round3(max(0, m.t - 0.1))
        default: continue
        }
        if !p.overlays.contains(where: { $0.type == o.type && abs($0.start - o.start) < 0.01 }) { p.overlays.append(o); added += 1 }
    }
    if added > 0 { try ProjectIO.save(p, to: bundle) }
}

// MARK: inspect / validate

func summarize(_ bundle: URL, extra: [String: Any] = [:]) throws {
    let studio = try Studio(url: bundle)
    let p = studio.project
    var out: [String: Any] = extra
    out["ok"] = extra["ok"] ?? true
    out["bundle"] = Studio.locate(bundle).base.path
    out["name"] = p.name
    out["kind"] = p.source.kind
    if studio.hasVideo {
        out["source"] = ["video": studio.videoURL!.path, "width": Int(studio.videoSize.width), "height": Int(studio.videoSize.height),
                         "duration": round3(studio.sourceDuration), "fps": round3(studio.sourceFPS)]
    }
    out["outputDuration"] = round3(studio.outputDuration)
    out["events"] = ["mouseSamples": studio.events.mouse.count, "clicks": studio.events.clicks.count, "keys": studio.events.keys.count,
                     "scrolls": studio.events.scrolls.count, "markers": studio.events.markers.count]
    out["kept"] = studio.map.segments.map { ["src": [round3($0.srcStart), round3($0.srcEnd)], "out": [round3($0.outStart), round3($0.outEnd)], "rate": $0.rate] }
    out["zooms"] = p.zoom.segments.map { z -> [String: Any] in
        var d: [String: Any] = ["id": z.id, "src": [z.start, z.end], "level": z.level, "mode": z.mode, "auto": z.auto,
                                "out": [round3(studio.map.output(atSource: z.start)), round3(studio.map.output(atSource: z.end))]]
        if let f = z.focus { d["focus"] = [f.x, f.y] }
        return d
    }
    out["overlays"] = p.overlays.enumerated().map { (i, o) -> [String: Any] in
        var d: [String: Any] = ["index": i, "type": o.type, "start": o.start, "end": o.end, "time": o.usesSourceTime ? "source" : "output"]
        if let t = o.text { d["text"] = t }
        return d
    }
    out["captions"] = studio.captions(preset: nil).count
    let ap = studio.audioPlan(preset: nil)
    var audio: [String: Any] = ["mode": ap.mode, "reason": ap.reason, "voiceClips": p.audio.voiceover.count,
                                "music": p.audio.music.path ?? NSNull()]
    if let g = p.audio.music.grid { audio["bpm"] = g.bpm }
    out["audio"] = audio
    let frameType = studio.hasVideo ? Frames.resolveType(p.frame, source: p.source, videoSize: studio.cropRect.size) : "none"
    out["look"] = ["background": p.background.type == "gradient" ? p.background.preset : p.background.type, "frame": frameType,
                   "aspect": p.layout.aspect, "fit": p.layout.fit, "cursor": "\(p.cursor.style) x\(p.cursor.size) \(p.cursor.motion)"]
    if let s = try? ExportSettings.resolve(studio) {
        out["export"] = ["preset": s.preset?.name ?? "custom", "size": "\(s.width)x\(s.height)", "fps": s.fps, "format": s.format, "codec": s.codec]
        if !s.notes.isEmpty { out["exportNotes"] = s.notes }
    }
    out["warnings"] = warnings(bundle, studio)
    printJSON(out)
}

func warnings(_ bundle: URL, _ studio: Studio) -> [String] {
    var w: [String] = []
    if let raw = try? ProjectIO.loadJSON(bundle) { w += Schema.unknownKeys(raw) }
    let p = studio.project
    let d = studio.outputDuration
    for o in p.overlays where !o.usesSourceTime && o.start >= d { w.append("overlay '\(o.text ?? o.type)' starts after the video ends (\(round3(d))s)") }
    if let st = try? ExportSettings.resolve(studio), st.safe.contains(where: { $0 > 0 }) {
        for o in p.overlays where o.type == "text" {
            if let y = o.y, y < st.safe[0] || y > 1 - st.safe[1] {
                w.append("text '\(o.text ?? "")' at y=\(y) is inside \(st.preset?.name ?? "")'s UI overlay zone (it will be nudged into the safe area)")
            }
        }
    }
    for z in p.zoom.segments where z.level > 3.5 { w.append("zoom \(z.id) level \(z.level) is very high; text will get soft") }
    let segs = p.zoom.segments.sorted { $0.start < $1.start }
    for i in segs.indices.dropFirst() where segs[i].start < segs[i - 1].end - 0.05 { w.append("zooms \(segs[i - 1].id) and \(segs[i].id) overlap") }
    if studio.hasVideo && studio.events.mouse.isEmpty && studio.events.clicks.isEmpty && p.cursor.show {
        w.append("no cursor telemetry: the recording's own cursor (if any) is shown; Smart Zooms need clicks")
    }
    if let m = p.audio.music.path, !FileManager.default.fileExists(atPath: studio.resolve(m).path) { w.append("music file missing: \(m)") }
    return w
}

func cmdInspect(_ a: Args) throws { try summarize(try bundleArg(a)) }

func cmdValidate(_ a: Args) throws {
    let b = try bundleArg(a)
    do {
        let studio = try Studio(url: b)
        let w = warnings(b, studio)
        _ = try ExportSettings.resolve(studio)
        emit(["ok": true, "valid": true, "warnings": w])
    } catch {
        emit(["ok": false, "valid": false, "error": "\(error)"])
        exit(1)
    }
}

// MARK: set / get

func cmdSet(_ a: Args) throws {
    let b = try bundleArg(a)
    var json = try ProjectIO.loadJSON(b)
    var changed: [String] = []
    for kv in a.positionals.dropFirst() {
        guard let eq = kv.firstIndex(of: "=") else { throw fail("expected key=value, got '\(kv)'") }
        let key = String(kv[..<eq]), raw = String(kv[kv.index(after: eq)...])
        try ProjectIO.setValue(&json, path: key, value: ProjectIO.parseValue(raw))
        changed.append(key)
    }
    // Also accept --key value for the common case of a single setting.
    for (k, v) in a.options where k.contains(".") {
        try ProjectIO.setValue(&json, path: k, value: ProjectIO.parseValue(v)); changed.append(k)
    }
    let unknown = Schema.unknownKeys(json)
    try ProjectIO.saveJSON(json, to: b)
    emit(["ok": true, "set": changed, "warnings": unknown])
}

func cmdGet(_ a: Args) throws {
    let b = try bundleArg(a)
    let json = try ProjectIO.loadJSON(b)
    if let key = a.pos(1) {
        let v = try ProjectIO.getValue(json, path: key)
        emit(["key": key, "value": v ?? NSNull()])
    } else {
        printJSON(json)
    }
}

// MARK: auto

func cmdAuto(_ a: Args) throws {
    let b = try bundleArg(a)
    let zooms = a.has("zooms") || (!a.has("zooms") && !a.has("idle"))
    let idle = a.has("idle")
    try ProjectIO.autoEdit(bundle: b, zooms: zooms, idle: idle)
    try summarize(b, extra: ["auto": ["zooms": zooms, "idle": idle]])
}

// MARK: zoom

func cmdZoom(_ a: Args) throws {
    let b = try bundleArg(a)
    var p = try ProjectIO.load(b)
    let sub = a.pos(1) ?? "list"
    switch sub {
    case "add":
        guard let s = a.double("start"), let e = a.double("end"), e > s else { throw fail("zoom add needs --start and --end (source seconds, end > start)") }
        var z = ZoomSegment(start: s, end: e, level: a.double("level") ?? p.zoom.level, mode: a.has("manual") ? "manual" : (a.str("mode") ?? p.zoom.mode))
        z.focus = a.point("focus")
        if z.mode == "manual" && z.focus == nil { throw fail("manual zoom needs --focus x,y (normalized 0-1)") }
        p.zoom.segments.append(z)
        p.zoom.segments.sort { $0.start < $1.start }
        try ProjectIO.save(p, to: b)
        emit(["ok": true, "added": z.id])
    case "clear":
        let before = p.zoom.segments.count
        p.zoom.segments = a.has("auto") ? p.zoom.segments.filter { !$0.auto } : []
        try ProjectIO.save(p, to: b)
        emit(["ok": true, "removed": before - p.zoom.segments.count])
    case "rm", "remove", "delete":
        let id = try a.requirePos(2, "zoom id")
        let before = p.zoom.segments.count
        p.zoom.segments.removeAll { $0.id == id }
        try ProjectIO.save(p, to: b)
        emit(["ok": before != p.zoom.segments.count, "removed": before - p.zoom.segments.count])
    default:
        try summarize(b)
    }
}

// MARK: timeline

func cmdCut(_ a: Args) throws {
    let b = try bundleArg(a)
    guard let s = a.pos(1).flatMap(Double.init), let e = a.pos(2).flatMap(Double.init), e > s else { throw fail("usage: pretty cut <bundle> START END (source seconds)") }
    var p = try ProjectIO.load(b)
    p.timeline.cuts.append(TimeRange(start: s, end: e))
    try ProjectIO.save(p, to: b)
    try summarize(b, extra: ["cut": [s, e]])
}

func cmdSpeed(_ a: Args) throws {
    let b = try bundleArg(a)
    guard let s = a.pos(1).flatMap(Double.init), let e = a.pos(2).flatMap(Double.init), let r = a.pos(3).flatMap(Double.init), e > s, r > 0 else {
        throw fail("usage: pretty speed <bundle> START END RATE")
    }
    var p = try ProjectIO.load(b)
    p.timeline.speed.removeAll { $0.start < e && s < $0.end && !$0.auto }
    p.timeline.speed.append(SpeedRange(start: s, end: e, rate: r))
    try ProjectIO.save(p, to: b)
    try summarize(b, extra: ["speed": [s, e, r]])
}

func cmdTrim(_ a: Args) throws {
    let b = try bundleArg(a)
    guard let s = a.pos(1).flatMap(Double.init) else { throw fail("usage: pretty trim <bundle> START [END]") }
    var p = try ProjectIO.load(b)
    p.timeline.trimStart = s
    p.timeline.trimEnd = a.pos(2).flatMap(Double.init)
    try ProjectIO.save(p, to: b)
    try summarize(b, extra: ["trim": [s, p.timeline.trimEnd as Any]])
}

// MARK: text / captions / music

func cmdText(_ a: Args) throws {
    let b = try bundleArg(a)
    let text = try a.requirePos(1, "text (or: ls | rm INDEX)")
    var p = try ProjectIO.load(b)
    if text == "ls" || text == "list" {
        emit(["overlays": p.overlays.enumerated().map { (i, o) -> [String: Any] in
            var d: [String: Any] = ["index": i, "type": o.type, "start": o.start, "end": o.end, "style": o.style, "position": o.position,
                                    "time": o.usesSourceTime ? "source" : "output"]
            if let t = o.text { d["text"] = t }
            if let y = o.y { d["y"] = y }
            return d
        }])
        return
    }
    if text == "rm" || text == "remove" {
        guard let i = a.pos(2).flatMap(Int.init), i >= 0, i < p.overlays.count else { throw fail("text rm INDEX (see `pretty text <bundle> ls`)") }
        let removed = p.overlays.remove(at: i)
        try ProjectIO.save(p, to: b)
        emit(["ok": true, "removed": i, "text": removed.text ?? removed.type])
        return
    }
    var o = Overlay()
    o.type = "text"; o.text = text
    o.start = a.double("start") ?? 0
    o.end = a.double("end") ?? (o.start + 3)
    o.style = a.str("style") ?? "title"
    o.position = a.str("position") ?? (o.style == "caption" ? "bottom" : "top")
    o.animation = a.str("animation") ?? "rise"
    if let c = a.str("color") { o.color = c }
    if let f = a.str("fill") { o.fill = f }
    if let s = a.double("size") { o.size = s }
    if let x = a.double("x") { o.x = x }
    if let y = a.double("y") { o.y = y }
    if let w = a.str("weight") { o.weight = w }
    if let f = a.str("font") { o.font = f }
    if let t = a.str("time") { o.time = t }
    p.overlays.append(o)
    try ProjectIO.save(p, to: b)
    emit(["ok": true, "overlayIndex": p.overlays.count - 1])
}

func cmdCaption(_ a: Args) throws {
    let b = try bundleArg(a)
    var p = try ProjectIO.load(b)
    if let srt = a.str("srt") {
        let src = url(srt)
        let base = Studio.locate(b).base
        let dst = base.appendingPathComponent("sources/captions.srt")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        p.captions.srt = "sources/captions.srt"
    } else {
        let text = try a.requirePos(1, "caption text (or --srt file)")
        guard let s = a.double("start"), let e = a.double("end") else { throw fail("caption needs --start and --end (output seconds)") }
        p.captions.items.append(CaptionItem(start: s, end: e, text: text))
        p.captions.items.sort { $0.start < $1.start }
    }
    if let st = a.str("style") { p.captions.style = st }
    try ProjectIO.save(p, to: b)
    emit(["ok": true, "captions": p.captions.items.count, "srt": p.captions.srt ?? NSNull()])
}

func cmdMusic(_ a: Args) throws {
    let b = try bundleArg(a)
    let file = url(try a.requirePos(1, "music file"))
    guard FileManager.default.fileExists(atPath: file.path) else { throw fail("music not found: \(file.path)") }
    var p = try ProjectIO.load(b)
    p.audio.music.path = file.path
    p.audio.music.generate = nil
    if let v = a.double("volume") { p.audio.music.volume = v }
    var beat: [String: Any] = [:]
    if let r = try? BeatDetect.analyze(file) {
        p.audio.music.bpm = r.bpm; p.audio.music.beatOffset = r.firstBeat
        beat = ["bpm": r.bpm, "firstBeat": r.firstBeat, "confidence": r.confidence]
    }
    if p.audio.mode == "voiceover" || p.audio.mode == "none" { Log.warn("audio.mode is \(p.audio.mode) — set audio.mode=music or both to hear it") }
    try ProjectIO.save(p, to: b)
    emit(["ok": true, "music": file.path, "volume": p.audio.music.volume, "beats": beat])
}

// MARK: debug

/// pretty _cursor <bundle>: cursor position/visibility at each click (regression checks).
func cmdDebugCursor(_ a: Args) throws {
    let studio = try Studio(url: try bundleArg(a))
    let rows: [[String: Any]] = studio.cursor.clicks.map { c in
        let p = studio.cursor.position(at: c.t), q = studio.cursor.position(at: c.t + 0.04)
        return ["t": round3(c.t), "click": [round3(c.x), round3(c.y)], "pos": [round3(Double(p.x)), round3(Double(p.y))],
                "pos+40ms": [round3(Double(q.x)), round3(Double(q.y))], "vis": round3(studio.cursor.visibility(at: c.t))]
    }
    var out: [String: Any] = ["motion": studio.project.cursor.motion, "clicks": rows, "mouse": studio.events.mouse.count,
                              "rests": studio.cursor.debugRests]
    if let t0 = a.double("from"), let t1 = a.double("to") {
        out["path"] = stride(from: t0, through: t1, by: 0.02).map { t -> [Double] in
            let p = studio.cursor.position(at: t); return [round3(t), round3(Double(p.x)), round3(Double(p.y))]
        }
    }
    emit(out)
}
