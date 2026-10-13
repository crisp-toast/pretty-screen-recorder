import Foundation
import CoreGraphics

public struct CameraState {
    public var zoom: CGFloat
    public var center: CGPoint
    /// 0 when not zoomed, 1 when fully at a zoom segment's level (for camera-bubble shrink).
    public var zoomAmount: CGFloat
}

/// The virtual camera, simulated once over the whole OUTPUT timeline with springs
/// (log-space zoom, linear pan). Deterministic: the same project always renders the same.
public final class CameraTrack {
    public static let hz: Double = 240
    public let duration: Double
    private var zs: [Float] = []
    private var cxs: [Float] = []
    private var cys: [Float] = []
    private var amounts: [Float] = []

    public struct Placed { public var start: Double; public var end: Double; public var seg: ZoomSegment }
    public private(set) var placed: [Placed] = []

    public init(layout: StageLayout, zoom: ZoomSpec, motion: MotionSpec, map: TimeMap, cursor: CursorTrack?, fullVideoSize: CGSize) {
        duration = max(map.outputDuration, 0.01)
        let n = Int(duration * Self.hz) + 2
        let W = layout.outputSize.width, H = layout.outputSize.height
        let base = layout.baseZoom
        let bounds = layout.cameraBounds

        // Place zoom segments on the output timeline.
        for seg in zoom.segments where seg.end > seg.start && seg.level > 1.001 {
            for (a, b) in map.outputRanges(source: seg.start, seg.end) where b - a > 0.05 {
                placed.append(Placed(start: a, end: b, seg: seg))
            }
        }
        placed.sort { $0.start < $1.start }

        let dynamic = motion.zoomAnimation == "dynamic"
        let zoomResp = dynamic ? 0.62 : 1.05, zoomDamp = dynamic ? 0.78 : 1.0
        let panResp = dynamic ? 0.55 : 0.85, panDamp = dynamic ? 0.82 : 1.0
        let wz = 2 * Double.pi / zoomResp, wp = 2 * Double.pi / panResp

        func clampCenter(_ c: CGPoint, _ z: CGFloat) -> CGPoint {
            let hw = W / (2 * z), hh = H / (2 * z)
            let x = bounds.width <= hw * 2 ? bounds.midX : clamp(c.x, bounds.minX + hw, bounds.maxX - hw)
            let y = bounds.height <= hh * 2 ? bounds.midY : clamp(c.y, bounds.minY + hh, bounds.maxY - hh)
            return CGPoint(x: x, y: y)
        }
        func cursorStage(_ t: Double) -> CGPoint? {
            guard let cursor, cursor.hasData else { return nil }
            return layout.stagePoint(cursor.position(at: map.source(atOutput: t)))
        }

        var L = Double(log(base)), vL = 0.0
        let home = clampCenter(CGPoint(x: W / 2, y: H / 2), base)
        var cx = Double(home.x), cy = Double(home.y), vx = 0.0, vy = 0.0
        var follow = home
        var activeID: String? = nil
        let dt = 1 / Self.hz
        let dz = CGFloat(clamp(zoom.followDeadzone, 0, 0.9))

        zs.reserveCapacity(n); cxs.reserveCapacity(n); cys.reserveCapacity(n); amounts.reserveCapacity(n)
        var pi = 0
        for i in 0..<n {
            let t = Double(i) * dt
            while pi < placed.count && placed[pi].end < t { pi += 1 }
            // Active segment, or a short gap between two segments (connected zooms pan instead of bouncing out).
            var active: Placed? = nil
            if pi < placed.count && placed[pi].start <= t { active = placed[pi] }
            else if pi > 0 && pi < placed.count && placed[pi].start - placed[pi - 1].end < 0.4 && t > placed[pi - 1].end {
                active = placed[pi - 1]
            }
            var targetZ = base
            var target = CGPoint(x: W / 2, y: H / 2)
            if let a = active {
                // Levels are relative to the contained view; in cover framing only push in further.
                targetZ = max(base, CGFloat(a.seg.level))
                if activeID != a.seg.id {
                    // Entering a segment: start from its focus, else from where the cursor is.
                    if let f = a.seg.focus { follow = layout.stagePoint(normalized: f, fullSize: fullVideoSize) }
                    else if let c = cursorStage(a.start + 0.6) ?? cursorStage(t) { follow = c }
                    activeID = a.seg.id
                }
                if a.seg.mode == "manual", let f = a.seg.focus {
                    target = layout.stagePoint(normalized: f, fullSize: fullVideoSize)
                } else {
                    if let c = cursorStage(t) {
                        let hw = W / (2 * targetZ) * dz, hh = H / (2 * targetZ) * dz
                        if c.x > follow.x + hw { follow.x = c.x - hw }
                        if c.x < follow.x - hw { follow.x = c.x + hw }
                        if c.y > follow.y + hh { follow.y = c.y - hh }
                        if c.y < follow.y - hh { follow.y = c.y + hh }
                    }
                    follow = clampCenter(follow, targetZ)
                    target = follow
                }
            } else {
                activeID = nil
                if layout.cover, let c = cursorStage(t) {
                    // Cover framing: keep following the action at the base zoom.
                    let hw = W / (2 * targetZ) * dz, hh = H / (2 * targetZ) * dz
                    if c.x > follow.x + hw { follow.x = c.x - hw }
                    if c.x < follow.x - hw { follow.x = c.x + hw }
                    if c.y > follow.y + hh { follow.y = c.y - hh }
                    if c.y < follow.y - hh { follow.y = c.y + hh }
                    follow = clampCenter(follow, targetZ)
                    target = follow
                } else {
                    follow = clampCenter(CGPoint(x: W / 2, y: H / 2), targetZ)
                }
            }
            target = clampCenter(target, targetZ)
            let tL = Double(log(targetZ))
            if i == 0 { L = tL; cx = Double(target.x); cy = Double(target.y) }

            // Semi-implicit Euler springs.
            vL += (wz * wz * (tL - L) - 2 * zoomDamp * wz * vL) * dt; L += vL * dt
            vx += (wp * wp * (Double(target.x) - cx) - 2 * panDamp * wp * vx) * dt; cx += vx * dt
            vy += (wp * wp * (Double(target.y) - cy) - 2 * panDamp * wp * vy) * dt; cy += vy * dt

            let z = max(base * 0.98, CGFloat(exp(L)))
            let c = clampCenter(CGPoint(x: cx, y: cy), max(z, 1))
            zs.append(Float(z)); cxs.append(Float(c.x)); cys.append(Float(c.y))
            let lvl = active.map { max(base, CGFloat($0.seg.level)) } ?? base * 1.5
            amounts.append(Float(clamp((z - base) / max(lvl - base, 0.2), 0, 1)))
        }
    }

    public func state(at t: Double) -> CameraState {
        let f = clamp(t, 0, duration) * Self.hz
        let i = min(Int(f), zs.count - 2), w = Float(f - Double(i))
        func s(_ a: [Float]) -> CGFloat { CGFloat(a[i] * (1 - w) + a[i + 1] * w) }
        return CameraState(zoom: s(zs), center: CGPoint(x: s(cxs), y: s(cys)), zoomAmount: s(amounts))
    }

    /// Stage → output transform (top-left coordinates).
    public static func transform(_ st: CameraState, output: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: output.width / 2, y: output.height / 2)
            .scaledBy(x: st.zoom, y: st.zoom)
            .translatedBy(x: -st.center.x, y: -st.center.y)
    }
}
