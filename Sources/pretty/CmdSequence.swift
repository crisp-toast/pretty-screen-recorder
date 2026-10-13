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
    var args: [String] = []
    for c in clips { args += ["-i", c.0.path] }
    var filters: [String] = []
    if clips.count == 1 {
        filters.append("[0:v]null[v]"); filters.append("[0:a]anull[a]")
    } else if T <= 0 {
        filters.append(clips.indices.map { "[\($0):v][\($0):a]" }.joined() + "concat=n=\(clips.count):v=1:a=1[v][a]")
    } else {
        var vprev = "[0:v]", aprev = "[0:a]", offset = 0.0
        for i in 1..<clips.count {
            offset += clips[i - 1].1 - T
            let vo = i == clips.count - 1 ? "[v]" : "[v\(i)]", ao = i == clips.count - 1 ? "[a]" : "[a\(i)]"
            filters.append("\(vprev)[\(i):v]xfade=transition=\(xf):duration=\(T):offset=\(String(format: "%.4f", offset))\(vo)")
            filters.append("\(aprev)[\(i):a]acrossfade=d=\(T)\(ao)")
            vprev = vo; aprev = ao
        }
    }
    let total = clips.map(\.1).reduce(0, +) - T * Double(max(0, clips.count - 1))
    var amap = "[a]"
    if let m = seq["music"] as? [String: Any], let mp = m["path"] as? String {
        let mu = res(mp)
        args += ["-stream_loop", "-1", "-i", mu.path]
        let mi = clips.count
        let vol = m["volume"] as? Double ?? 0.3
        filters.append("[\(mi):a]atrim=0:\(total),asetpts=PTS-STARTPTS,aresample=48000,volume=\(vol),afade=t=in:d=0.6,afade=t=out:st=\(max(0, total - 1.5)):d=1.5[mus]")
        filters.append("[a][mus]amix=inputs=2:normalize=0:duration=first,loudnorm=I=-14:TP=-1:LRA=11,aresample=48000[am]")
        amap = "[am]"
    }
    args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", amap, "-t", String(format: "%.3f", total),
             "-c:v", "libx264", "-crf", "17", "-preset", "medium", "-pix_fmt", "yuv420p", "-r", "\(fps)",
             "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", out.path]
    Log.info("stitching \(clips.count) clips (\(ttype) \(T)s) → \(out.path)")
    try Media.ffmpegRun(args)
    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
    emit(["ok": true, "output": out.path, "size": "\(W)x\(H)", "fps": fps, "duration": round3(total),
          "items": clips.count, "megabytes": round3(Double(size ?? 0) / 1_048_576)])
}
