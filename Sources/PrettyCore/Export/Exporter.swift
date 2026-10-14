import Foundation
import AVFoundation
import CoreImage
import Metal
import VideoToolbox

public struct ExportResult: Codable {
    public var output: String
    public var extra: [String] = []
    public var width: Int
    public var height: Int
    public var fps: Int
    public var duration: Double
    public var frames: Int
    public var sizeBytes: Int64
    public var seconds: Double
    public var notes: [String]
}

public enum Render {
    public static let context: CIContext = {
        let dev = MTLCreateSystemDefaultDevice()!
        return CIContext(mtlDevice: dev, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .name: "pretty-studio",
        ])
    }()

    /// Render a single still at output time `t`.
    public static func still(_ studio: Studio, settings: ExportSettings, at t: Double) -> CGImage? {
        let comp = Composer(studio: studio, settings: settings)
        return still(comp, at: t, grabber: studio.videoURL.map { FrameGrabber(url: $0) },
                     camera: studio.cameraURL.map { FrameGrabber(url: $0) })
    }

    public static func still(_ comp: Composer, at t: Double, grabber: FrameGrabber?, camera: FrameGrabber?) -> CGImage? {
        let studio = comp.studio
        let tt = clamp(t, 0, max(0, studio.outputDuration - 0.001))
        let s = studio.map.source(atOutput: tt)
        let src = grabber?.frame(at: s)
        let cam = camera?.frame(at: s + studio.project.camera.offset)
        let img = comp.render(t: tt, source: src, cameraFrame: cam)
        return context.createCGImage(img, from: CGRect(origin: .zero, size: comp.size), format: .RGBA8, colorSpace: sRGB)
    }

    /// Contact sheet: N frames across the timeline in a grid, labeled with times.
    public static func sheet(_ studio: Studio, settings: ExportSettings, count: Int, columns: Int, tileWidth: CGFloat = 480) -> CGImage? {
        let comp = Composer(studio: studio, settings: settings)
        let grabber = studio.videoURL.map { FrameGrabber(url: $0) }
        let cam = studio.cameraURL.map { FrameGrabber(url: $0) }
        let d = studio.outputDuration
        let times = (0..<count).map { d * (Double($0) + 0.5) / Double(count) }
        let tw = tileWidth, th = tileWidth * settings.size.height / settings.size.width
        let rows = Int(ceil(Double(count) / Double(columns)))
        let gap: CGFloat = 10, label: CGFloat = 26
        let W = CGFloat(columns) * (tw + gap) + gap, H = CGFloat(rows) * (th + gap + label) + gap
        let tiles = times.map { still(comp, at: $0, grabber: grabber, camera: cam) }
        return drawImage(width: Int(W), height: Int(H)) { ctx in
            ctx.setFillColor(RGBA.hex("#1A1A1D").cg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let font = Fonts.font(name: nil, size: 15, weight: .medium, mono: true)
            for (i, tile) in tiles.enumerated() {
                let c = i % columns, r = i / columns
                let x = gap + CGFloat(c) * (tw + gap), y = gap + CGFloat(r) * (th + gap + label)
                if let tile {
                    ctx.saveGState()
                    ctx.translateBy(x: x, y: y + th); ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tw, height: th))
                    ctx.restoreGState()
                }
                drawLine(ctx, String(format: "%@  (src %@)", formatTime(times[i]), formatTime(studio.map.source(atOutput: times[i]))),
                         font: font, color: RGBA(1, 1, 1, 0.75), at: CGPoint(x: x + 2, y: y + th + label / 2))
            }
        }
    }
}

public final class Exporter {
    let studio: Studio
    let settings: ExportSettings
    public var progress: ((Double) -> Void)?

    public init(studio: Studio, settings: ExportSettings) {
        self.studio = studio
        self.settings = settings
    }

    public func run(to out: URL) throws -> ExportResult {
        let started = Date()
        let fm = FileManager.default
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmpDir = out.deletingLastPathComponent().appendingPathComponent(".pretty-tmp-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let fmt = settings.format
        let videoOnly = tmpDir.appendingPathComponent(settings.codec == "prores" ? "video.mov" : "video.mp4")
        let frames = try renderVideo(to: videoOnly)

        var notes = settings.notes
        var extras: [String] = []
        let wantAudio = settings.audio && fmt != "gif"
        var muxed = videoOnly
        if wantAudio || settings.requireAudioTrack {
            let audio = tmpDir.appendingPathComponent("audio.m4a")
            let has = try AudioMix.render(studio: studio, to: audio, duration: studio.outputDuration, silentIfEmpty: settings.requireAudioTrack, includeContent: wantAudio,
                                         preset: settings.preset?.name)
            if has {
                muxed = tmpDir.appendingPathComponent("muxed." + (settings.codec == "prores" ? "mov" : "mp4"))
                var args = ["-i", videoOnly.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy"]
                args += settings.codec == "prores" ? ["-c:a", "pcm_s16le"] : ["-c:a", "copy"]
                args += ["-shortest", "-movflags", "+faststart", muxed.path]
                try Media.ffmpegRun(args)
            } else if wantAudio {
                notes.append("no audio sources; exported silent")
            }
        }

        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        switch fmt {
        case "gif":
            try Media.ffmpegRun(["-i", muxed.path, "-vf",
                                 "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                                 "-loop", "0", out.path])
        case "webm":
            try Media.ffmpegRun(["-i", muxed.path, "-c:v", "libvpx-vp9", "-b:v", "\(settings.bitrate / 2)", "-crf", "30", "-row-mt", "1",
                                 "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k", out.path])
        default:
            if muxed == videoOnly && settings.codec != "prores" {
                try Media.ffmpegRun(["-i", videoOnly.path, "-c", "copy", "-movflags", "+faststart", out.path])
            } else {
                try fm.moveItem(at: muxed, to: out)
            }
        }
        if settings.preset?.extraWebM == true && fmt == "mp4" {
            let webm = out.deletingPathExtension().appendingPathExtension("webm")
            try? fm.removeItem(at: webm)
            try Media.ffmpegRun(["-i", out.path, "-an", "-c:v", "libvpx-vp9", "-b:v", "\(settings.bitrate / 2)", "-crf", "32", "-row-mt", "1",
                                 "-deadline", "good", "-cpu-used", "4", webm.path])
            extras.append(webm.path)
            let poster = out.deletingPathExtension().appendingPathExtension("jpg")
            if let cg = Render.still(studio, settings: settings, at: min(0.5, studio.outputDuration / 2)) {
                try writeJPEG(cg, to: poster, quality: 0.85); extras.append(poster.path)
            }
        }
        // What this video must carry when it's published (music license, AI voice disclosure).
        if wantAudio {
            let credits = studio.credits(preset: settings.preset?.name)
            if !credits.lines.isEmpty {
                let f = out.deletingPathExtension().appendingPathExtension("credits.txt")
                let header = "Credits for \(out.lastPathComponent) — paste into the post/description when publishing.\n\n"
                try? (header + credits.text + "\n").write(to: f, atomically: true, encoding: .utf8)
                extras.append(f.path)
                if credits.onScreen != nil && studio.onScreenCredit(preset: settings.preset?.name) == nil {
                    notes.append("the music license requires credit: publish the lines in \(f.lastPathComponent)")
                }
            }
        }
        let size = (try? fm.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        return ExportResult(output: out.path, extra: extras, width: settings.width, height: settings.height, fps: settings.fps,
                            duration: round3(studio.outputDuration), frames: frames, sizeBytes: size,
                            seconds: round3(Date().timeIntervalSince(started)), notes: notes)
    }

    /// Render all frames to a video-only file. Returns frame count.
    func renderVideo(to url: URL) throws -> Int {
        let W = settings.width, H = settings.height, fps = settings.fps
        let comp = Composer(studio: studio, settings: settings)
        let total = max(1, Int((studio.outputDuration * Double(fps)).rounded()))

        let ranges = studio.map.segments.map { ($0.srcStart, $0.srcEnd) }
        let source = try studio.videoURL.map { try FrameSource(url: $0, ranges: ranges) }
        let camSource = try studio.cameraURL.map { try FrameSource(url: $0, ranges: ranges, offset: studio.project.camera.offset) }

        let fileType: AVFileType = settings.codec == "prores" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var props: [String: Any] = [:]
        let codec: AVVideoCodecType
        switch settings.codec {
        case "hevc", "h265":
            codec = .hevc
            props = [AVVideoAverageBitRateKey: settings.bitrate, AVVideoExpectedSourceFrameRateKey: fps,
                     AVVideoMaxKeyFrameIntervalKey: fps * 2, AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String]
        case "prores":
            codec = .proRes422HQ
        default:
            codec = .h264
            props = [AVVideoAverageBitRateKey: settings.bitrate, AVVideoExpectedSourceFrameRateKey: fps,
                     AVVideoMaxKeyFrameIntervalKey: fps * 2, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                     AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC]
        }
        var vs: [String: Any] = [
            AVVideoCodecKey: codec, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !props.isEmpty { vs[AVVideoCompressionPropertiesKey] = props }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw fail("cannot configure video writer") }
        writer.add(input)
        guard writer.startWriting() else { throw fail("writer failed: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)

        let ctx = Render.context
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        var lastReport = Date.distantPast
        for i in 0..<total {
            try autoreleasepool {
                let t = Double(i) / Double(fps)
                let s = studio.map.source(atOutput: t)
                let frame = source?.frame(at: s)
                let cam = camSource?.frame(at: s)
                let img = comp.render(t: t, source: frame, cameraFrame: cam)
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw fail("encoder failed: \(writer.error?.localizedDescription ?? "?")") }
                    usleep(1000)
                }
                guard let pool = adaptor.pixelBufferPool else { throw fail("no pixel buffer pool: \(writer.error?.localizedDescription ?? "?")") }
                var pbOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
                guard let pb = pbOut else { throw fail("pixel buffer allocation failed") }
                CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                ctx.render(img, to: pb, bounds: rect, colorSpace: sRGB)
                if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) {
                    throw fail("frame append failed: \(writer.error?.localizedDescription ?? "?")")
                }
            }
            if Date().timeIntervalSince(lastReport) > 0.5 || i == total - 1 {
                lastReport = Date()
                progress?(Double(i + 1) / Double(total))
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw fail("writing failed: \(writer.error?.localizedDescription ?? "?")") }
        return total
    }
}
