import Foundation
import CoreGraphics

public struct ExportPreset {
    public var name: String
    public var summary: String
    public var width: Int? = nil
    public var height: Int? = nil
    /// Short-side resolution when size is derived from the project's aspect.
    public var shortSide: Int? = nil
    public var fps: Int = 60
    public var format: String = "mp4"
    public var codec: String = "h264"
    public var quality: String = "high"
    public var audio: Bool = true
    /// Platforms that reject files without an audio track (App Store previews).
    public var requireAudioTrack: Bool = false
    public var maxDuration: Double? = nil
    public var minDuration: Double? = nil
    public var extraWebM: Bool = false
    /// Platform UI overlay zones to keep text out of (fractions: top, bottom, left, right).
    public var safe: [Double] = [0, 0, 0, 0]
}

extension ExportPreset {
    /// Vertical short-video presets: TikTok/Reels/Shorts UI covers ~220px top, ~380px bottom, ~120px right of 1920x1080.
    init(name: String, safeZone: Bool, summary: String, width: Int, height: Int, fps: Int) {
        self.init(name: name, summary: summary, width: width, height: height, fps: fps)
        if safeZone { safe = [0.115, 0.2, 0.04, 0.11] }
    }
}

public enum Presets {
    public static let all: [ExportPreset] = [
        ExportPreset(name: "youtube", summary: "16:9 1920x1080 60fps H.264 — YouTube, website embeds, demos", width: 1920, height: 1080),
        ExportPreset(name: "youtube-4k", summary: "16:9 3840x2160 60fps — crisp product walkthroughs", width: 3840, height: 2160),
        ExportPreset(name: "tiktok", safeZone: true, summary: "9:16 1080x1920 30fps — TikTok / Reels / Shorts (keep text out of top 220px, bottom 380px)", width: 1080, height: 1920, fps: 30),
        ExportPreset(name: "reels", safeZone: true, summary: "alias of tiktok", width: 1080, height: 1920, fps: 30),
        ExportPreset(name: "shorts", safeZone: true, summary: "alias of tiktok", width: 1080, height: 1920, fps: 30),
        ExportPreset(name: "instagram", summary: "4:5 1080x1350 30fps — Instagram / Facebook feed", width: 1080, height: 1350, fps: 30),
        ExportPreset(name: "square", summary: "1:1 1080x1080 30fps — feeds, LinkedIn, X", width: 1080, height: 1080, fps: 30),
        ExportPreset(name: "x", summary: "16:9 1920x1080 60fps — X / Twitter", width: 1920, height: 1080),
        ExportPreset(name: "linkedin", summary: "16:9 1920x1080 30fps", width: 1920, height: 1080, fps: 30),
        ExportPreset(name: "app-store-iphone", summary: "App Store app preview, iPhone portrait 886x1920 30fps, 15-30s, audio track required", width: 886, height: 1920, fps: 30, requireAudioTrack: true, maxDuration: 30, minDuration: 15),
        ExportPreset(name: "app-store-iphone-landscape", summary: "App Store app preview, iPhone landscape 1920x886 30fps", width: 1920, height: 886, fps: 30, requireAudioTrack: true, maxDuration: 30, minDuration: 15),
        ExportPreset(name: "app-store-ipad", summary: "App Store app preview, iPad 1200x1600 30fps", width: 1200, height: 1600, fps: 30, requireAudioTrack: true, maxDuration: 30, minDuration: 15),
        ExportPreset(name: "web-hero", summary: "16:9 1920x1080 30fps silent loop for landing pages (+ .webm + poster.jpg)", width: 1920, height: 1080, fps: 30, quality: "medium", audio: false, extraWebM: true),
        ExportPreset(name: "gif", summary: "Animated GIF, 960px wide, 15fps — READMEs, docs, replies", shortSide: 540, fps: 15, format: "gif", quality: "medium", audio: false),
        ExportPreset(name: "master", summary: "Original resolution, 60fps ProRes 422 HQ .mov — for further editing", shortSide: 0, fps: 60, format: "mov", codec: "prores", quality: "max"),
        ExportPreset(name: "preview", summary: "Fast 720p 30fps draft for quick review on a phone", shortSide: 720, fps: 30, quality: "low"),
        ExportPreset(name: "landscape", summary: "16:9 1080p 60fps (generic)", width: 1920, height: 1080),
        ExportPreset(name: "portrait", summary: "9:16 1080x1920 60fps (generic)", width: 1080, height: 1920),
    ]

    public static func named(_ n: String) -> ExportPreset? { all.first { $0.name == n.lowercased() } }
}

public struct ExportSettings {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var format: String
    public var codec: String
    public var quality: String
    public var bitrate: Int
    public var audio: Bool
    public var requireAudioTrack: Bool
    public var preset: ExportPreset?
    public var notes: [String] = []
    /// Text-safe area as fractions (top, bottom, left, right) from the preset.
    public var safe: [Double] { preset?.safe ?? [0, 0, 0, 0] }

    public var size: CGSize { CGSize(width: width, height: height) }

    /// Resolve the canvas for a studio. Precedence: CLI overrides > export.width/height >
    /// preset size > layout.aspect + resolution.
    public static func resolve(_ studio: Studio, overrides: ExportSpec = ExportSpec()) throws -> ExportSettings {
        let e = studio.project.export
        let presetName = overrides.preset ?? e.preset
        var preset: ExportPreset? = nil
        if let n = presetName {
            guard let pr = Presets.named(n) else {
                throw fail("unknown export preset '\(n)'. Run `pretty presets` for the list.")
            }
            preset = pr
        }
        let fps = overrides.fps ?? e.fps ?? preset?.fps ?? 60
        let format = (overrides.format ?? e.format ?? preset?.format ?? "mp4").lowercased()
        let codec = (overrides.codec ?? e.codec ?? preset?.codec ?? "h264").lowercased()
        let quality = (overrides.quality ?? e.quality ?? preset?.quality ?? "high").lowercased()
        let audio = overrides.audio ?? e.audio ?? preset?.audio ?? true

        var w = overrides.width ?? e.width, h = overrides.height ?? e.height
        let resolution = overrides.resolution ?? e.resolution
        if w == nil || h == nil {
            if resolution == nil, let pw = preset?.width, let ph = preset?.height {
                w = pw; h = ph
            } else {
                let short = shortSide(resolution ?? (preset?.shortSide.map { "\($0)" }) ?? "1080", studio: studio)
                let size = canvas(studio, shortSide: short)
                w = size.0; h = size.1
            }
        }
        var W = even(Double(w!)), H = even(Double(h!))
        if format == "gif" {
            // Keep GIFs reasonable.
            let maxSide = 960.0
            let s = min(1, maxSide / Double(max(W, H)))
            W = even(Double(W) * s); H = even(Double(H) * s)
        }
        let bpp: Double = ["low": 0.045, "medium": 0.075, "high": 0.11, "max": 0.2][quality] ?? 0.11
        var br = Double(W * H * fps) * bpp
        if codec == "hevc" { br *= 0.62 }
        br = clamp(br, 1_000_000, 160_000_000)
        var s = ExportSettings(width: W, height: H, fps: fps, format: format, codec: codec, quality: quality, bitrate: Int(br),
                               audio: audio, requireAudioTrack: preset?.requireAudioTrack ?? false, preset: preset)
        let d = studio.outputDuration
        if let mx = preset?.maxDuration, d > mx + 0.01 { s.notes.append("duration \(String(format: "%.1f", d))s exceeds \(preset!.name) max \(Int(mx))s — trim or cut") }
        if let mn = preset?.minDuration, d < mn - 0.01 { s.notes.append("duration \(String(format: "%.1f", d))s is below \(preset!.name) minimum \(Int(mn))s") }
        return s
    }

    static func shortSide(_ r: String, studio: Studio) -> Int {
        switch r.lowercased() {
        case "480p": return 480
        case "720p": return 720
        case "1080p": return 1080
        case "1440p", "2k": return 1440
        case "2160p", "4k": return 2160
        case "original":
            return 0
        default: return Int(r.filter(\.isNumber)) ?? 1080
        }
    }

    /// Output size from the project's aspect ("auto" wraps the framed recording with even padding).
    static func canvas(_ studio: Studio, shortSide: Int) -> (Int, Int) {
        let p = studio.project
        let crop = studio.cropRect
        let ftype = studio.hasVideo ? Frames.resolveType(p.frame, source: p.source, videoSize: crop.size) : "none"
        let frame = Frames.build(type: ftype, spec: p.frame, source: p.source, videoSize: crop.size, corners: p.layout.corners, border: false)
        let pad = clamp(p.layout.padding, 0, 0.45)
        let a = Double(frame.outerSize.width / max(frame.outerSize.height, 1))
        var R = Double(shortSide)
        if let ratio = parseAspect(p.layout.aspect) {
            if R == 0 { R = Double(min(frame.outerSize.width, frame.outerSize.height)) / (1 - 2 * pad) }
            R = min(R, 4320)
            return ratio >= 1 ? (even(R * ratio), even(R)) : (even(R), even(R / ratio))
        }
        if !studio.hasVideo { R = R == 0 ? 1080 : R; return (even(R * 16 / 9), even(R)) }
        let bands = clamp(p.layout.headroom, 0, 0.6) + clamp(p.layout.footroom, 0, 0.6)
        if a >= 1 {
            if R == 0 { R = Double(frame.outerSize.height) / max(0.1, 1 - 2 * pad - bands) }
            R = min(R, 4320)
            let H = R, W = a * H * max(0.1, 1 - 2 * pad - bands) + 2 * pad * H
            return (even(W), even(H))
        } else {
            if R == 0 { R = Double(frame.outerSize.width) / (1 - 2 * pad) }
            R = min(R, 4320)
            let W = R, H = (W * (1 - 2 * pad) / a + 2 * pad * W) / max(0.1, 1 - bands)
            return (even(W), even(H))
        }
    }
}
