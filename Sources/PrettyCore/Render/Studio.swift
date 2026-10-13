import Foundation
import AVFoundation
import CoreImage

/// A project loaded from disk with everything derived from it (time map, cursor track, keystrokes).
public final class Studio {
    public let projectURL: URL
    public let baseURL: URL
    public var project: Project
    public let events: InputEvents
    public let videoURL: URL?
    public let cameraURL: URL?
    public let asset: AVURLAsset?
    /// Display size of the source video (after its preferred transform).
    public let videoSize: CGSize
    public let videoTransform: CGAffineTransform
    public let sourceDuration: Double
    public let sourceFPS: Double
    public let map: TimeMap
    public let cursor: CursorTrack
    public let keyItems: [KeystrokeItem]
    public let captions: [CaptionItem]
    public var hasVideo: Bool { videoURL != nil }

    /// `url` may be a .prettystudio bundle directory or a project.json file.
    public convenience init(url: URL) throws {
        let (projectURL, base) = Studio.locate(url)
        guard FileManager.default.fileExists(atPath: projectURL.path) else { throw fail("no project at \(projectURL.path)") }
        let data = try Data(contentsOf: projectURL)
        let project: Project
        do { project = try JSONDecoder().decode(Project.self, from: data) }
        catch { throw fail("project.json is invalid: \(describe(error))") }
        try self.init(project: project, projectURL: projectURL, baseURL: base)
    }

    public init(project: Project, projectURL: URL, baseURL: URL) throws {
        self.project = project
        self.projectURL = projectURL
        self.baseURL = baseURL
        func res(_ p: String?) -> URL? { p.map { Backgrounds.resolve($0, baseURL) } }

        videoURL = res(project.source.video)
        cameraURL = res(project.source.camera)
        if let v = videoURL {
            guard FileManager.default.fileExists(atPath: v.path) else { throw fail("source video missing: \(v.path)") }
            let a = AVURLAsset(url: v, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            asset = a
            guard let track = a.tracks(withMediaType: .video).first else { throw fail("no video track in \(v.lastPathComponent)") }
            let t = track.preferredTransform
            let r = CGRect(origin: .zero, size: track.naturalSize).applying(t)
            videoSize = CGSize(width: abs(r.width), height: abs(r.height))
            videoTransform = t
            sourceDuration = CMTimeGetSeconds(a.duration)
            sourceFPS = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 60)
        } else {
            asset = nil
            videoSize = CGSize(width: 1920, height: 1080)
            videoTransform = .identity
            sourceDuration = project.duration ?? 4
            sourceFPS = 60
        }

        var ev = InputEvents()
        if let e = res(project.source.events), FileManager.default.fileExists(atPath: e.path) {
            ev = try InputEvents.load(e)
        }
        if ev.width <= 0 { ev.width = videoSize.width; ev.height = videoSize.height }
        if ev.pointScale <= 0 { ev.pointScale = project.source.pointScale }
        // Events recorded at a different scale than the video (e.g. points) are rescaled.
        if abs(ev.width - videoSize.width) > 2, ev.width > 0, videoURL != nil {
            let sx = videoSize.width / ev.width, sy = videoSize.height / ev.height
            ev.mouse = ev.mouse.map { [$0[0], $0[1] * sx, $0[2] * sy] }
            ev.clicks = ev.clicks.map { var c = $0; c.x *= sx; c.y *= sy; return c }
            ev.scrolls = ev.scrolls.map { var s = $0; s.x = s.x.map { $0 * sx }; s.y = s.y.map { $0 * sy }; return s }
            ev.pointScale *= sx
            ev.width = videoSize.width; ev.height = videoSize.height
        }
        ev.sortAll()
        events = ev

        map = videoURL == nil ? TimeMap(duration: sourceDuration) : TimeMap(sourceDuration: sourceDuration, timeline: project.timeline)
        let touch = project.cursor.style == "touch"
        cursor = CursorTrack(events: ev, duration: sourceDuration, spec: project.cursor, touch: touch)
        keyItems = Keystrokes.items(events: ev, spec: project.keystrokes)
        var caps = project.captions.items
        if let srt = res(project.captions.srt), let text = try? String(contentsOf: srt, encoding: .utf8) {
            caps += parseSRT(text)
        }
        captions = caps.sorted { $0.start < $1.start }
    }

    public static func locate(_ url: URL) -> (project: URL, base: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return (url.appendingPathComponent("project.json"), url)
        }
        return (url, url.deletingLastPathComponent())
    }

    public var outputDuration: Double { map.outputDuration }
    public var cropRect: CGRect {
        guard let c = project.source.crop else { return CGRect(origin: .zero, size: videoSize) }
        return CGRect(x: c.x * videoSize.width, y: c.y * videoSize.height, width: c.w * videoSize.width, height: c.h * videoSize.height).integral
    }

    public func resolve(_ path: String) -> URL { Backgrounds.resolve(path, baseURL) }
}

func describe(_ error: Error) -> String {
    if let e = error as? DecodingError {
        switch e {
        case .typeMismatch(let t, let c): return "type mismatch for \(path(c)): expected \(t)"
        case .valueNotFound(let t, let c): return "missing value for \(path(c)) (\(t))"
        case .keyNotFound(let k, let c): return "missing key '\(k.stringValue)' at \(path(c))"
        case .dataCorrupted(let c): return "corrupted JSON at \(path(c)): \(c.debugDescription)"
        @unknown default: return "\(e)"
        }
    }
    return "\(error)"
}

private func path(_ c: DecodingError.Context) -> String {
    let p = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    return p.isEmpty ? "(root)" : p
}
