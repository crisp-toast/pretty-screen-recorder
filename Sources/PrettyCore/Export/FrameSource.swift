import Foundation
import AVFoundation
import CoreImage

/// Sequential frame access along the edited timeline. Opens one AVAssetReader per kept
/// segment so cut regions are never decoded.
public final class FrameSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let transform: CGAffineTransform
    let displaySize: CGSize
    let ranges: [(Double, Double)]
    let offset: Double
    let duration: Double

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var rangeIndex = -1
    private var current: (Double, CIImage)?
    private var next: (Double, CIImage)?
    private var exhausted = false

    /// `ranges`: source-time ranges that will be requested, in order. `offset` shifts the
    /// request time (for a camera clip that started slightly before/after the screen).
    public init(url: URL, ranges: [(Double, Double)], offset: Double = 0) throws {
        let info = try AssetInfo.load(url)
        guard let t = info.videoTrack else { throw fail("no video track in \(url.lastPathComponent)") }
        asset = info.asset
        track = t
        transform = info.transform
        displaySize = info.displaySize
        duration = info.duration
        self.offset = offset
        self.ranges = ranges.map { ($0.0 + offset, $0.1 + offset) }
    }

    private func open(_ i: Int) {
        reader?.cancelReading()
        reader = nil; output = nil; current = nil; next = nil; exhausted = false
        rangeIndex = i
        guard i < ranges.count else { exhausted = true; return }
        let (a, b) = ranges[i]
        let start = max(0, a - 0.25), end = min(duration, b + 0.1)
        guard end > start, let r = try? AVAssetReader(asset: asset) else { exhausted = true; return }
        r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                  end: CMTime(seconds: end, preferredTimescale: 60000))
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { exhausted = true; return }
        r.add(o)
        guard r.startReading() else { exhausted = true; return }
        reader = r; output = o
        next = read()
    }

    private func read() -> (Double, CIImage)? {
        guard let o = output, let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else {
            exhausted = true; return nil
        }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        var img = CIImage(cvPixelBuffer: pb)
        if !transform.isIdentity {
            img = img.transformed(by: transform)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        return (t, img)
    }

    /// Latest frame at or before source time `s` (plus offset).
    public func frame(at s: Double) -> CIImage? {
        let q = s + offset
        // Find which range we're in (ranges are visited in order).
        var target = max(rangeIndex, 0)
        while target < ranges.count - 1 && q > ranges[target].1 + 1e-3 { target += 1 }
        if target != rangeIndex || reader == nil { open(target) }
        while let n = next, n.0 <= q + 1e-4 {
            current = n
            next = read()
        }
        if current == nil, let n = next { return n.1 } // before first frame: show the first one
        return current?.1
    }

    deinit { reader?.cancelReading() }
}

/// Random access for single frames (stills, contact sheets, the editor).
public final class FrameGrabber {
    let gen: AVAssetImageGenerator
    public init(url: URL) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
    }
    public func frame(at s: Double) -> CIImage? {
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: max(0, s), preferredTimescale: 60000), actualTime: nil) else { return nil }
        return CIImage(cgImage: cg)
    }
}
