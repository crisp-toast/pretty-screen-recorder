import Foundation

/// Maps output time (the final video) <-> source time (the raw recording),
/// after trim, cuts and speed changes.
public struct TimeMap {
    public struct Segment {
        public var srcStart: Double
        public var srcEnd: Double
        public var rate: Double
        public var outStart: Double
        public var outEnd: Double { outStart + (srcEnd - srcStart) / rate }
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

        var out = 0.0
        for (a, b, r) in pieces where b - a > 1e-5 {
            segments.append(Segment(srcStart: a, srcEnd: b, rate: r, outStart: out))
            out += (b - a) / r
        }
        if segments.isEmpty {
            segments = [Segment(srcStart: 0, srcEnd: max(sourceDuration, 0.001), rate: 1, outStart: 0)]
        }
    }

    /// Identity map for sources without cuts (or title cards).
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
        let s = seg.srcStart + (t - seg.outStart) * seg.rate
        return min(max(s, seg.srcStart), seg.srcEnd)
    }

    /// Output time for a source time. Times inside a cut snap to the next kept moment.
    public func output(atSource s: Double) -> Double {
        for seg in segments {
            if s < seg.srcStart { return seg.outStart }
            if s <= seg.srcEnd { return seg.outStart + (s - seg.srcStart) / seg.rate }
        }
        return outputDuration
    }

    /// Whether a source time survives the edit.
    public func isKept(source s: Double) -> Bool {
        segments.contains { s >= $0.srcStart && s <= $0.srcEnd }
    }

    /// Map a source range to output ranges (clipped to kept segments).
    public func outputRanges(source a: Double, _ b: Double) -> [(Double, Double)] {
        var r: [(Double, Double)] = []
        for seg in segments where seg.srcEnd > a && seg.srcStart < b {
            let s0 = max(a, seg.srcStart), s1 = min(b, seg.srcEnd)
            r.append((seg.outStart + (s0 - seg.srcStart) / seg.rate, seg.outStart + (s1 - seg.srcStart) / seg.rate))
        }
        // Merge touching ranges (a zoom spanning a cut stays one zoom).
        var merged: [(Double, Double)] = []
        for x in r {
            if let last = merged.last, x.0 - last.1 < 0.05 { merged[merged.count - 1].1 = x.1 } else { merged.append(x) }
        }
        return merged
    }

    /// Output time of each segment boundary (where a cut happens), for motion-blur guards.
    public var cutPoints: [Double] { segments.dropFirst().map { $0.outStart } }
}
