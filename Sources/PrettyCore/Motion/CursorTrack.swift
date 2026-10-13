import Foundation
import CoreGraphics

/// Rebuilt cursor motion in SOURCE time, sampled on a fixed grid.
///
/// Agent-driven recordings (computer use, scripted UI tests) teleport the pointer and
/// pause for seconds between actions. Human recordings wobble. Both look amateurish.
/// The track keeps every click exactly where and when it happened, but:
///   - smooth:  replaces every move with a minimum-jerk glide between resting points
///              (a gentle arc, bell-shaped speed), timed to arrive on time;
///   - natural: keeps human paths with light smoothing, but still turns teleports into glides;
///   - raw:     exactly as recorded.
public final class CursorTrack {
    public static let hz: Double = 240
    public let duration: Double
    public private(set) var xs: [Float] = []
    public private(set) var ys: [Float] = []
    public private(set) var vis: [Float] = []
    public let clicks: [ClickEvent]
    private let kinds: [CursorChange]
    public let hasData: Bool
    public let isTouch: Bool
    /// Detected resting points (start, end, x, y) for debugging.
    public private(set) var debugRests: [[Double]] = []

    public init(events: InputEvents, duration: Double, spec: CursorSpec, touch: Bool) {
        self.duration = max(duration, 0.01)
        self.clicks = events.clicks.sorted { $0.t < $1.t }
        self.kinds = events.cursors.sorted { $0.t < $1.t }
        self.isTouch = touch
        let n = Int(self.duration * Self.hz) + 2
        let ps = max(1, events.pointScale)

        var samples = events.mouse.filter { $0.count >= 3 }.sorted { $0[0] < $1[0] }
        // Clicks are ground truth: make sure the path passes through them.
        for c in clicks { samples.append([c.t, c.x, c.y]); samples.append([c.release, c.x, c.y]) }
        samples.sort { $0[0] < $1[0] }
        hasData = !samples.isEmpty

        guard hasData else {
            xs = [Float](repeating: Float(events.width / 2), count: n)
            ys = [Float](repeating: Float(events.height / 2), count: n)
            vis = [Float](repeating: 0, count: n)
            return
        }

        // 1. Raw path on the grid. Interpolate only across short gaps; across long gaps the
        //    pointer was sitting still (sparse logs only record changes).
        var rx = [Double](repeating: 0, count: n), ry = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = Double(i) / Self.hz
            while j + 1 < samples.count && samples[j + 1][0] <= t { j += 1 }
            let a = samples[j]
            if t < a[0] { rx[i] = a[1]; ry[i] = a[2]; continue }
            if j + 1 < samples.count {
                let b = samples[j + 1]
                let gap = b[0] - a[0]
                if gap > 0 && gap < 0.1 {
                    let f = (t - a[0]) / gap
                    rx[i] = a[1] + (b[1] - a[1]) * f; ry[i] = a[2] + (b[2] - a[2]) * f
                    continue
                }
            }
            rx[i] = a[1]; ry[i] = a[2]
        }

        // Drag intervals (button held while moving) keep their real path.
        var drags: [(Int, Int)] = []
        for c in clicks where c.release - c.t > 0.15 {
            let a = Int(c.t * Self.hz), b = min(n - 1, Int(c.release * Self.hz))
            if b > a {
                var moved = 0.0
                for i in a...b { moved = max(moved, hypot(rx[i] - c.x, ry[i] - c.y)) }
                if moved > 6 * ps { drags.append((a, b)) }
            }
        }
        func inDrag(_ i: Int) -> Bool { drags.contains { i >= $0.0 && i <= $0.1 } }

        var px = rx, py = ry
        // Touch indicators sit exactly on the taps (fingers don't glide between them).
        if spec.motion != "raw" && !touch {
            // 2. Resting points.
            struct Rest { var a: Int; var b: Int; var x: Double; var y: Double }
            var rests: [Rest] = []
            let eps = 3 * ps
            let minRest = Int(0.12 * Self.hz)
            var anchor = 0
            for i in 1...n {
                let moved = i == n || hypot(rx[i] - rx[anchor], ry[i] - ry[anchor]) > eps
                if moved {
                    if i - anchor >= minRest || anchor == 0 || i == n {
                        rests.append(Rest(a: anchor, b: i - 1, x: rx[i - 1], y: ry[i - 1]))
                    }
                    anchor = i
                }
            }
            // A click always defines a rest at its position.
            for c in clicks {
                let ci = min(n - 1, Int(c.t * Self.hz))
                if !rests.contains(where: { ci >= $0.a && ci <= $0.b }) {
                    rests.append(Rest(a: ci, b: ci, x: c.x, y: c.y))
                }
            }
            rests.sort { $0.a < $1.a }
            // Merge overlapping rests (adjacent rests are distinct: a teleport separates them).
            var merged: [Rest] = []
            for r in rests {
                if var last = merged.last, r.a <= last.b {
                    if r.b > last.b { last.b = r.b; last.x = r.x; last.y = r.y }
                    merged[merged.count - 1] = last
                } else { merged.append(r) }
            }
            // A rest's position: the click inside it if any (ground truth), else the median sample
            // (its first/last samples are still arriving/departing).
            for k in merged.indices {
                let r = merged[k]
                if let c = clicks.first(where: { Int($0.t * Self.hz) >= r.a && Int($0.t * Self.hz) <= r.b }) {
                    merged[k].x = c.x; merged[k].y = c.y
                } else if r.b > r.a {
                    let xsr = rx[r.a...r.b].sorted(), ysr = ry[r.a...r.b].sorted()
                    merged[k].x = xsr[xsr.count / 2]; merged[k].y = ysr[ysr.count / 2]
                }
            }
            rests = merged
            debugRests = rests.map { [round3(Double($0.a) / Self.hz), round3(Double($0.b) / Self.hz), round3($0.x), round3($0.y)] }

            if spec.motion == "natural" {
                px = gaussian(rx, sigma: 0.03 * Self.hz); py = gaussian(ry, sigma: 0.03 * Self.hz)
                for r in rests { for i in r.a...r.b { px[i] = r.x; py[i] = r.y } }
            } else {
                for r in rests { for i in r.a...r.b { px[i] = r.x; py[i] = r.y } }
            }

            // 3. Glides between consecutive rests.
            for k in 0..<max(0, rests.count - 1) {
                let r0 = rests[k], r1 = rests[k + 1]
                let d = hypot(r1.x - r0.x, r1.y - r0.y)
                if d < 1 { for i in r0.b...r1.a { px[i] = r0.x; py[i] = r0.y }; continue }
                let dPts = d / ps
                let want = clamp(0.24 + 0.17 * log2(1 + dPts / 45), 0.28, 0.95)
                let rawDur = Double(r1.a - r0.b) / Self.hz
                let isTeleport = rawDur < 0.07
                if spec.motion == "natural" && !isTeleport { continue }
                if (r0.b...r1.a).contains(where: inDrag) { continue }
                var start: Int, end = r1.a
                if rawDur >= want {
                    start = r0.b
                } else {
                    // Borrow time from the previous rest so we arrive exactly on time.
                    let borrowLimit = r0.a + Int(Double(r0.b - r0.a) * 0.35)
                    start = max(borrowLimit, r1.a - Int(want * Self.hz))
                    start = min(start, r0.b)
                }
                if end <= start { end = start + 1 }
                let len = Double(end - start)
                // Gentle arc: perpendicular offset proportional to distance.
                let dx = (r1.x - r0.x) / d, dy = (r1.y - r0.y) / d
                let bow = min(0.08 * d, 60 * ps) * (dx >= 0 ? -1 : 1)
                let c1 = (r0.x + (r1.x - r0.x) * 0.3 - dy * bow, r0.y + (r1.y - r0.y) * 0.3 + dx * bow)
                let c2 = (r0.x + (r1.x - r0.x) * 0.72 - dy * bow * 0.6, r0.y + (r1.y - r0.y) * 0.72 + dx * bow * 0.6)
                for i in start...min(end, n - 1) {
                    let u = smootherstep(pow(Double(i - start) / len, 0.9))
                    let a = 1 - u
                    px[i] = a * a * a * r0.x + 3 * a * a * u * c1.0 + 3 * a * u * u * c2.0 + u * u * u * r1.x
                    py[i] = a * a * a * r0.y + 3 * a * a * u * c1.1 + 3 * a * u * u * c2.1 + u * u * u * r1.y
                }
            }
            // Drags: lightly smoothed real path.
            if !drags.isEmpty {
                let gx = gaussian(rx, sigma: 0.02 * Self.hz), gy = gaussian(ry, sigma: 0.02 * Self.hz)
                for (a, b) in drags { for i in a...b { px[i] = gx[i]; py[i] = gy[i] } }
            }
        }
        if touch {
            // Each indicator lives at its own tap for its whole visible window (fade-in to fade-out);
            // swipes (held, moving touches) keep their real path.
            for c in clicks {
                let ia = max(0, Int((c.t - 0.16) * Self.hz)), ib = min(n - 1, Int((c.release + 0.26) * Self.hz))
                guard ib >= ia else { continue }
                let isSwipe = drags.contains { $0.0 <= Int(c.t * Self.hz) && Int(c.t * Self.hz) <= $0.1 }
                for i in ia...ib {
                    let t = Double(i) / Self.hz
                    if isSwipe && t >= c.t && t <= c.release { continue }
                    px[i] = isSwipe && t > c.release ? px[min(n - 1, Int(c.release * Self.hz))] : c.x
                    py[i] = isSwipe && t > c.release ? py[min(n - 1, Int(c.release * Self.hz))] : c.y
                }
            }
        }
        xs = px.map { Float($0) }
        ys = py.map { Float($0) }

        // 4. Visibility.
        var v = [Float](repeating: 1, count: n)
        if touch {
            // Touch indicators exist only around touches.
            v = [Float](repeating: 0, count: n)
            for c in clicks {
                let a = c.t - 0.12, b = c.release + 0.22
                let ia = max(0, Int(a * Self.hz)), ib = min(n - 1, Int(b * Self.hz))
                if ib < ia { continue }
                for i in ia...ib {
                    let t = Double(i) / Self.hz
                    let fin = clamp((t - a) / 0.12, 0, 1), fout = clamp((b - t) / 0.22, 0, 1)
                    v[i] = max(v[i], Float(min(fin, fout)))
                }
            }
        } else {
            if spec.hideWhenIdle {
                // Activity = movement or clicks. Fade out after idleDelay; fade back in just before moving.
                var active = [Bool](repeating: false, count: n)
                for i in 1..<n where abs(px[i] - px[i - 1]) + abs(py[i] - py[i - 1]) > 0.2 * ps { active[i] = true }
                for c in clicks { let i = min(n - 1, Int(c.t * Self.hz)); active[i] = true }
                var last = -1e9
                var nextActive = [Double](repeating: 1e9, count: n)
                var nxt = 1e9
                for i in stride(from: n - 1, through: 0, by: -1) { if active[i] { nxt = Double(i) / Self.hz }; nextActive[i] = nxt }
                for i in 0..<n {
                    let t = Double(i) / Self.hz
                    if active[i] { last = t }
                    let since = t - last - spec.idleDelay
                    let out = since > 0 ? clamp(1 - since / 0.3, 0, 1) : 1
                    let until = nextActive[i] - t
                    let back = clamp(1 - (until - 0.05) / 0.25, 0, 1)
                    v[i] = Float(max(out, back))
                }
            }
            if spec.hideWhileTyping && !events.keys.isEmpty {
                let typing = events.keys.filter { !$0.isShortcut }.map(\.t)
                var bursts: [(Double, Double)] = []
                for t in typing {
                    if let l = bursts.last, t - l.1 < 1.2 { bursts[bursts.count - 1].1 = t } else { bursts.append((t, t)) }
                }
                for (a, b) in bursts {
                    let ia = max(0, Int((a - 0.1) * Self.hz)), ib = min(n - 1, Int((b + 0.8) * Self.hz))
                    guard ib > ia else { continue }
                    for i in ia...ib {
                        let moving = i > 0 && abs(px[i] - px[i - 1]) + abs(py[i] - py[i - 1]) > 0.5 * ps
                        if moving { break }
                        let t = Double(i) / Self.hz
                        let f = min(clamp((t - (a - 0.1)) / 0.15, 0, 1), clamp(((b + 0.8) - t) / 0.2, 0, 1))
                        v[i] = min(v[i], Float(1 - f))
                    }
                }
            }
        }
        vis = v
    }

    @inline(__always) private func sample(_ arr: [Float], _ t: Double) -> Double {
        let f = clamp(t, 0, duration) * Self.hz
        let i = Int(f)
        if i >= arr.count - 1 { return Double(arr[arr.count - 1]) }
        let w = f - Double(i)
        return Double(arr[i]) * (1 - w) + Double(arr[i + 1]) * w
    }

    public func position(at s: Double) -> CGPoint {
        let f = clamp(s, 0, duration) * Self.hz
        let i = Int(f)
        if i < xs.count - 1 {
            // Never interpolate across a jump (raw teleports / taps): snap to the nearer sample.
            let jump = abs(xs[i + 1] - xs[i]) + abs(ys[i + 1] - ys[i])
            if jump > 40 {
                let k = f - Double(i) < 0.5 ? i : i + 1
                return CGPoint(x: Double(xs[k]), y: Double(ys[k]))
            }
        }
        return CGPoint(x: sample(xs, s), y: sample(ys, s))
    }
    public func visibility(at s: Double) -> Double { hasData ? sample(vis, s) : 0 }

    public func kind(at s: Double) -> String {
        var k = "arrow"
        for c in kinds { if c.t <= s { k = c.kind } else { break } }
        return k
    }

    /// 0 (released) … 1 (fully pressed), with quick attack and springy release.
    public func press(at s: Double) -> Double {
        var p = 0.0
        for c in clicks where c.t - 0.05 <= s && s <= c.release + 0.3 {
            if s < c.t { p = max(p, 1 - (c.t - s) / 0.05) }
            else if s <= c.release { p = max(p, 1) }
            else { p = max(p, 1 - easeOutCubic((s - c.release) / 0.3)) }
        }
        return clamp(p, 0, 1)
    }

    /// Active ripples at source time s: (click, progress 0-1).
    public func ripples(at s: Double, duration: Double = 0.55) -> [(ClickEvent, Double)] {
        clicks.compactMap { c in
            let p = (s - c.t) / duration
            return (p >= 0 && p <= 1) ? (c, p) : nil
        }
    }
}

/// Gaussian smoothing (edge-clamped).
func gaussian(_ x: [Double], sigma: Double) -> [Double] {
    guard sigma > 0.5, x.count > 2 else { return x }
    let r = Int(ceil(sigma * 3))
    var kernel = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
    let sum = kernel.reduce(0, +); kernel = kernel.map { $0 / sum }
    var out = x
    let n = x.count
    for i in 0..<n {
        var acc = 0.0
        for k in -r...r { acc += x[clamp(i + k, 0, n - 1)] * kernel[k + r] }
        out[i] = acc
    }
    return out
}
