import Foundation
import PrettyCore
import CoreGraphics
import CoreImage

func overrides(_ a: Args) -> ExportSpec {
    var e = ExportSpec()
    e.preset = a.str("preset")
    e.fps = a.int("fps")
    e.quality = a.str("quality")
    e.format = a.str("format")
    e.codec = a.str("codec")
    e.resolution = a.str("resolution")
    e.width = a.int("width"); e.height = a.int("height")
    if a.has("no-audio") { e.audio = false }
    return e
}

func rendersDir(_ bundle: URL) throws -> URL {
    let d = Studio.locate(bundle).base.appendingPathComponent("renders")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func cmdFrame(_ a: Args) throws {
    let b = try bundleArg(a)
    let studio = try Studio(url: b)
    let settings = try ExportSettings.resolve(studio, overrides: overrides(a))
    var times: [Double] = []
    if let at = a.str("at") {
        times = at.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
    if times.isEmpty { times = [studio.outputDuration / 2] }
    let comp = Composer(studio: studio, settings: settings)
    let grabber = studio.videoURL.map { FrameGrabber(url: $0) }
    let cam = studio.cameraURL.map { FrameGrabber(url: $0) }
    var outs: [String] = []
    for (i, t) in times.enumerated() {
        guard let cg = Render.still(comp, at: t, grabber: grabber, camera: cam) else { throw fail("render failed at \(t)") }
        let out: URL
        if let o = a.str("out") {
            let u = url(o)
            out = times.count == 1 ? u : u.deletingPathExtension().appendingPathExtension("\(i).\(u.pathExtension.isEmpty ? "png" : u.pathExtension)")
        } else {
            out = try rendersDir(b).appendingPathComponent(String(format: "frame_%07.3f.png", t))
        }
        if out.pathExtension.lowercased() == "jpg" || out.pathExtension.lowercased() == "jpeg" { try writeJPEG(cg, to: out) } else { try writePNG(cg, to: out) }
        outs.append(out.path)
    }
    emit(["ok": true, "frames": outs, "size": "\(settings.width)x\(settings.height)", "times": times])
}

func cmdSheet(_ a: Args) throws {
    let b = try bundleArg(a)
    let studio = try Studio(url: b)
    var settings = try ExportSettings.resolve(studio, overrides: overrides(a))
    // Contact sheets don't need full resolution.
    let scale = min(1, 1280 / Double(max(settings.width, settings.height)))
    settings.width = even(Double(settings.width) * scale); settings.height = even(Double(settings.height) * scale)
    let count = a.int("count") ?? 12
    let cols = a.int("columns") ?? (settings.height > settings.width ? 6 : 4)
    let tw: CGFloat = settings.height > settings.width ? 260 : 420
    guard let cg = Render.sheet(studio, settings: settings, count: count, columns: cols, tileWidth: tw) else { throw fail("sheet failed") }
    let out = try a.str("out").map(url) ?? rendersDir(b).appendingPathComponent("sheet.jpg")
    try writeJPEG(cg, to: out, quality: 0.85)
    emit(["ok": true, "sheet": out.path, "frames": count, "duration": round3(studio.outputDuration)])
}

func cmdRender(_ a: Args) throws {
    let b = try bundleArg(a)
    let studio = try Studio(url: b)
    let settings = try ExportSettings.resolve(studio, overrides: overrides(a))
    let ext = settings.format == "gif" ? "gif" : settings.format == "webm" ? "webm" : (settings.format == "mov" || settings.codec == "prores") ? "mov" : "mp4"
    let out: URL
    if let o = a.str("out") { out = url(o) } else {
        let tag = settings.preset?.name ?? "\(settings.width)x\(settings.height)"
        out = Home.versioned(dir: try rendersDir(b), slug: "\(Home.slug(studio.project.name))_\(tag)", ext: ext)
    }
    for n in settings.notes { Log.warn(n) }
    Log.info("rendering \(settings.width)x\(settings.height) @\(settings.fps) \(settings.codec)/\(settings.format), \(String(format: "%.1f", studio.outputDuration))s → \(out.path)")
    let exporter = Exporter(studio: studio, settings: settings)
    var lastPct = -1
    exporter.progress = { p in
        let pct = Int(p * 100)
        if pct / 10 != lastPct / 10 || pct == 100 { Log.info("  \(pct)%"); lastPct = pct }
    }
    let r = try exporter.run(to: out)
    var obj: [String: Any] = ["ok": true, "output": r.output, "size": "\(r.width)x\(r.height)", "fps": r.fps, "duration": r.duration,
                              "frames": r.frames, "megabytes": round3(Double(r.sizeBytes) / 1_048_576), "renderSeconds": r.seconds]
    if !r.extra.isEmpty { obj["extra"] = r.extra }
    if !r.notes.isEmpty { obj["notes"] = r.notes }
    emit(obj)
}

func cmdPresets() {
    printJSON(["presets": Presets.all.map { p -> [String: Any] in
        var d: [String: Any] = ["name": p.name, "summary": p.summary, "fps": p.fps, "format": p.format, "codec": p.codec]
        if let w = p.width, let h = p.height { d["size"] = "\(w)x\(h)" }
        return d
    }])
}

func cmdLooks() {
    printJSON(["looks": ProjectIO.looks.map { ["name": $0.name, "summary": $0.summary] }])
}

func cmdBackgrounds(_ a: Args) throws {
    let names = Backgrounds.presets.map(\.name)
    if let sheet = a.str("sheet") {
        let tw = 320, th = 200, cols = 5, gap = 12, label = 28
        let rows = (names.count + cols - 1) / cols
        let W = cols * (tw + gap) + gap, H = rows * (th + gap + label) + gap
        let ctx = Render.context
        let tiles: [CGImage?] = names.map { n in
            var spec = BackgroundSpec(); spec.preset = n
            let img = Backgrounds.render(spec, size: CGSize(width: tw, height: th), brand: [], baseURL: nil)
            return ctx.createCGImage(img, from: CGRect(x: 0, y: 0, width: tw, height: th), format: .RGBA8, colorSpace: sRGB)
        }
        let cg = drawImage(width: W, height: H) { c in
            c.setFillColor(RGBA.hex("#18181B").cg); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let font = Fonts.font(name: nil, size: 15, weight: .semibold)
            for (i, t) in tiles.enumerated() {
                let x = gap + (i % cols) * (tw + gap), y = gap + (i / cols) * (th + gap + label)
                if let t {
                    c.saveGState(); c.addPath(roundedRect(CGRect(x: x, y: y, width: tw, height: th), 14)); c.clip()
                    c.translateBy(x: CGFloat(x), y: CGFloat(y + th)); c.scaleBy(x: 1, y: -1)
                    c.draw(t, in: CGRect(x: 0, y: 0, width: tw, height: th)); c.restoreGState()
                }
                drawLine(c, names[i], font: font, color: RGBA(1, 1, 1, 0.85), at: CGPoint(x: CGFloat(x + 4), y: CGFloat(y + th + label / 2 + 2)))
            }
        }!
        let out = url(sheet)
        try writeJPEG(cg, to: out, quality: 0.9)
        emit(["ok": true, "sheet": out.path, "backgrounds": names])
    } else {
        printJSON(["backgrounds": Backgrounds.presets.map { ["name": $0.name, "dark": $0.dark] },
                   "types": ["gradient", "color", "image", "blur", "none"]])
    }
}

func cmdGuide() throws {
    let g = Home.root.appendingPathComponent("docs/AGENT_GUIDE.md")
    guard let s = try? String(contentsOf: g, encoding: .utf8) else { throw fail("guide not found at \(g.path)") }
    print(s)
}

func cmdOpen(_ a: Args) throws {
    let b = try bundleArg(a)
    guard let app = Home.appBundle else { throw fail("editor app not found: run scripts/build.sh or install Pretty Studio.app") }
    let r = try Media.run("/usr/bin/open", ["-a", app.path, Studio.locate(b).base.path])
    emit(["ok": r.status == 0, "app": app.path])
}

/// Installed browsers Playwright can drive, as (channel, path). `chromium` = Playwright's own build.
func detectBrowsers() -> [(String, String)] {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    var found: [(String, String)] = []
    for (channel, app) in [("chrome", "Google Chrome.app"), ("chrome-beta", "Google Chrome Beta.app"), ("msedge", "Microsoft Edge.app")] {
        for dir in ["/Applications", "\(home)/Applications"] where fm.fileExists(atPath: "\(dir)/\(app)") {
            found.append((channel, "\(dir)/\(app)")); break
        }
    }
    let cache = ProcessInfo.processInfo.environment["PLAYWRIGHT_BROWSERS_PATH"].map { ($0 as NSString).expandingTildeInPath }
        ?? "\(home)/Library/Caches/ms-playwright"
    if let items = try? fm.contentsOfDirectory(atPath: cache), let c = items.filter({ $0.hasPrefix("chromium") }).sorted().last {
        found.append(("chromium", "\(cache)/\(c)"))
    }
    return found
}

func cmdDoctor() throws {
    var checks: [[String: Any]] = []
    func check(_ name: String, _ ok: Bool, _ detail: String, required: Bool = true) {
        checks.append(["check": name, "ok": ok, "detail": detail, "required": required])
    }
    check("ffmpeg", Media.which("ffmpeg") != nil, Media.which("ffmpeg") ?? "brew install ffmpeg")
    check("ffprobe", Media.which("ffprobe") != nil, Media.which("ffprobe") ?? "brew install ffmpeg")
    let node = Media.which("node")
    check("node", node != nil, node ?? "install Node.js (found via PATH, NVM, Volta, asdf or Homebrew)")
    let pw = Home.root.appendingPathComponent("web-recorder/node_modules/playwright-core").path
    check("playwright-core", FileManager.default.fileExists(atPath: pw), FileManager.default.fileExists(atPath: pw) ? pw : "cd web-recorder && npm install")
    let browsers = detectBrowsers()
    check("browser", !browsers.isEmpty, browsers.isEmpty
          ? "install Google Chrome, or run `npx playwright install chromium` in web-recorder/ (storyboard \"channel\": \"chromium\")"
          : browsers.map { "\($0.0): \($0.1)" }.joined(separator: "; ") + " — the recorder tries these in order unless the storyboard sets \"channel\"")
    let out = Home.projectsRoot
    check("default-output", out != nil, out.map { "\($0.path)/<project>/video" } ?? "none: pass -o <path> or set PRETTY_PROJECTS_DIR", required: false)
    check("screen-recording-permission", CGPreflightScreenCaptureAccess(), CGPreflightScreenCaptureAccess() ? "granted to the host app" :
          "needed only for `record screen`: grant Screen Recording to the app running pretty (System Settings → Privacy & Security)", required: false)
    let simctl = (try? Media.run("/usr/bin/xcrun", ["simctl", "help"]))?.status == 0
    check("simctl", simctl, simctl ? "available" : "needed only for `record sim`: install Xcode", required: false)
    let narr = Narrator.resolve(nil)
    check("narration", narr != nil, narr.map { "\($0.voiceName) — \($0.provider) \($0.model)" }
          ?? "off: \(Narrator.unavailableReason(nil)). Videos still work: on-screen type carries the story.", required: false)
    let lib = MusicLibrary.licensed().count
    let incompetech = AppSettings.load().music.useIncompetech
    check("music", incompetech || lib > 0, (incompetech ? "Kevin MacLeod catalog (CC BY 4.0, credited automatically)" : "catalog off")
          + (lib > 0 ? " + \(lib) licensed tracks" : "") + "; downloads go to \(Paths.musicLibrary.path)", required: false)
    check("gpu", MTLCreateSystemDefaultDeviceAvailable(), "Metal")
    let app = Home.appBundle?.path
    check("editor-app", app != nil, app ?? "run scripts/build.sh", required: false)
    let ok = checks.allSatisfy { ($0["ok"] as? Bool) == true || ($0["required"] as? Bool) == false }
    emit(["ok": ok, "home": Home.root.path, "checks": checks])
}

import Metal
func MTLCreateSystemDefaultDeviceAvailable() -> Bool { MTLCreateSystemDefaultDevice() != nil }
