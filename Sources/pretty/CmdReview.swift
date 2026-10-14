import Foundation
import CoreGraphics
import ImageIO
import PrettyCore

/// pretty review <bundle | render.mp4> [--render file] [-p preset]
///
/// The final check before anything is delivered. Builds a review pack (contact sheet, key moments,
/// waveform) and runs objective checks; the agent then LOOKS at the images and scores the rubric.
/// Nothing ships until every blocker and major issue is fixed and every rubric line scores 4+.
func cmdReview(_ a: Args) throws {
    let target = url(try a.requirePos(0, "bundle or rendered video"))
    var bundle: URL? = nil, render: URL? = nil
    if target.pathExtension == ProjectIO.bundleExtension || FileManager.default.fileExists(atPath: target.appendingPathComponent("project.json").path) {
        bundle = target
        render = a.str("render").map(url) ?? latestRender(target)
    } else {
        render = target
        bundle = a.str("bundle").map(url) ?? bundleFor(render: target)
    }
    guard let video = render, FileManager.default.fileExists(atPath: video.path) else {
        throw fail("no render to review — run `pretty render <bundle> -p <preset>` first (or pass --render file.mp4)")
    }
    let studio = try bundle.map { try Studio(url: $0) }
    let p = studio?.project
    let preset = a.str("preset") ?? p?.export.preset
    let outDir = video.deletingPathExtension().appendingPathExtension("review")
    try? FileManager.default.removeItem(at: outDir)
    try FileManager.default.createDirectory(at: outDir.appendingPathComponent("moments"), withIntermediateDirectories: true)
    let probe = try Media.probe(video)
    let dur = probe.duration

    var issues: [[String: Any]] = []
    func issue(_ sev: String, _ area: String, _ msg: String, _ fix: String) {
        issues.append(["severity": sev, "area": area, "message": msg, "fix": fix])
    }

    // MARK: Images
    Log.info("building the review pack…")
    let sheet = outDir.appendingPathComponent("sheet.jpg")
    let step = max(0.5, dur / 24)
    _ = try? Media.run(Media.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path,
                                      "-vf", "fps=1/\(String(format: "%.3f", step)),scale=270:-2,tile=6x4:padding=6:color=0x111111", "-frames:v", "1", "-q:v", "3", sheet.path])
    var moments: [(Double, String)] = []
    if let p {
        for s in p.scenes {
            moments.append((s.start + min(0.35, s.duration / 4), "\(s.style) scene entering"))
            moments.append((s.start + s.duration * 0.62, "\(s.style) scene settled: \"\((s.text ?? s.allLines.joined(separator: " ")).prefix(40))\""))
        }
        for o in p.overlays where o.id == "headline" { moments.append((o.start + 0.9, "headline \"\((o.text ?? "").prefix(36))\"")) }
        for m in p.moves where ["rise", "tilt", "orbit"].contains(m.type) { moments.append((m.start + 0.6, "device \(m.type) entrance")) }
        for sh in p.shots {
            moments.append((sh.start + 0.35, "3D \(sh.move) shot beginning"))
            moments.append((sh.start + sh.duration * 0.55, "3D \(sh.move) shot mid-move (check for ghosting/clipping)"))
            moments.append((sh.end - 0.15, "3D \(sh.move) shot landing / handoff"))
        }
        if let st = studio {
            for z in p.zoom.segments { moments.append((st.map.output(atSource: (z.start + z.end) / 2), "zoom \(String(format: "%.2f", z.level))x")) }
            for c in st.events.clicks.prefix(12) where st.map.isKept(source: c.t) { moments.append((st.map.output(atSource: c.t) + 0.5, "after tap: \(c.why ?? "")")) }
        }
    }
    moments.append((0.05, "first frame (the hook — does it read instantly?)"))
    moments.append((max(0, dur - 0.1), "last frame"))
    moments = moments.filter { $0.0 >= 0 && $0.0 < dur }.sorted { $0.0 < $1.0 }
    var dedup: [(Double, String)] = []
    for m in moments where !(dedup.last.map { abs($0.0 - m.0) < 0.25 } ?? false) { dedup.append(m) }
    var images: [[String: Any]] = [["file": sheet.path, "what": "contact sheet, every \(String(format: "%.1f", step))s"]]
    for (k, m) in dedup.prefix(40).enumerated() {
        let f = outDir.appendingPathComponent("moments/\(String(format: "%02d", k))_\(String(format: "%05.2f", m.0))s.jpg")
        _ = try? Media.run(Media.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.3f", m.0), "-i", video.path,
                                          "-frames:v", "1", "-vf", "scale=540:-2", "-q:v", "3", f.path])
        images.append(["file": f.path, "at": round3(m.0), "what": m.1])
    }
    let wave = outDir.appendingPathComponent("audio.png")
    if probe.audioStreams > 0 {
        _ = try? Media.run(Media.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path, "-filter_complex",
                                          "showwavespic=s=1600x240:split_channels=0:colors=0x86868B", "-frames:v", "1", wave.path])
        images.append(["file": wave.path, "what": "waveform: look for a build into the reveal, a clean resolve, no abrupt end"])
    }

    // MARK: Picture checks
    let noise = sampleNoise(video, duration: dur)
    if let d = frameDetail(video), d < 0.002 {
        issue("major", "story", "frame one is blank — feeds autoplay muted and judge the first frame", "put the hook on screen from t=0 (re-plan: the opening scene now lands its first line on frame one)")
    }
    if noise > 1.6 { issue("major", "picture", String(format: "visible grain/noise (σ≈%.1f levels in flat areas)", noise), "set background.grain=0; avoid noisy B-roll") }
    if let r = try? Media.run(Media.ffmpeg, ["-hide_banner", "-nostats", "-i", video.path, "-vf", "blackdetect=d=0.2:pix_th=0.06", "-an", "-f", "null", "-"]) {
        for m in r.err.split(separator: "\n") where m.contains("black_start") {
            issue("major", "picture", "black frames: \(m.split(separator: "]").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "")", "check scene timing and the end of the video")
        }
    }
    if let r = try? Media.run(Media.ffmpeg, ["-hide_banner", "-nostats", "-i", video.path, "-vf", "freezedetect=n=0.002:d=2.6", "-an", "-f", "null", "-"]) {
        let starts = r.err.split(separator: "\n").compactMap { l -> Double? in l.contains("freeze_start") ? Double(l.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") : nil }
        let durs = r.err.split(separator: "\n").compactMap { l -> Double? in l.contains("freeze_duration") ? Double(l.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") : nil }
        for (s, d) in zip(starts, durs) where s < dur - 3.5 {
            issue("minor", "pacing", String(format: "nothing moves for %.1fs at %.1fs", d, s), "tighten the beat, add a slow push, or cut the dead time")
        }
    }

    // MARK: Audio checks
    if probe.audioStreams == 0 {
        issue(preset.map { ["web-hero", "gif"].contains($0) } == true ? "minor" : "major", "sound", "the video is silent", "an ad needs a score: set audio.mode and music (composed score, licensed track)")
    } else if let r = try? Media.run(Media.ffmpeg, ["-hide_banner", "-nostats", "-i", video.path, "-af", "ebur128=framelog=quiet:peak=true", "-f", "null", "-"]) {
        let lines = r.err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let l = lines.last(where: { $0.hasPrefix("I:") }), let v = Double(l.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") {
            if abs(v + 14) > 1.2 { issue("major", "sound", String(format: "loudness %.1f LUFS (target -14)", v), "keep audio.normalize=true and re-render") }
        }
        if let l = lines.last(where: { $0.hasPrefix("Peak:") }), let v = Double(l.dropFirst(5).trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""), v > -0.5 {
            issue("major", "sound", String(format: "true peak %.1f dBFS — will clip on phones", v), "re-render with normalization")
        }
        if let r2 = try? Media.run(Media.ffmpeg, ["-hide_banner", "-nostats", "-i", video.path, "-af", "silencedetect=n=-45dB:d=0.9", "-f", "null", "-"]) {
            for l in r2.err.split(separator: "\n") where l.contains("silence_start") {
                if let t = Double(l.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""), t > 0.5, t < dur - 1.2 {
                    issue("major", "sound", String(format: "the sound drops out at %.1fs", t), "music should run under the whole video")
                }
            }
        }
        // An abrupt end: the last half second still at full level.
        let tail = Media.rms(video, from: max(0, dur - 0.35), length: 0.3), body = Media.rms(video, from: dur * 0.3, length: dur * 0.4)
        if let t = tail, let b = body, t > b - 4, b > -40 { issue("minor", "sound", "the audio ends abruptly (no fade or resolve)", "let the score resolve on the end card; keep music.fadeOut ≥ 1.5s") }
    }

    // MARK: Craft checks (project)
    if let p {
        let pastel: Set<String> = ["dusk", "candy", "peach", "mint", "lavender", "sunset", "citrus", "rose", "sky", "pastel"]
        if p.background.type == "gradient" && pastel.contains(p.background.preset) {
            issue("major", "look", "pastel gradient backdrop (\(p.background.preset)) reads dated/cheesy", "use a treatment stage: background {type: stage, preset: keynote|studio|glow|paper|cinema}")
        }
        if p.background.grain > 0.05 { issue("major", "look", "film grain is on (background.grain=\(p.background.grain))", "set background.grain=0") }
        if p.scenes.contains(where: { $0.marker }) { issue("minor", "type", "highlighter marker on scene text can look dated", "prefer two-tone (secondary) emphasis") }
        if p.scenes.filter({ $0.style == "punch" || $0.style == "beat" }).count > 1 { issue("minor", "type", "more than one punch scene feels gimmicky", "use one at most") }
        let ad = ["tiktok", "reels", "shorts", "instagram", "square", "x"].contains(preset ?? "") || (preset ?? "").hasPrefix("app-store")
        if ad && !p.scenes.contains(where: { $0.style == "lockup" }) { issue("major", "story", "no end card (lockup)", "end on a lockup scene: icon, name, the product's promise, where to get it") }
        if let last = p.scenes.last(where: { $0.style == "lockup" }), last.duration < 1.8 { issue("major", "story", String(format: "the end card holds only %.1fs", last.duration), "hold the lockup at least 2s") }
        let trans = Set(p.scenes.map(\.transition))
        if p.scenes.count >= 3 && trans.count == 1 && trans.first != "auto" { issue("minor", "motion", "every scene uses the same transition", "vary transitions within the treatment") }
        if p.moves.isEmpty && studio?.hasVideo == true { issue("minor", "motion", "the device never moves (no entrance, no push)", "plan with a treatment, or add moves: [{type: rise|tilt|push|drift}]") }
        let mobile = ["ios", "mobile-web", "android"].contains(p.source.kind)
        if mobile && p.zoom.segments.isEmpty && studio?.hasVideo == true { issue("minor", "motion", "no zooms on a phone recording — small UI may be hard to read", "pretty auto <bundle> --zooms, or zoom markers on the payoff") }
        if p.zoom.segments.contains(where: { $0.level > 2.1 }) && mobile { issue("minor", "motion", "a zoom above 2.1x on a phone crops the device hard", "keep phone zooms ~1.3-1.6x") }
        // Music character
        let m = p.audio.music
        if studio?.audioPlan(preset: preset).music == true {
            if let lic = m.license, lic.source == "incompetech", let title = m.title,
               let t = try? MusicLibrary.find("incompetech:\(title)"), !Set(t.feel).isDisjoint(with: ["Bouncy", "Humorous"]) || t.famous && ["Carefree", "Happy Alley", "Life of Riley", "Funky Chunk", "Hustle", "Monkeys Spinning Monkeys", "Fluffing a Duck", "Sneaky Snitch", "Bit Quest", "Wallpaper"].contains(title) {
                issue("major", "sound", "\"\(title)\" is happy stock music — it cheapens a premium ad", "compose an original score (ElevenLabs Music, paid plan) or use a licensed cinematic track")
            }
            if m.generate != nil { issue("major", "sound", "procedurally generated bed — sounds synthetic", "compose with ElevenLabs Music or use a licensed track") }
        } else if !(["web-hero", "gif"].contains(preset ?? "")) {
            issue("major", "sound", "no music in an ad", "add a composed or licensed score")
        }
        // Credits & licensing
        let credits = studio?.credits(preset: preset)
        if let c = credits, !c.lines.isEmpty {
            let file = video.deletingPathExtension().appendingPathExtension("credits.txt")
            if !FileManager.default.fileExists(atPath: file.path) { issue("major", "rights", "credits.txt is missing next to the render", "re-render; publish its lines with the post") }
            if c.text.contains("non-commercial") { issue("blocker", "rights", "audio was made on the ElevenLabs free plan — non-commercial, credit required", "upgrade ElevenLabs (Starter or above) and re-render before running this as an ad") }
        }
        // Repetition across generations
        if let proj = projectName(bundle) {
            let h = History.load(Home.historyURL(project: proj))
            let recent = h.entries.dropLast().suffix(3)
            if let mine = h.entries.last, recent.contains(where: { $0.treatment == mine.treatment && $0.music == mine.music }) {
                issue("minor", "variety", "same treatment and music as a recent video for \(proj)", "re-plan with another treatment (or --seed N)")
            }
        }
    }

    let blockers = issues.filter { ($0["severity"] as? String) == "blocker" }.count
    let majors = issues.filter { ($0["severity"] as? String) == "major" }.count
    let rubric = [
        "Hook (first 1.5s): one clear idea, readable instantly, makes you want the next second",
        "Specific: every word on screen is about THIS product (its nouns, its numbers) — nothing generic",
        "Payoff: the result (price, screen, outcome) is visible, large enough, and on screen long enough to read",
        "Motion: purposeful and calm — one move at a time, no zoom during an entrance, no jitter",
        "Type: even spacing, aligned, nothing touching edges or the device, no orphan words, consistent sizes",
        "Device: correct and clean — no doubled island, no awkward crops, status bar tidy",
        "Sound: music fits the brand, builds into the reveal, resolves on the end card; effects subtle; no abrupt cut",
        "Ending: the end card holds 2s+, the promise and CTA are legible",
        "Overall: would this run as a paid ad for a top-tier app? Is it moving?",
    ]
    var md = "# Review — \(video.lastPathComponent)\n\n"
    md += "Duration \(String(format: "%.1f", dur))s · \(probe.width)x\(probe.height) · noise σ \(String(format: "%.2f", noise))\n\n"
    md += "## Automated findings\n" + (issues.isEmpty ? "None.\n" : issues.map { "- **\($0["severity"]!)** [\($0["area"]!)] \($0["message"]!) → \($0["fix"]!)" }.joined(separator: "\n") + "\n")
    md += "\n## Look at these, then score each line 1-5 (ship only when every line is 4+)\n"
    md += rubric.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n## Images\n"
    md += images.map { "- \($0["what"] as? String ?? ""): \($0["file"] as? String ?? "")" }.joined(separator: "\n") + "\n"
    try md.write(to: outDir.appendingPathComponent("REVIEW.md"), atomically: true, encoding: .utf8)
    let out: [String: Any] = ["ok": blockers == 0 && majors == 0, "render": video.path, "review": outDir.path, "blockers": blockers, "majors": majors,
                              "issues": issues, "images": images, "rubric": rubric, "noise": round3(noise),
                              "next": "Open sheet.jpg and every moments/*.jpg with your image tool. Score the rubric honestly. Fix every blocker/major and anything scoring under 4, re-render, and review again. Deliver only a clean pass."]
    try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: outDir.appendingPathComponent("review.json"))
    emit(out)
}

func latestRender(_ bundle: URL) -> URL? {
    let dir = Studio.locate(bundle).base.appendingPathComponent("renders")
    let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return items.filter { ["mp4", "mov"].contains($0.pathExtension) }
        .max { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
}

func bundleFor(render: URL) -> URL? {
    // <bundle>/renders/<file> → <bundle>
    let up = render.deletingLastPathComponent()
    if up.lastPathComponent == "renders" { return up.deletingLastPathComponent() }
    return nil
}

func projectName(_ bundle: URL?) -> String? {
    guard let b = bundle, let root = Home.projectsRoot?.standardizedFileURL.path, b.standardizedFileURL.path.hasPrefix(root + "/") else { return nil }
    return b.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
}

/// Noise estimate (σ in 8-bit levels) from the flattest blocks of a few frames.
/// Share of the first frame's pixels on a hard edge (text, UI): ~0 means a blank opening.
func frameDetail(_ video: URL) -> Double? {
    guard let data = try? Media.runData(Media.ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", video.path,
                                                       "-frames:v", "1", "-vf", "scale=360:-2,format=gray", "-f", "rawvideo", "-"]),
          data.count > 360 * 16 else { return nil }
    let w = 360, h = data.count / w, px = [UInt8](data)
    var edges = 0
    for y in 0..<h { for x in 0..<(w - 1) where abs(Int(px[y * w + x]) - Int(px[y * w + x + 1])) > 40 { edges += 1 } }
    return Double(edges) / Double(w * h)
}

func sampleNoise(_ video: URL, duration: Double) -> Double {
    var sigmas: [Double] = []
    for f in [0.2, 0.45, 0.7, 0.9] {
        let t = duration * f
        guard let data = try? Media.runData(Media.ffmpeg, ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", t), "-i", video.path,
                                                           "-frames:v", "1", "-vf", "scale=540:-2,format=gray", "-f", "rawvideo", "-"]),
              !data.isEmpty else { continue }
        let w = 540, h = data.count / w
        guard h > 16 else { continue }
        let px = [UInt8](data)
        var blockVars: [Double] = []
        var y = 0
        while y + 8 <= h {
            var x = 0
            while x + 8 <= w {
                // High-pass inside the block (pixel minus the mean of its row neighbours) so gradients don't count.
                var acc = 0.0, n = 0.0
                for yy in y..<(y + 8) {
                    for xx in (x + 1)..<(x + 7) {
                        let c = Double(px[yy * w + xx]), l = Double(px[yy * w + xx - 1]), r = Double(px[yy * w + xx + 1])
                        let d = c - (l + r) / 2
                        acc += d * d; n += 1
                    }
                }
                blockVars.append(acc / n)
                x += 8
            }
            y += 8
        }
        blockVars.sort()
        // The flattest third of the frame (backgrounds) tells us the noise floor.
        let k = max(1, blockVars.count / 3)
        let floor = blockVars[k / 2]
        sigmas.append(sqrt(floor / 1.5))
    }
    return sigmas.isEmpty ? 0 : sigmas.sorted()[sigmas.count / 2]
}

/// pretty shots <bundle> [-p preset]: render the project's 3D device shots now (otherwise they render on first frame/render).
func cmdShots(_ a: Args) throws {
    let studio = try Studio(url: try bundleArg(a))
    let settings = try ExportSettings.resolve(studio, overrides: overrides(a))
    guard !studio.project.shots.isEmpty else { emit(["ok": true, "shots": 0, "note": "no shots in this project (storyboard beats with \"shot\", or project.shots)"]); return }
    let comp = Composer(studio: studio, settings: settings)
    emit(["ok": comp.shotFrames.count == studio.project.shots.count, "shots": studio.project.shots.count, "rendered": comp.shotFrames.values.map(\.path),
          "blender": orNull(Shots.defaultTools?.blender)])
}
