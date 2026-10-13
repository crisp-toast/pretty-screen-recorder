import Foundation
import PrettyCore

/// Locations: the install (repo) root and default output folders on Master Storage.
enum Home {
    static let masterStorage = "/Volumes/Master Storage"

    /// Repo root: $PRETTY_HOME, else walk up from the executable until web-recorder/ is found.
    static var root: URL {
        if let h = ProcessInfo.processInfo.environment["PRETTY_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("web-recorder/record.mjs").path) { return u }
            u = u.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "\(masterStorage)/Code/pretty-screen-recorder")
    }

    static var recorderScript: URL { root.appendingPathComponent("web-recorder/record.mjs") }

    static var masterStorageMounted: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: masterStorage + "/Projects", isDirectory: &isDir) && isDir.boolValue
    }

    /// Default folder for new recordings: Master Storage/Projects/<project>/video
    static func videoDir(project: String) throws -> URL {
        guard masterStorageMounted else {
            throw fail("Master Storage is not mounted; pass -o <path> explicitly")
        }
        let u = URL(fileURLWithPath: "\(masterStorage)/Projects/\(project)/video")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let parts = s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(parts).split(separator: "-").joined(separator: "-").prefix(48).description
    }

    /// `<dir>/<date>_<slug>_vNN.<ext>` with NN bumped past existing files (never overwrite deliverables).
    static func versioned(dir: URL, slug: String, ext: String) -> URL {
        let base = "\(today())_\(slug)"
        var n = 1
        while true {
            let u = dir.appendingPathComponent(String(format: "%@_v%02d.%@", base, n, ext))
            if !FileManager.default.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    /// Make sure recording into `bundle` won't clobber an existing project. With `force`, the
    /// old recording (project.json + sources/) is removed first; renders/ are kept.
    static func prepareTarget(_ bundle: URL, force: Bool) throws {
        let pj = bundle.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: pj.path) else { return }
        guard force else {
            throw fail("\(bundle.path) already has a project. Use a new -o path, or --force to replace its recording (renders/ are kept).")
        }
        try FileManager.default.removeItem(at: pj)
        try? FileManager.default.removeItem(at: bundle.appendingPathComponent("sources"))
    }

    static func newBundleURL(name: String, project: String?, out: String?) throws -> URL {
        if let out {
            var u = url(out)
            if u.pathExtension != ProjectIO.bundleExtension { u = u.appendingPathExtension(ProjectIO.bundleExtension) }
            return u
        }
        let dir = try videoDir(project: project ?? "pretty-studio")
        var b = dir.appendingPathComponent("\(today())_\(slug(name)).prettystudio")
        var n = 2
        while FileManager.default.fileExists(atPath: b.path) {
            b = dir.appendingPathComponent("\(today())_\(slug(name))-\(n).prettystudio"); n += 1
        }
        return b
    }
}
