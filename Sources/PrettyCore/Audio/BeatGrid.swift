import Foundation

/// A musical time grid on the OUTPUT timeline: beat k sits at firstBeat + k * period.
/// Used to land clicks on beats, start story beats on bar lines, and cut sequences on the beat.
public struct BeatGrid: Codable, Equatable {
    public var bpm: Double
    /// Output time of a downbeat (bar start). May be negative or beyond 0.
    public var firstBeat: Double
    public var beatsPerBar: Int = 4

    public init(bpm: Double, firstBeat: Double, beatsPerBar: Int = 4) {
        self.bpm = bpm; self.firstBeat = firstBeat; self.beatsPerBar = beatsPerBar
    }

    public var period: Double { 60 / bpm }
    public var bar: Double { period * Double(beatsPerBar) }

    /// Beat index (fractional) of time t.
    public func position(_ t: Double) -> Double { (t - firstBeat) / period }

    public func beat(_ k: Double) -> Double { firstBeat + k * period }

    /// First grid point at or after t, at the given subdivision (1 = beats, 2 = eighths).
    public func next(atOrAfter t: Double, subdivision: Int = 1) -> Double {
        let step = period / Double(max(1, subdivision))
        return firstBeat + (((t - firstBeat) / step) - 1e-6).rounded(.up) * step
    }

    public func nearest(_ t: Double, subdivision: Int = 1) -> Double {
        let step = period / Double(max(1, subdivision))
        return firstBeat + ((t - firstBeat) / step).rounded() * step
    }

    public func nextBar(atOrAfter t: Double) -> Double {
        firstBeat + (((t - firstBeat) / bar) - 1e-6).rounded(.up) * bar
    }

    /// Snap t to the nearest grid point if it is within `tolerance` seconds; otherwise leave it.
    public func snap(_ t: Double, tolerance: Double, subdivision: Int = 2) -> Double {
        let n = nearest(t, subdivision: subdivision)
        return abs(n - t) <= tolerance ? n : t
    }

    public func isDownbeat(_ t: Double) -> Bool {
        let p = (t - firstBeat) / bar
        return abs(p - p.rounded()) < 0.01
    }
}

// MARK: - Beat detection for supplied music

public enum BeatDetect {
    public struct Result: Codable {
        public var bpm: Double
        /// Seconds into the file of the first detected downbeat.
        public var firstBeat: Double
        /// 0-1: how periodic the onsets are (below ~0.3, don't trust the grid).
        public var confidence: Double
    }

    /// Estimate tempo and beat phase: spectral-flux onsets → autocorrelation with a tempo
    /// prior around 115 BPM → phase search → downbeat from accent strength.
    public static func analyze(_ url: URL, maxSeconds: Double = 90) throws -> Result {
        let sr = 11025.0
        let data = try Media.runData(Media.ffmpeg, ["-hide_banner", "-loglevel", "error", "-t", "\(maxSeconds)", "-i", url.path,
                                                    "-ac", "1", "-ar", "\(Int(sr))", "-f", "f32le", "-"])
        let samples: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard samples.count > Int(sr * 4) else { throw fail("music too short to analyze (need 4+ seconds)") }

        // Onset envelope: log-energy flux across four bands (biquad filterbank), hop ≈ 11.6 ms.
        let hop = 128
        let frames = samples.count / hop
        var bands = [Biquad.lowpass(sr: sr, hz: 160, q: 0.7), Biquad.bandpass(sr: sr, hz: 450, q: 0.9),
                     Biquad.bandpass(sr: sr, hz: 1600, q: 0.9), Biquad.highpass(sr: sr, hz: 3500, q: 0.7)]
        var energy4 = [[Double]](repeating: [Double](repeating: 0, count: frames), count: 4)
        for f in 0..<frames {
            for k in 0..<4 {
                var e = 0.0
                for i in (f * hop)..<min(samples.count, f * hop + hop) { let y = bands[k].process(Double(samples[i])); e += y * y }
                energy4[k][f] = log1p(1000 * e)
            }
        }
        var env = [Float](repeating: 0, count: frames)
        for f in 1..<frames {
            var flux = 0.0
            for k in 0..<4 { flux += max(0, energy4[k][f] - energy4[k][f - 1]) * (k == 0 ? 1.5 : 1) }
            env[f] = Float(flux)
        }
        // Remove the slow trend so only onsets remain.
        let fps = sr / Double(hop)
        let w = Int(fps * 0.4)
        var smooth = env
        var acc: Float = 0
        for i in 0..<frames {
            acc += env[i]
            if i >= w { acc -= env[i - w] }
            smooth[i] = max(0, env[i] - acc / Float(min(i + 1, w)))
        }
        // Tempo by autocorrelation with a log-normal prior centered on 115 BPM.
        let minLag = Int(fps * 60 / 200), maxLag = Int(fps * 60 / 60)
        var best = (lag: minLag, score: -Double.infinity)
        var energy: Double = 0
        for v in smooth { energy += Double(v * v) }
        var scores: [Double] = []
        for lag in minLag...maxLag {
            var s: Double = 0
            for i in 0..<(frames - lag) { s += Double(smooth[i] * smooth[i + lag]) }
            let bpm = 60 * fps / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 115) / 0.9, 2))
            let score = s * prior
            scores.append(s)
            if score > best.score { best = (lag, score) }
        }
        // Parabolic refinement of the lag.
        var lag = Double(best.lag)
        let li = best.lag - minLag
        if li > 0 && li < scores.count - 1 {
            let a = scores[li - 1], b = scores[li], c = scores[li + 1]
            let d = a - 2 * b + c
            if d != 0 { lag += 0.5 * (a - c) / d }
        }
        var bpm = 60 * fps / lag
        // Prefer the 80-160 octave.
        while bpm < 80 { bpm *= 2 }
        while bpm > 165 { bpm /= 2 }
        let period = 60 / bpm * fps
        // Beat phase: offset maximizing onset energy on the grid.
        func gridScore(_ phase: Double, step: Double) -> Double {
            var s: Double = 0, k = phase
            while k < Double(frames - 1) { let i = Int(k); s += Double(smooth[i]) + Double(smooth[min(i + 1, frames - 1)]) * (k - Double(i)); k += step }
            return s
        }
        var bestPhase = 0.0, bestScore = -1.0
        var p = 0.0
        while p < period { let s = gridScore(p, step: period); if s > bestScore { bestScore = s; bestPhase = p }; p += 0.5 }
        // Downbeat: which of the 4 beats in a bar carries the strongest accents.
        var bestBar = 0, bestBarScore = -1.0
        for k in 0..<4 {
            let s = gridScore(bestPhase + Double(k) * period, step: period * 4)
            if s > bestBarScore { bestBarScore = s; bestBar = k }
        }
        let first = (bestPhase + Double(bestBar) * period) / fps
        let peak = scores.max() ?? 1
        let confidence = energy > 0 ? clamp(peak / energy, 0, 1) : 0
        return Result(bpm: (bpm * 100).rounded() / 100, firstBeat: round3(first), confidence: round3(confidence))
    }
}
