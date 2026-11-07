import Foundation
import PrettyCore

/// Stitch title cards, rendered projects and plain clips into one video with transitions
/// and a music bed — the "ad" workflow.
///
/// {
///   "export": {"preset": "tiktok"},
///   "transition": {"type": "fade", "duration": 0.4},
///   "music": {"path": "song.m4a", "volume": 0.3},
///   "items": [ {"project": "intro.prettystudio"}, {"project": "demo.prettystudio"}, {"video": "broll.mp4", "trim": [0, 3]} ]
/// }
func cmdSequence(_ a: Args) throws {
    let seqURL = url(try a.requirePos(0, "sequence.json"))
    guard let seq = try JSONSerialization.jsonObject(with: Data(contentsOf: seqURL)) as? [String: Any],
          let items = seq["items"] as? [[String: Any]], !items.isEmpty else { throw fail("sequence needs an items array") }
    let base = seqURL.deletingLastPathComponent()
    func res(_ p: String) -> URL { p.hasPrefix("/") ? URL(fileURLWithPath: p) : base.appendingPathComponent(p) }

    var spec = ExportSpec()
    if let e = seq["export"] as? [String: Any] {
        spec.preset = e["preset"] as? String; spec.width = e["width"] as? Int; spec.height = e["height"] as? Int
        spec.fps = e["fps"] as? Int; spec.quality = e["quality"] as? String
    }
    let cli = overrides(a)
    if cli.preset != nil { spec.preset = cli.preset }
    if let f = cli.fps { spec.fps = f }
    // Fix the canvas from the preset (or explicit size) once for every item.
    let preset = spec.preset.flatMap(Presets.named)
    let W = spec.width ?? preset?.width ?? 1920, H = spec.height ?? preset?.height ?? 1080, fps = spec.fps ?? preset?.fps ?? 30

    let out = a.str("out").map(url) ?? Home.versioned(dir: base, slug: Home.slug(seqURL.deletingPathExtension().lastPathComponent), ext: "mp4")
    let tmp = out.deletingLastPathComponent().appendingPathComponent(".pretty-seq-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    var clips: [(URL, Double)] = []
    for (i, item) in items.enumerated() {
        let clip = tmp.appendingPathComponent(String(format: "clip_%02d.mp4", i))
        if let p = (item["project"] as? String) ?? (item["card"] as? String) {
            let studio = try Studio(url: res(p))
            if seq["music"] != nil { studio.project.audio.music.path = nil } // the sequence's music bed replaces per-item music
            var o = ExportSpec(); o.width = W; o.height = H; o.fps = fps; o.quality = spec.quality ?? "high"; o.format = "mp4"; o.codec = "h264"
            var settings = try ExportSettings.resolve(studio, overrides: o)
            settings.requireAudioTrack = true
            Log.info("[\(i + 1)/\(items.count)] rendering \(p)")
            _ = try Exporter(studio: studio, settings: settings).run(to: clip)
        } else if let v = item["video"] as? String {
            var args = [String]()
            if let trim = item["trim"] as? [Double], trim.count == 2 { args += ["-ss", "\(trim[0])", "-to", "\(trim[1])"] }
            args += ["-i", res(v).path, "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                     "-filter_complex", "[0:v]scale=\(W):\(H):force_original_aspect_ratio=decrease,pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2:color=black,fps=\(fps),format=yuv420p[v]",
                     "-map", "[v]"]
            let hasAudio = ((try? Media.probe(res(v)))?.audioStreams ?? 0) > 0
            args += hasAudio ? ["-map", "0:a:0"] : ["-map", "1:a:0", "-shortest"]
            args += ["-c:v", "libx264", "-crf", "16", "-preset", "fast", "-c:a", "aac", "-ar", "48000", "-ac", "2", clip.path]
            Log.info("[\(i + 1)/\(items.count)] conforming \(v)")
            try Media.ffmpegRun(args)
        } else { throw fail("item \(i) needs project, card or video") }
        clips.append((clip, try Media.probe(clip).duration))
    }

    let tr = seq["transition"] as? [String: Any]
    let ttype = (tr?["type"] as? String) ?? "fade"
    let T = ttype == "none" ? 0 : ((tr?["duration"] as? Double) ?? 0.4)
    let xf = ["fade": "fade", "dissolve": "dissolve", "slide": "slideleft", "slideup": "slideup", "wipe": "wipeleft",
              "zoom": "zoomin", "smooth": "smoothleft", "circle": "circleopen", "blur": "hblur"][ttype] ?? "fade"

    // Music bed: a file (beats analyzed) or a generated track; with sync, cuts land on the beat.
    let m = seq["music"] as? [String: Any]
    var musicURL: URL? = nil, grid: BeatGrid? = nil, musicStart = 0.0
    var rawTotal = clips.map(\.1).reduce(0, +) - T * Double(max(0, clips.count - 1))
    var musicSpec: MusicSpec? = nil
    if m?["track"] != nil || m?["find"] != nil || (m?["path"] == nil && m?["generate"] == nil && m != nil) {
        // A real track: catalog/licensed reference, or a search.
        let t: MusicLibrary.Track
        if let ref = m?["track"] as? String { t = try MusicLibrary.find(ref) }
        else {
            var q = MusicLibrary.Query(json: (m?["find"] as? [String: Any]) ?? ["mood": m?["mood"] as? String ?? "upbeat"])
            q.minDuration = q.minDuration ?? rawTotal + 2
            guard let best = try MusicLibrary.search(q, limit: 1).first else { throw fail("no track matched the music search") }
            t = best
        }
        let spec = try MusicLibrary.spec(for: t)
        musicSpec = spec
        musicURL = spec.path.map { URL(fileURLWithPath: $0) }
        if let bpm = spec.bpm {
            // Start on the downbeat at/after the smart offset.
            let g0 = BeatGrid(bpm: bpm, firstBeat: spec.beatOffset ?? 0)
            musicStart = g0.next(atOrAfter: spec.offset)
            grid = BeatGrid(bpm: bpm, firstBeat: 0)
        }
        Log.info("music: \"\(t.title)\" — \(t.artist) (\(t.license.name))")
    } else if let mp = m?["path"] as? String {
        musicURL = res(mp)
        if let r = try? BeatDetect.analyze(musicURL!), r.confidence >= 0.2 {
            musicStart = r.firstBeat               // start the bed on its first downbeat
            grid = BeatGrid(bpm: r.bpm, firstBeat: 0)
        }
    } else if let g = m?["generate"] as? [String: Any] {
        var spec = MusicGenSpec()
        spec.mood = g["mood"] as? String ?? spec.mood; spec.bpm = g["bpm"] as? Double; spec.key = g["key"] as? String
        spec.seed = g["seed"] as? Int ?? spec.seed; spec.energy = g["energy"] as? Double ?? spec.energy
        let u = tmp.appendingPathComponent("music.wav")
        let r = try MusicGen.render(spec, duration: rawTotal + 1, to: u)
        musicURL = u
        grid = BeatGrid(bpm: r.bpm, firstBeat: 0)
    }
    let sync = (seq["sync"] as? String ?? "beats") != "none"

    // Effective clip lengths: with beat sync, trim each clip's tail (by less than one beat) so every
    // clip STARTS on a beat — directed clips keep their own click-on-beat timing when tempos match.
    var lens = clips.map(\.1)
    if sync, let g = grid, clips.count > 1 {
        var offset = 0.0
        for k in 1..<clips.count {
            let raw = offset + lens[k - 1] - T
            // Latest beat at or before where the next clip would start (we only ever shorten clips).
            let beat = g.firstBeat + ((raw - g.firstBeat) / g.period + 1e-6).rounded(.down) * g.period
            let trimmed = beat - offset + T
            if trimmed > 0.5 && lens[k - 1] - trimmed < g.period + 1e-6 && trimmed <= lens[k - 1] { lens[k - 1] = trimmed }
            offset += lens[k - 1] - T
        }
        Log.info(String(format: "beat-synced cuts at %.0f BPM", g.bpm))
    }
    rawTotal = lens.reduce(0, +) - T * Double(max(0, clips.count - 1))
    let total = rawTotal

    var args: [String] = []
    for c in clips { args += ["-i", c.0.path] }
    var filters: [String] = []
    for i in clips.indices {
        filters.append("[\(i):v]trim=0:\(String(format: "%.4f", lens[i])),setpts=PTS-STARTPTS[cv\(i)]")
        filters.append("[\(i):a]atrim=0:\(String(format: "%.4f", lens[i])),asetpts=PTS-STARTPTS[ca\(i)]")
    }
    if clips.count == 1 {
        filters.append("[cv0]null[v]"); filters.append("[ca0]anull[a]")
    } else if T <= 0 {
        filters.append(clips.indices.map { "[cv\($0)][ca\($0)]" }.joined() + "concat=n=\(clips.count):v=1:a=1[v][a]")
    } else {
        var vprev = "[cv0]", aprev = "[ca0]", offset = 0.0
        for i in 1..<clips.count {
            offset += lens[i - 1] - T
            let vo = i == clips.count - 1 ? "[v]" : "[v\(i)]", ao = i == clips.count - 1 ? "[a]" : "[a\(i)]"
            filters.append("\(vprev)[cv\(i)]xfade=transition=\(xf):duration=\(T):offset=\(String(format: "%.4f", offset))\(vo)")
            filters.append("\(aprev)[ca\(i)]acrossfade=d=\(T)\(ao)")
            vprev = vo; aprev = ao
        }
    }
    var amap = "[a]"
    if let mu = musicURL {
        args += ["-stream_loop", "-1", "-ss", "\(musicStart)", "-i", mu.path]
        let mi = clips.count
        let vol = m?["volume"] as? Double ?? 0.3
        filters.append("[\(mi):a]atrim=0:\(total),asetpts=PTS-STARTPTS,aresample=48000,volume=\(vol),afade=t=in:d=0.3,afade=t=out:st=\(max(0, total - 1.5)):d=1.5[mus]")
        filters.append("[a][mus]amix=inputs=2:normalize=0:duration=first,loudnorm=I=-14:TP=-1:LRA=11,aresample=48000[am]")
        amap = "[am]"
    }
    args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", amap, "-t", String(format: "%.3f", total),
             "-c:v", "libx264", "-crf", "17", "-preset", "medium", "-pix_fmt", "yuv420p", "-r", "\(fps)",
             "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", out.path]
    Log.info("stitching \(clips.count) clips (\(ttype) \(T)s) → \(out.path)")
    try Media.ffmpegRun(args)
    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
    var result: [String: Any] = ["ok": true, "output": out.path, "size": "\(W)x\(H)", "fps": fps, "duration": round3(total),
                                 "items": clips.count, "megabytes": round3(Double(size) / 1_048_576)]
    if let ms = musicSpec {
        let c = MusicLibrary.credits(music: ms, usedMusic: true, voiceProvider: nil)
        if !c.lines.isEmpty {
            let f = out.deletingPathExtension().appendingPathExtension("credits.txt")
            try? ("Credits for \(out.lastPathComponent) — paste into the post/description when publishing.\n\n" + c.text + "\n").write(to: f, atomically: true, encoding: .utf8)
            result["credits"] = c.lines; result["creditsFile"] = f.path
        }
    }
    emit(result)
}
