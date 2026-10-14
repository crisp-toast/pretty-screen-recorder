import Foundation
import PrettyCore

/// pretty brand <https://site | /path/to/app-or-web-project | icon.png> [-o dir] [--name N] [--tagline T] [--cta C] [--colors #a,#b]
func cmdBrand(_ a: Args) throws {
    let target = try a.requirePos(0, "website URL, project folder, or icon image")
    let dir: URL
    if let o = a.str("out") { dir = url(o) }
    else if let root = Home.projectsRoot {
        let slug = Home.slug(a.str("project") ?? a.str("name") ?? URL(string: target)?.host?.replacingOccurrences(of: "www.", with: "").split(separator: ".").first.map(String.init)
                             ?? URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent)
        dir = root.appendingPathComponent(slug).appendingPathComponent("marketing/brand")
    } else { dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("brand") }
    var r = try BrandKit.extract(target, into: dir)
    if let n = a.str("name") { r.brand.name = n }
    if let t = a.str("tagline") { r.brand.tagline = t }
    if let c = a.str("cta") { r.brand.cta = c }
    if let cs = a.str("colors") { r.brand.colors = cs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    if let f = a.str("font") { r.brand.font = f }
    if let i = a.str("icon") {
        let src = url(i), dst = dir.appendingPathComponent("icon." + src.pathExtension)
        try? FileManager.default.removeItem(at: dst); try FileManager.default.copyItem(at: src, to: dst)
        r.brand.icon = dst.lastPathComponent
    }
    if r.brand.cta == nil, let u = r.brand.url { r.brand.cta = u }
    let file = dir.appendingPathComponent("brand.json")
    try prettyJSON(r.brand).write(to: file)
    var notes = r.notes
    if r.brand.tagline == nil { notes.append("no tagline found — add the product's own one-line promise (brand.tagline)") }
    notes.append("Review it: these colors, icon and promise dress every scene, headline and the end card. Use it with \"brand\": \"\(file.path)\" in a storyboard.")
    emit(["ok": true, "brand": file.path, "name": orNull(r.brand.name), "tagline": orNull(r.brand.tagline), "colors": r.brand.colors,
          "icon": orNull(r.brand.icon.map { dir.appendingPathComponent($0).path }), "logo": orNull(r.brand.logo), "font": orNull(r.brand.font),
          "cta": orNull(r.brand.cta), "sources": r.sources, "notes": notes])
}

/// pretty lint <storyboard.json> [-p preset]: generic copy, overlong hooks, missing lockup.
func cmdLint(_ a: Args) throws {
    let sbURL = url(try a.requirePos(0, "storyboard.json"))
    guard let sb = try JSONSerialization.jsonObject(with: Data(contentsOf: sbURL)) as? [String: Any] else { throw fail("storyboard must be a JSON object") }
    var brand: BrandSpec? = nil
    if let bp = sb["brand"] as? String, let d = try? Data(contentsOf: Backgrounds.resolve(bp, sbURL.deletingLastPathComponent())) {
        brand = try? JSONDecoder().decode(BrandSpec.self, from: d)
    } else if let bd = sb["brand"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: bd) {
        brand = try? JSONDecoder().decode(BrandSpec.self, from: d)
    }
    let issues = Director.lintCopy(sb, brand: brand, preset: a.str("preset") ?? (sb["preset"] as? String))
    emit(["ok": issues.isEmpty, "issues": issues,
          "brief": "Tailor every line: name the product's own nouns (screens, numbers, card names), show the result on screen as it's said, one idea per beat, a ≤7-word hook, and end on a lockup with the product's real promise."])
}

/// pretty compose <storyboard.json> [-o bundle] [-p preset]: a video made only of scenes (no recording) —
/// teasers, intros, end cards, App Store "words" frames. Every beat must be a `scene`.
func cmdCompose(_ a: Args) throws {
    let sbURL = url(try a.requirePos(0, "storyboard.json"))
    guard let sb = try JSONSerialization.jsonObject(with: Data(contentsOf: sbURL)) as? [String: Any] else { throw fail("storyboard must be a JSON object") }
    guard let beats = sb["beats"] as? [[String: Any]], !beats.isEmpty else { throw fail("compose needs \"beats\", each with a \"scene\"") }
    if let i = beats.firstIndex(where: { $0["scene"] == nil }) { throw fail("beat \(i) has no scene — compose makes type-only videos; use `pretty record web` for beats with actions") }
    let name = a.str("name") ?? (sb["name"] as? String) ?? sbURL.deletingPathExtension().lastPathComponent
    let bundle = try Home.newBundleURL(name: name, project: a.str("project") ?? (sb["project"] as? String), out: a.str("out"))
    try Home.prepareTarget(bundle, force: a.has("force"))
    let sources = bundle.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let preset = a.str("preset") ?? (sb["preset"] as? String)
    let project = a.str("project") ?? (sb["project"] as? String)
    var opts = Director.Options(preset: preset, assetsDir: sources, baseDir: sbURL.deletingLastPathComponent(), historyURL: Home.historyURL(project: project))
    if let seed = a.int("seed") { opts.seed = UInt64(seed) }
    let plan = try Director.plan(storyboard: sb, options: opts)
    try prettyJSON(plan).write(to: sources.appendingPathComponent("plan.json"))
    Log.info(Director.timeline(plan))
    var o = ProjectIO.NewOptions()
    o.kind = "card"; o.name = name; o.duration = plan.duration; o.preset = preset; o.look = a.str("look") ?? (sb["look"] as? String)
    try ProjectIO.create(at: bundle, o)
    var p = try ProjectIO.load(bundle)
    p.overlays = []
    Director.apply(plan, to: &p, beatMarkers: [], bundle: bundle)
    // Narration is placed in output time here (no recording to follow).
    p.audio.voiceover = p.audio.voiceover.map { var c = $0; c.time = "output"; return c }
    p.duration = plan.duration
    try ProjectIO.save(p, to: bundle)
    Director.remember(plan, name: name, historyURL: Home.historyURL(project: project))
    try summarize(bundle, extra: ["composed": true, "plan": sources.appendingPathComponent("plan.json").path, "mode": plan.mode,
                                  "duration": plan.duration, "scenes": plan.scenes?.count ?? 0, "warnings": plan.warnings, "credits": plan.credits ?? []])
}
