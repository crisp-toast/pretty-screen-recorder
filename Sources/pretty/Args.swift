import Foundation
import PrettyCore

/// Tiny argument parser: positionals, `--key value`, `--key=value`, boolean `--flag`, `-o value`.
struct Args {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let booleans: Set<String> = [
        "json", "quiet", "manual", "auto", "reset", "force", "open", "help", "no-audio", "compress-idle", "idle", "zooms",
        "no-zoom", "dry-run", "detach", "all", "keep", "silent", "verbose", "dark", "light", "symlink", "no-auto", "mic",
        "system-audio", "list", "markdown", "camera", "stop", "status", "touch", "no-cursor", "replace", "clear",
        "pixels", "norm", "keep-status-bar", "card",
    ]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" { positionals += argv[(i + 1)...]; break }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if Args.booleans.contains(body) || i + 1 >= argv.count {
                    flags.insert(body)
                } else {
                    options[body] = argv[i + 1]; i += 1
                }
            } else if a == "-o" || a == "-p", i + 1 < argv.count {
                options[a == "-o" ? "out" : "preset"] = argv[i + 1]; i += 1
            } else if a == "-h" {
                flags.insert("help")
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    func has(_ f: String) -> Bool { flags.contains(f) }
    func str(_ k: String) -> String? { options[k] }
    func double(_ k: String) -> Double? { options[k].flatMap(Double.init) }
    func int(_ k: String) -> Int? { options[k].flatMap(Int.init) }
    func pos(_ i: Int) -> String? { i < positionals.count ? positionals[i] : nil }

    func requirePos(_ i: Int, _ what: String) throws -> String {
        guard let v = pos(i) else { throw fail("missing \(what)") }
        return v
    }

    /// "x,y" → point
    func point(_ k: String) -> NPoint? {
        guard let s = options[k] else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return p.count == 2 ? NPoint(x: p[0], y: p[1]) : nil
    }

    /// "x,y,w,h" → rect
    func rect(_ k: String) -> NRect? {
        guard let s = options[k] else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return p.count == 4 ? NRect(x: p[0], y: p[1], w: p[2], h: p[3]) : nil
    }
}

func url(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func emit(_ obj: [String: Any]) { printJSON(obj) }
