import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit

/// Native screen capture with ScreenCaptureKit. The real cursor is hidden; the recorder
/// logs pointer telemetry instead so the renderer can draw a smooth, resizable one.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    public enum Target { case display(Int?), window(app: String, title: String?), region(CGRect, display: Int?) }

    public struct Result {
        public var video: URL
        public var events: InputEvents
        public var width: Int
        public var height: Int
        public var pointScale: Double
        public var title: String?
        public var keysCaptured: Bool
        public var duration: Double
    }

    let target: Target
    let outURL: URL
    let fps: Int
    let systemAudio: Bool
    let mic: Bool
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var micIn: AVAssetWriterInput?
    private var t0: Double?
    private var lastT: Double = 0
    private var monitor: InputMonitor?
    private let q = DispatchQueue(label: "pretty.capture")
    private var size = CGSize.zero
    private var scale: CGFloat = 2
    private var windowTitle: String?

    public init(target: Target, out: URL, fps: Int = 60, systemAudio: Bool = false, mic: Bool = false) {
        self.target = target; self.outURL = out; self.fps = fps; self.systemAudio = systemAudio; self.mic = mic
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        var origin = CGPoint.zero
        var windowID: CGWindowID? = nil

        func displayFor(_ idx: Int?) throws -> SCDisplay {
            let ds = content.displays
            guard !ds.isEmpty else { throw fail("no displays available (Screen Recording permission?)") }
            if let i = idx {
                if let d = ds.first(where: { Int($0.displayID) == i }) { return d }
                if i >= 0 && i < ds.count { return ds[i] }
                throw fail("display \(i) not found; displays: \(ds.map { "\($0.displayID) \($0.width)x\($0.height)" })")
            }
            let main = CGMainDisplayID()
            return ds.first { $0.displayID == main } ?? ds[0]
        }

        switch target {
        case .display(let idx):
            let d = try displayFor(idx)
            filter = SCContentFilter(display: d, excludingWindows: [])
            origin = CGDisplayBounds(d.displayID).origin
        case .region(let r, let idx):
            let d = try displayFor(idx)
            filter = SCContentFilter(display: d, excludingWindows: [])
            config.sourceRect = r
            origin = CGPoint(x: CGDisplayBounds(d.displayID).minX + r.minX, y: CGDisplayBounds(d.displayID).minY + r.minY)
        case .window(let app, let title):
            let candidates = content.windows.filter { w in
                let name = w.owningApplication?.applicationName.lowercased() ?? ""
                let bid = w.owningApplication?.bundleIdentifier.lowercased() ?? ""
                let okApp = name.contains(app.lowercased()) || bid.contains(app.lowercased())
                let okTitle = title.map { (w.title ?? "").lowercased().contains($0.lowercased()) } ?? true
                return okApp && okTitle && w.frame.width > 80 && w.frame.height > 80 && w.windowLayer == 0
            }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            guard let w = candidates.first else {
                let apps = Set(content.windows.compactMap { $0.owningApplication?.applicationName }).sorted()
                throw fail("no window for '\(app)'\(title.map { " titled '\($0)'" } ?? ""). Apps with windows: \(apps.joined(separator: ", "))")
            }
            filter = SCContentFilter(desktopIndependentWindow: w)
            origin = w.frame.origin
            windowID = w.windowID
            windowTitle = w.title
        }

        let info = SCShareableContent.info(for: filter)
        scale = CGFloat(info.pointPixelScale)
        var rectPts = info.contentRect.size
        if case .region(let r, _) = target { rectPts = r.size }
        size = CGSize(width: (rectPts.width * scale).rounded(), height: (rectPts.height * scale).rounded())
        config.width = Int(size.width); config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) { config.captureMicrophone = mic }
        if #available(macOS 14.2, *) { config.includeChildWindows = true }

        // Writer: HEVC handles 5K+ displays; high bitrate keeps text crisp for later zooms.
        let w = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let bitrate = Int(clamp(size.width * size.height * Double(fps) * 0.09, 8_000_000, 180_000_000))
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: fps,
                                              AVVideoMaxKeyFrameIntervalKey: fps],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        vin.expectsMediaDataInRealTime = true
        w.add(vin)
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        if systemAudio { let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings); a.expectsMediaDataInRealTime = true; w.add(a); audioIn = a }
        if mic { let m = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings); m.expectsMediaDataInRealTime = true; w.add(m); micIn = m }
        writer = w; videoIn = vin

        let mon = InputMonitor(mapping: .init(origin: origin, scale: scale))
        if let wid = windowID {
            mon.mappingProvider = { [scale] in
                guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
                      let b = list.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                return .init(origin: CGPoint(x: b["X"] ?? 0, y: b["Y"] ?? 0), scale: scale)
            }
        }
        monitor = mon

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q) }
        if #available(macOS 15.0, *), mic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q) }
        stream = s
        mon.start()
        try await s.startCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        switch type {
        case .screen:
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = atts.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete else { return }
            if t0 == nil {
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
                t0 = CMTimeGetSeconds(pts)
            }
            lastT = CMTimeGetSeconds(pts)
            if videoIn?.isReadyForMoreMediaData == true { videoIn?.append(sb) }
        case .audio:
            if t0 != nil, audioIn?.isReadyForMoreMediaData == true { audioIn?.append(sb) }
        default:
            if t0 != nil, micIn?.isReadyForMoreMediaData == true { micIn?.append(sb) }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.warn("capture stopped: \(error.localizedDescription)")
    }

    public func stop() async throws -> Result {
        try? await stream?.stopCapture()
        monitor?.stop()
        guard let writer, let t0 else { throw fail("no frames were captured (is the target visible? Screen Recording permission?)") }
        // Hold the last frame so the file ends where the recording stopped.
        let end = InputMonitor.hostNow()
        writer.endSession(atSourceTime: CMTime(seconds: max(lastT, end), preferredTimescale: 600))
        videoIn?.markAsFinished(); audioIn?.markAsFinished(); micIn?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw fail("writer failed: \(writer.error?.localizedDescription ?? "?")") }
        let ev = monitor?.events(t0: t0, width: size.width, height: size.height, pointScale: Double(scale)) ?? InputEvents()
        return Result(video: outURL, events: ev, width: Int(size.width), height: Int(size.height), pointScale: Double(scale),
                      title: windowTitle, keysCaptured: monitor?.keysAvailable ?? false, duration: max(lastT, end) - t0)
    }
}
