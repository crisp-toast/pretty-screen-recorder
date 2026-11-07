import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import CryptoKit

/// Renders `project.shots` — the recording's real screen on a 3D device, animated by a camera
/// template — with Blender (headless). A Rotato-style component: shots live inside a video and
/// hand off to the flat device. Frames are cached per shot, output size and content.
public enum Shots {
    /// Set once by the CLI / app (where the Blender script lives); used whenever a composer is built for an output.
    nonisolated(unsafe) public static var defaultTools: Tools? = nil

    public struct Tools {
        public var blender: String?
        public var blenderScript: URL
        public init(blender: String?, blenderScript: URL) { self.blender = blender; self.blenderScript = blenderScript }

        /// Find Blender on this Mac.
        public static func find(script: URL) -> Tools {
            var blender = ProcessInfo.processInfo.environment["PRETTY_BLENDER"]
            if blender == nil {
                for c in ["/Applications/Blender.app/Contents/MacOS/Blender", NSHomeDirectory() + "/Applications/Blender.app/Contents/MacOS/Blender"]
                where FileManager.default.isExecutableFile(atPath: c) { blender = c; break }
            }
            if blender == nil { blender = Media.which("blender") }
            return Tools(blender: blender, blenderScript: script)
        }
    }

    static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Make sure every shot has frames for this output; returns shot index → frames folder.
    public static func ensure(studio: Studio, size: CGSize, fps: Int, screenRect: CGRect, tools: Tools) throws -> [Int: URL] {
        var out: [Int: URL] = [:]
        let p = studio.project
        guard !p.shots.isEmpty else { return [:] }
        guard let video = studio.videoURL else { throw fail("3D shots need a recording (this project has no source video)") }
        let kind = p.source.kind
        guard ["ios", "mobile-web", "android"].contains(kind) else { throw fail("3D shots are for phone recordings (source.kind ios / mobile-web), not \(kind)") }
        let fm = FileManager.default
        // The renderer itself is part of the cache key: a changed script re-renders every shot.
        let scriptHash = (try? Data(contentsOf: tools.blenderScript)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined().prefix(10).description } ?? "none"
        for (i, sh) in p.shots.enumerated() {
            let frames = max(2, Int((sh.duration * Double(fps)).rounded()))
            let s0 = studio.map.source(atOutput: sh.start), s1 = studio.map.source(atOutput: sh.end)
            let finish = sh.finish ?? (p.frame.color == "auto" ? "black" : p.frame.color)
            let key = hash([sh.move, finish, String(sh.reflection), sh.focus.map { "\($0.x),\($0.y)" } ?? "", String(sh.offset ?? 0),
                            String(format: "%.3f,%.3f", s0, s1), "\(Int(size.width))x\(Int(size.height))@\(fps)",
                            String(format: "%.4f,%.4f", screenRect.height / size.height, screenRect.midY / size.height), video.lastPathComponent, scriptHash, "av1"])
            let dir = studio.baseURL.appendingPathComponent("shots/\(i)-\(key)")
            let last = dir.appendingPathComponent(String(format: "frame_%04d.png", frames))
            out[i] = dir
            if fm.fileExists(atPath: last.path) { continue }
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // The screen as it plays during the shot, frame for frame what the flat device shows (same
            // decoder, same time map — speed ramps included), so the hand-off has nothing to cross-fade.
            let crop = studio.cropRect
            let clip = dir.appendingPathComponent("screen.mp4")
            try screenClip(studio: studio, video: video, crop: crop, shot: sh, frames: frames, fps: fps, shift: 0, to: clip)
            // duo: a second screen from another moment of the take.
            var clip2: URL? = nil
            if sh.move == "duo" {
                let off = sh.offset ?? 2.5
                let shift = clamp(s0 + off, 0, max(0, studio.sourceDuration - (s1 - s0))) - s0
                let c2 = dir.appendingPathComponent("screen2.mp4")
                try screenClip(studio: studio, video: video, crop: crop, shot: sh, frames: frames, fps: fps, shift: shift, to: c2)
                clip2 = c2
            }
            Log.info("rendering 3D shot \(i + 1)/\(p.shots.count) (\(sh.move), \(frames) frames) with Blender…")
            guard let blender = tools.blender else { throw fail("Blender isn't installed — install it (brew install --cask blender) or set PRETTY_BLENDER") }
            var cfg: [String: Any] = ["screen": clip.path, "screen_size": [Int(crop.width), Int(crop.height)], "out_dir": dir.path,
                                      "width": Int(size.width), "height": Int(size.height), "fps": fps, "frames": frames, "move": sh.move,
                                      "end_height": Double(screenRect.height / size.height), "end_center_y": Double(screenRect.midY / size.height),
                                      "finish": finish, "samples": 48]
            if let f = sh.focus { cfg["focus"] = [f.x, f.y] }
            if let c2 = clip2 { cfg["screen2"] = c2.path }
            let cfgURL = dir.appendingPathComponent("shot.json")
            try JSONSerialization.data(withJSONObject: cfg, options: .prettyPrinted).write(to: cfgURL)
            let r = try Media.run(blender, ["-b", "--factory-startup", "--python", tools.blenderScript.path, "--", cfgURL.path])
            guard fm.fileExists(atPath: last.path) else {
                throw fail("Blender didn't finish the shot: \(String((r.err + r.out).split(separator: "\n").suffix(6).joined(separator: " ").prefix(600)))")
            }
            if let c2 = clip2 { try? fm.removeItem(at: c2) }
            try? fm.removeItem(at: clip)
        }
        // Drop renders of shots that no longer exist (moves or timing changed).
        let keep = Set(out.values.map { $0.lastPathComponent })
        let shotsDir = studio.baseURL.appendingPathComponent("shots")
        for d in (try? fm.contentsOfDirectory(at: shotsDir, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(d.lastPathComponent) {
            try? fm.removeItem(at: d)
        }
        return out
    }

    /// Writes the shot's screen as an mp4: each output frame's source frame through the time map,
    /// read with AVFoundation (ffmpeg can disagree with it on reordered HEVC simulator captures).
    static func screenClip(studio: Studio, video: URL, crop: CGRect, shot sh: DeviceShot, frames: Int, fps: Int, shift: Double, to out: URL) throws {
        let times = (0..<frames).map { studio.map.source(atOutput: sh.start + Double($0) / Double(fps)) + shift }
        let src = try FrameSource(url: video, ranges: [(times.min() ?? 0, (times.max() ?? 0) + 0.05)])
        let tmp = out.deletingLastPathComponent().appendingPathComponent("screen-frames")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ciCrop = CGRect(x: crop.minX, y: studio.videoSize.height - crop.maxY, width: crop.width, height: crop.height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var last: CIImage? = nil
        for (k, s) in times.enumerated() {
            guard let img = src.frame(at: s) ?? last else { throw fail("couldn't read the recording at \(String(format: "%.2f", s))s for the 3D shot") }
            last = img
            let framed = img.cropped(to: ciCrop).transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
            try Render.context.writeJPEGRepresentation(of: framed, to: tmp.appendingPathComponent(String(format: "f%04d.jpg", k + 1)), colorSpace: cs,
                                                       options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
        }
        try Media.ffmpegRun(["-framerate", String(fps), "-i", tmp.appendingPathComponent("f%04d.jpg").path, "-an",
                             "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", out.path])
    }
}
