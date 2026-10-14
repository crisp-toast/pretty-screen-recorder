import Foundation

/// Maps output time (the final video) <-> source time (the raw recording),
/// after trim, cuts, speed changes and freeze-frame holds.
public struct TimeMap {
    public struct Segment {
        public var srcStart: Double
        public var srcEnd: Double
        /// Playback rate; 0 marks a freeze-frame hold (srcStart == srcEnd).
        public var rate: Double
        public var outStart: Double
        public var holdDuration: Double = 0
        public var isHold: Bool { rate == 0 }
        public var outDuration: Double { isHold ? holdDuration : (srcEnd - srcStart) / rate }
        public var outEnd: Double { outStart + outDuration }
    }

    public private(set) var segments: [Segment] = []
    public let sourceDuration: Double

    public var outputDuration: Double { segments.last?.outEnd ?? 0 }

    public init(sourceDuration: Double, timeline: TimelineSpec) {
        self.sourceDuration = sourceDuration
        let start = max(0, min(timeline.trimStart, sourceDuration))
        let end = min(sourceDuration, max(start, timeline.trimEnd ?? sourceDuration))

        // Kept ranges = [start, end] minus cuts.
        var kept: [(Double, Double)] = [(start, end)]
        for cut in timeline.cuts.sorted(by: { $0.start < $1.start }) where cut.end > cut.start {
            var next: [(Double, Double)] = []
            for (a, b) in kept {
                if cut.end <= a || cut.start >= b { next.append((a, b)); continue }
                if cut.start > a { next.append((a, cut.start)) }
                if cut.end < b { next.append((cut.end, b)) }
            }
            kept = next
        }
        kept = kept.filter { $0.1 - $0.0 > 1e-4 }

        // Split kept ranges by speed ranges.
        let speeds = timeline.speed.filter { $0.end > $0.start && $0.rate > 0 }.sorted { $0.start < $1.start }
        var pieces: [(Double, Double, Double)] = []
        for (a, b) in kept {
            var cursor = a
            for sp in speeds where sp.end > cursor && sp.start < b {
                let s0 = max(cursor, sp.start), s1 = min(b, sp.end)
                if s0 > cursor { pieces.append((cursor, s0, 1)) }
                pieces.append((s0, s1, sp.rate))
                cursor = s1
            }
            if cursor < b { pieces.append((cursor, b, 1)) }
        }

        // Insert holds (freeze-frames) at their source times, splitting pieces as needed.
        let holds = timeline.holds.filter { $0.duration > 0.001 }.sorted { $0.at < $1.at }
        var out = 0.0
        var hi = 0
        func emitHold(_ h: HoldRange) {
            segments.append(Segment(srcStart: h.at, srcEnd: h.at, rate: 0, outStart: out, holdDuration: h.duration))
            out += h.duration
        }
        for (a, b, r) in pieces where b - a > 1e-5 {
            var cur = a
            while hi < holds.count && holds[hi].at <= b + 1e-6 {
                let h = holds[hi]
                if h.at < a - 1e-6 { hi += 1; continue } // inside a cut: dropped
                if h.at > cur {
                    segments.append(Segment(srcStart: cur, srcEnd: h.at, rate: r, outStart: out))
                    out += (h.at - cur) / r
                    cur = h.at
                }
                emitHold(h)
                hi += 1
            }
            if b - cur > 1e-5 {
                segments.append(Segment(srcStart: cur, srcEnd: b, rate: r, outStart: out))
                out += (b - cur) / r
            }
        }
        if segments.isEmpty {
            segments = [Segment(srcStart: 0, srcEnd: max(sourceDuration, 0.001), rate: 1, outStart: 0)]
        }
    }

    /// Identity map for sources without edits (or title cards).
    public init(duration: Double) {
        sourceDuration = duration
        segments = [Segment(srcStart: 0, srcEnd: duration, rate: 1, outStart: 0)]
    }

    public func segmentIndex(forOutput t: Double) -> Int {
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].outStart <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func source(atOutput t: Double) -> Double {
        let seg = segments[segmentIndex(forOutput: t)]
        if seg.isHold { return seg.srcStart }
        let s = seg.srcStart + (t - seg.outStart) * seg.rate
        return min(max(s, seg.srcStart), seg.srcEnd)
    }

    /// Output time for a source time. Times inside a cut snap to the next kept moment;
    /// a time with a hold maps to the start of the hold.
    public func output(atSource s: Double) -> Double {
        for seg in segments {
            if s < seg.srcStart { return seg.outStart }
            if seg.isHold { if abs(s - seg.srcStart) < 1e-6 { return seg.outStart }; continue }
            if s <= seg.srcEnd { return seg.outStart + (s - seg.srcStart) / seg.rate }
        }
        return outputDuration
    }

    /// Whether a source time survives the edit.
    public func isKept(source s: Double) -> Bool {
        segments.contains { !$0.isHold && s >= $0.srcStart && s <= $0.srcEnd }
    }

    /// Map a source range to output ranges (clipped to kept segments, holds included).
    public func outputRanges(source a: Double, _ b: Double) -> [(Double, Double)] {
        var r: [(Double, Double)] = []
        for seg in segments {
            if seg.isHold {
                if seg.srcStart >= a && seg.srcStart <= b { r.append((seg.outStart, seg.outEnd)) }
                continue
            }
            guard seg.srcEnd > a && seg.srcStart < b else { continue }
            let s0 = max(a, seg.srcStart), s1 = min(b, seg.srcEnd)
            r.append((seg.outStart + (s0 - seg.srcStart) / seg.rate, seg.outStart + (s1 - seg.srcStart) / seg.rate))
        }
        r.sort { $0.0 < $1.0 }
        // Merge touching ranges (a zoom spanning a cut stays one zoom).
        var merged: [(Double, Double)] = []
        for x in r {
            if let last = merged.last, x.0 - last.1 < 0.05 { merged[merged.count - 1].1 = max(last.1, x.1) } else { merged.append(x) }
        }
        return merged
    }

    /// Output time of each segment boundary where the picture jumps (cuts), for motion-blur guards.
    public var cutPoints: [Double] {
        var pts: [Double] = []
        for (a, b) in zip(segments, segments.dropFirst()) where abs(a.srcEnd - b.srcStart) > 1e-3 { pts.append(b.outStart) }
        return pts
    }
}
