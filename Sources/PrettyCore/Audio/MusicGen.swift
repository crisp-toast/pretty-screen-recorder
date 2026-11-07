import Foundation

/// Procedural, royalty-free background music with an exact beat grid (first downbeat at 0s).
/// A small offline synth: supersaw pads, sub bass, plucked arpeggios with ping-pong delay, a
/// drum kit, Freeverb-style reverb and kick sidechain. Deterministic for a given spec.
public enum MusicGen {
    public struct Result: Codable {
        public var bpm: Double
        public var beatOffset: Double
        public var duration: Double
        public var bars: Int
        public var mood: String
        public var key: String
    }

    public static let moods = ["upbeat", "corporate", "chill", "cinematic", "minimal"]

    public struct Style {
        public var bpm: Double
        public var minor: Bool
        var progression: [[Int]]      // chord tones as semitones above the key root
        public var drums: String      // four | pop | lofi | cinematic | none
        var arp: Int                  // notes per beat (0 = none)
        var padCutoff: Double
        var padLevel: Double
        var bassPattern: String       // pulse | roots | long
        var swing: Double             // 0.5 = straight
        var reverb: Double
        var sidechain: Double
    }

    public static func style(_ mood: String) -> Style {
        switch mood {
        case "corporate":
            return Style(bpm: 118, minor: false, progression: [[0, 4, 7, 14], [5, 9, 12, 16], [9, 12, 16, 19], [7, 11, 14, 17]],
                         drums: "pop", arp: 2, padCutoff: 2400, padLevel: 0.16, bassPattern: "roots", swing: 0.5, reverb: 0.22, sidechain: 0.18)
        case "chill":
            return Style(bpm: 86, minor: false, progression: [[2, 5, 9, 12], [7, 11, 14, 17], [0, 4, 7, 11], [9, 12, 16, 19]],
                         drums: "lofi", arp: 0, padCutoff: 1100, padLevel: 0.2, bassPattern: "long", swing: 0.58, reverb: 0.3, sidechain: 0)
        case "cinematic":
            return Style(bpm: 96, minor: true, progression: [[9, 12, 16], [5, 9, 12], [0, 4, 7], [7, 11, 14]],
                         drums: "cinematic", arp: 4, padCutoff: 1600, padLevel: 0.22, bassPattern: "long", swing: 0.5, reverb: 0.4, sidechain: 0)
        case "minimal":
            return Style(bpm: 104, minor: false, progression: [[0, 4, 7, 11], [5, 9, 12, 16]],
                         drums: "none", arp: 2, padCutoff: 1500, padLevel: 0.17, bassPattern: "long", swing: 0.5, reverb: 0.32, sidechain: 0)
        default: // upbeat
            return Style(bpm: 116, minor: false, progression: [[0, 4, 7], [7, 11, 14], [9, 12, 16], [5, 9, 12]],
                         drums: "four", arp: 4, padCutoff: 2000, padLevel: 0.15, bassPattern: "pulse", swing: 0.5, reverb: 0.24, sidechain: 0.32)
        }
    }

    static let keyNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static func pitchClass(_ k: String) -> Int? {
        let alias = ["DB": "C#", "D#": "EB", "GB": "F#", "G#": "AB", "A#": "BB"]
        let u = k.uppercased().replacingOccurrences(of: "M", with: "")
        let name = alias[u] ?? u
        return keyNames.firstIndex { $0.uppercased() == name }
    }

    // MARK: Rendering

    public static func render(_ spec: MusicGenSpec, duration: Double, to url: URL) throws -> Result {
        let st = style(spec.mood)
        let bpm = spec.bpm ?? st.bpm
        let beat = 60 / bpm
        let barLen = beat * 4
        let bars = max(2, Int((duration / barLen).rounded(.up)) + 1)
        let total = Double(bars) * barLen + 2.5
        let sr = 48000.0
        let n = Int(total * sr)
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: spec.seed &* 2654435761 &+ 97))
        let root = spec.key.flatMap(pitchClass) ?? (st.minor ? 9 : 0) // A minor / C major by default
        let keyRoot = 48 + (root % 12) - (st.minor ? 9 : 0)          // chord tables are major-relative
        let energy = clamp(spec.energy, 0, 1)

        var music = Bus(n), drums = Bus(n), send = Bus(n), delaySend = Bus(n)
        var kickTimes: [Double] = []

        // Voice-led chord voicings in a mid register.
        var prevVoicing: [Int] = []
        func voicing(_ chord: [Int]) -> [Int] {
            var notes = chord.map { keyRoot + $0 + 12 }
            for i in notes.indices { while notes[i] < 55 { notes[i] += 12 }; while notes[i] > 72 { notes[i] -= 12 } }
            notes.sort()
            if !prevVoicing.isEmpty {
                // Try inversions; keep the one closest to the previous voicing.
                var best = notes, bestCost = Int.max
                for inv in 0..<notes.count {
                    var v = notes
                    for j in 0..<inv { v[j] += 12 }
                    v.sort()
                    if v.last! > 76 { v = v.map { $0 - 12 } }
                    let cost = zip(v, prevVoicing).map { abs($0 - $1) }.reduce(0, +)
                    if cost < bestCost { bestCost = cost; best = v }
                }
                notes = best
            }
            prevVoicing = notes
            return notes
        }

        let lastBar = bars - 1
        for b in 0..<bars {
            let t0 = Double(b) * barLen
            let chord = st.progression[b % st.progression.count]
            let notes = voicing(chord)
            let outro = b == lastBar
            let intro = b == 0
            // Pads (whole bar; the final chord rings out)
            let padDur = outro ? barLen + 2 : barLen
            for (i, m) in notes.enumerated() {
                let pan = (Double(i) / Double(max(1, notes.count - 1)) - 0.5) * 0.6
                pad(&music, &send, sr: sr, start: t0, dur: padDur, freq: mtof(m), level: st.padLevel * (intro ? 0.85 : 1),
                    cutoff: st.padCutoff * (intro ? 0.7 : 1), pan: pan, reverb: st.reverb, rng: &rng)
            }
            // Bass
            let bassNote = keyRoot - 12 + (chord[0] % 12)
            if !intro || st.bassPattern == "long" {
                switch st.bassPattern {
                case "pulse":
                    for e in 0..<8 where !outro || e == 0 {
                        let t = t0 + Double(e) * beat / 2
                        bass(&music, sr: sr, start: t, dur: beat / 2 * 0.8, freq: mtof(bassNote), level: e % 2 == 0 ? 0.24 : 0.2)
                    }
                case "roots":
                    for e in [0, 2] where !outro || e == 0 {
                        bass(&music, sr: sr, start: t0 + Double(e) * beat, dur: beat * 1.8, freq: mtof(bassNote), level: 0.24)
                    }
                default:
                    bass(&music, sr: sr, start: t0, dur: outro ? barLen + 1.5 : barLen * 0.98, freq: mtof(bassNote), level: 0.22)
                }
            }
            // Arpeggio
            if st.arp > 0 && !outro && (energy > 0.35 || b % 2 == 1) {
                let tones = notes + notes.map { $0 + 12 }
                let steps = st.arp * 4
                for s in 0..<steps {
                    if energy < 0.6 && s % 2 == 1 { continue }
                    let idx = (s % (tones.count * 2 - 2))
                    let ti = idx < tones.count ? idx : tones.count * 2 - 2 - idx
                    var t = t0 + Double(s) * beat / Double(st.arp)
                    if st.swing > 0.5 && s % 2 == 1 { t += (st.swing - 0.5) * beat }
                    let vel = 0.09 * (s % st.arp == 0 ? 1 : 0.75) * (0.92 + rng.next() * 0.16) * (intro ? 0.7 : 1)
                    pluck(&music, &send, &delaySend, sr: sr, start: t, freq: mtof(tones[ti] + 12), level: vel, reverb: st.reverb)
                }
            }
            // Drums (intro bar and outro bar stay out, except cinematic hits)
            if intro || outro {
                if st.drums == "cinematic" && intro { boom(&drums, &send, sr: sr, start: t0, level: 0.5) }
                continue
            }
            switch st.drums {
            case "four", "pop":
                for k in 0..<4 {
                    let t = t0 + Double(k) * beat
                    if st.drums == "four" || k % 2 == 0 { kick(&drums, sr: sr, start: t, level: 0.62); kickTimes.append(t) }
                    if k % 2 == 1 { clap(&drums, &send, sr: sr, start: t, level: 0.3, rng: &rng) }
                    hat(&drums, sr: sr, start: t + beat / 2, level: 0.1 * (0.85 + rng.next() * 0.3), open: k == 3 && st.drums == "four", rng: &rng)
                    if energy > 0.55 { hat(&drums, sr: sr, start: t + beat * 0.75, level: 0.045, open: false, rng: &rng) }
                }
                if (b + 1) % 8 == 0 && energy > 0.4 {
                    for r in 0..<4 { clap(&drums, &send, sr: sr, start: t0 + 3 * beat + Double(r) * beat / 4, level: 0.12 + 0.04 * Double(r), rng: &rng) }
                }
            case "lofi":
                kick(&drums, sr: sr, start: t0, level: 0.5); kickTimes.append(t0)
                kick(&drums, sr: sr, start: t0 + beat * 2.5, level: 0.4); kickTimes.append(t0 + beat * 2.5)
                for k in [1, 3] { snare(&drums, &send, sr: sr, start: t0 + Double(k) * beat, level: 0.2, rng: &rng) }
                for e in 0..<8 {
                    var t = t0 + Double(e) * beat / 2
                    if e % 2 == 1 { t += (st.swing - 0.5) * beat }
                    hat(&drums, sr: sr, start: t, level: 0.06 * (e % 2 == 0 ? 1 : 0.7) * (0.8 + rng.next() * 0.4), open: false, rng: &rng)
                }
            case "cinematic":
                if b % 2 == 0 { boom(&drums, &send, sr: sr, start: t0, level: 0.45) }
                for e in 0..<8 { tick(&drums, sr: sr, start: t0 + Double(e) * beat / 2, level: 0.035) }
                if (b + 2) % 4 == 0 { riser(&drums, &send, sr: sr, start: t0 + barLen * 0.25, dur: barLen * 0.75, level: 0.07, rng: &rng) }
            default:
                for k in 0..<4 { tick(&drums, sr: sr, start: t0 + Double(k) * beat, level: 0.03) }
            }
        }

        // Effects
        let dl = pingPong(delaySend, sr: sr, delay: beat * 0.75, feedback: 0.34)
        send.add(dl, gain: 0.35)
        let verb = freeverb(send, sr: sr, room: 0.86, damp: 0.25)
        // Sidechain pump on the music bus.
        if st.sidechain > 0 {
            var g = [Float](repeating: 1, count: n)
            for t in kickTimes {
                let i0 = Int(t * sr), len = Int(beat * sr)
                for i in 0..<len where i0 + i < n {
                    let x = Double(i) / sr
                    g[i0 + i] = min(g[i0 + i], Float(1 - st.sidechain * exp(-x / (beat * 0.22))))
                }
            }
            for i in 0..<n { music.l[i] *= g[i]; music.r[i] *= g[i] }
        }
        var out = Bus(n)
        out.add(music, gain: 1); out.add(dl, gain: 0.22); out.add(drums, gain: 1); out.add(verb, gain: 0.9)
        // Master: DC/rumble high-pass, gentle saturation, fade, normalize to -1 dBFS.
        out.highpass(sr: sr, hz: 28)
        let fadeStart = Int((total - 2.2) * sr)
        for i in 0..<n {
            var gl = Double(out.l[i]), gr = Double(out.r[i])
            gl = tanh(gl * 1.15) / 1.15; gr = tanh(gr * 1.15) / 1.15
            if i > fadeStart { let f = 1 - Double(i - fadeStart) / Double(n - fadeStart); gl *= f; gr *= f }
            out.l[i] = Float(gl); out.r[i] = Float(gr)
        }
        let peak = max(out.l.map(abs).max() ?? 1, out.r.map(abs).max() ?? 1)
        let norm = peak > 0 ? Float(0.89 / Double(peak)) : 1
        try writeWAV(url, l: out.l.map { $0 * norm }, r: out.r.map { $0 * norm }, sr: Int(sr))
        return Result(bpm: bpm, beatOffset: 0, duration: round3(total), bars: bars, mood: spec.mood,
                      key: keyNames[(root % 12 + 12) % 12] + (st.minor ? "m" : ""))
    }

    // MARK: Instruments

    static func mtof(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12) }

    static func pad(_ bus: inout Bus, _ send: inout Bus, sr: Double, start: Double, dur: Double, freq: Double, level: Double,
                    cutoff: Double, pan: Double, reverb: Double, rng: inout SplitMix) {
        let atk = 0.35, rel = 0.7
        let len = Int((dur + rel) * sr), i0 = Int(start * sr)
        var phases = (0..<3).map { _ in rng.next() }
        let detune = [1.0, pow(2, 7 / 1200.0), pow(2, -6 / 1200.0)]
        var lp1 = 0.0, lp2 = 0.0
        let gl = sqrt(0.5 - pan * 0.5), gr = sqrt(0.5 + pan * 0.5)
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            var s = 0.0
            for v in 0..<3 {
                phases[v] += freq * detune[v] / sr
                if phases[v] >= 1 { phases[v] -= 1 }
                s += 2 * phases[v] - 1 // saw
            }
            s /= 3
            s += 0.35 * sin(2 * .pi * freq * 0.5 * t) // sub
            let lfo = 1 + 0.12 * sin(2 * .pi * 0.23 * t)
            let a = 1 - exp(-2 * .pi * cutoff * lfo / sr)
            lp1 += a * (s - lp1); lp2 += a * (lp1 - lp2)
            var env = min(1, t / atk)
            if t > dur { env *= max(0, 1 - (t - dur) / rel) }
            let y = lp2 * env * level
            bus.l[idx] += Float(y * gl); bus.r[idx] += Float(y * gr)
            send.l[idx] += Float(y * gl * reverb); send.r[idx] += Float(y * gr * reverb)
        }
    }

    static func bass(_ bus: inout Bus, sr: Double, start: Double, dur: Double, freq: Double, level: Double) {
        let rel = 0.06, len = Int((dur + rel) * sr), i0 = Int(start * sr)
        var ph = 0.0
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            ph += freq / sr
            let s = sin(2 * .pi * ph) + 0.28 * sin(4 * .pi * ph) + 0.08 * sin(6 * .pi * ph)
            var env = min(1, t / 0.006) * (0.75 + 0.25 * exp(-t / 0.12))
            if t > dur { env *= max(0, 1 - (t - dur) / rel) }
            let y = tanh(1.4 * s) * env * level
            bus.l[idx] += Float(y); bus.r[idx] += Float(y)
        }
    }

    static func pluck(_ bus: inout Bus, _ send: inout Bus, _ delay: inout Bus, sr: Double, start: Double, freq: Double, level: Double, reverb: Double) {
        let len = Int(0.6 * sr), i0 = Int(start * sr)
        var ph = 0.0, lp = 0.0
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            ph += freq / sr; if ph >= 1 { ph -= 1 }
            let saw = 2 * ph - 1, sq = ph < 0.5 ? 1.0 : -1.0
            let s = 0.6 * saw + 0.4 * sq
            let cutoff = 900 + 3400 * exp(-t / 0.07)
            lp += (1 - exp(-2 * .pi * cutoff / sr)) * (s - lp)
            let env = min(1, t / 0.002) * exp(-t / 0.16)
            let y = lp * env * level
            bus.l[idx] += Float(y); bus.r[idx] += Float(y)
            send.l[idx] += Float(y * reverb); send.r[idx] += Float(y * reverb)
            delay.l[idx] += Float(y); delay.r[idx] += Float(y)
        }
    }

    static func kick(_ bus: inout Bus, sr: Double, start: Double, level: Double) {
        let len = Int(0.5 * sr), i0 = Int(start * sr)
        var ph = 0.0
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            let f = 46 + 115 * exp(-t / 0.032)
            ph += f / sr
            let body = sin(2 * .pi * ph) * exp(-t / 0.3)
            let click = (t < 0.004 ? (1 - t / 0.004) : 0) * 0.35
            let y = tanh(1.6 * (body + click)) * level
            bus.l[idx] += Float(y); bus.r[idx] += Float(y)
        }
    }

    static func clap(_ bus: inout Bus, _ send: inout Bus, sr: Double, start: Double, level: Double, rng: inout SplitMix) {
        let len = Int(0.35 * sr), i0 = Int(start * sr)
        var bp = Biquad.bandpass(sr: sr, hz: 1400, q: 1.1)
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            var env = 0.0
            for b in [0.0, 0.011, 0.022] where t >= b { env = max(env, exp(-(t - b) / 0.006)) }
            if t > 0.03 { env = max(env, 0.55 * exp(-(t - 0.03) / 0.14)) }
            let y = bp.process(rng.next() * 2 - 1) * env * level * 2.2
            bus.l[idx] += Float(y * 0.95); bus.r[idx] += Float(y * 1.05)
            send.l[idx] += Float(y * 0.3); send.r[idx] += Float(y * 0.3)
        }
    }

    static func snare(_ bus: inout Bus, _ send: inout Bus, sr: Double, start: Double, level: Double, rng: inout SplitMix) {
        let len = Int(0.3 * sr), i0 = Int(start * sr)
        var bp = Biquad.bandpass(sr: sr, hz: 2200, q: 0.8)
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            let noise = bp.process(rng.next() * 2 - 1) * exp(-t / 0.11)
            let tone = sin(2 * .pi * 185 * t) * exp(-t / 0.06)
            let y = (noise * 1.6 + tone * 0.5) * level
            bus.l[idx] += Float(y); bus.r[idx] += Float(y)
            send.l[idx] += Float(y * 0.35); send.r[idx] += Float(y * 0.35)
        }
    }

    static func hat(_ bus: inout Bus, sr: Double, start: Double, level: Double, open: Bool, rng: inout SplitMix) {
        let decay = open ? 0.2 : 0.032
        let len = Int((decay * 6) * sr), i0 = Int(start * sr)
        var hp = Biquad.highpass(sr: sr, hz: 7800, q: 0.7)
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            let y = hp.process(rng.next() * 2 - 1) * exp(-t / decay) * level
            bus.l[idx] += Float(y * 0.85); bus.r[idx] += Float(y * 1.15)
        }
    }

    static func tick(_ bus: inout Bus, sr: Double, start: Double, level: Double) {
        let len = Int(0.05 * sr), i0 = Int(start * sr)
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            let y = sin(2 * .pi * 1700 * t) * exp(-t / 0.008) * level
            bus.l[idx] += Float(y); bus.r[idx] += Float(y)
        }
    }

    static func boom(_ bus: inout Bus, _ send: inout Bus, sr: Double, start: Double, level: Double) {
        let len = Int(2.2 * sr), i0 = Int(start * sr)
        var ph = 0.0
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let t = Double(i) / sr
            ph += (40 + 35 * exp(-t / 0.08)) / sr
            let y = tanh(1.3 * sin(2 * .pi * ph)) * exp(-t / 0.9) * level
            bus.l[idx] += Float(y); bus.r[idx] += Float(y)
            send.l[idx] += Float(y * 0.4); send.r[idx] += Float(y * 0.4)
        }
    }

    static func riser(_ bus: inout Bus, _ send: inout Bus, sr: Double, start: Double, dur: Double, level: Double, rng: inout SplitMix) {
        let len = Int(dur * sr), i0 = Int(start * sr)
        var bp = Biquad.bandpass(sr: sr, hz: 400, q: 2)
        for i in 0..<len {
            let idx = i0 + i
            if idx >= bus.n { break }
            let p = Double(i) / Double(len)
            if i % 64 == 0 { bp.retune(Biquad.bandpass(sr: sr, hz: 400 + 5600 * p * p, q: 2)) }
            let y = bp.process(rng.next() * 2 - 1) * p * p * level
            bus.l[idx] += Float(y); bus.r[idx] += Float(y)
            send.l[idx] += Float(y); send.r[idx] += Float(y)
        }
    }

    // MARK: Effects

    static func pingPong(_ input: Bus, sr: Double, delay: Double, feedback: Double) -> Bus {
        var out = Bus(input.n)
        let d = Int(delay * sr)
        guard d > 0 else { return out }
        var bl = [Float](repeating: 0, count: d), br = [Float](repeating: 0, count: d)
        var p = 0
        var lpL: Float = 0, lpR: Float = 0
        for i in 0..<input.n {
            let yl = bl[p], yr = br[p]
            lpL += 0.4 * (yl - lpL); lpR += 0.4 * (yr - lpR)
            out.l[i] = yl; out.r[i] = yr
            let mono = (input.l[i] + input.r[i]) * 0.5
            bl[p] = mono + lpR * Float(feedback)
            br[p] = lpL * Float(feedback)
            p = (p + 1) % d
        }
        return out
    }

    /// Freeverb (Jezar) — 8 lowpass-feedback combs + 4 allpasses per channel.
    static func freeverb(_ input: Bus, sr: Double, room: Double, damp: Double) -> Bus {
        let scale = sr / 44100
        let combT = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], apT = [556, 441, 341, 225]
        var out = Bus(input.n)
        for ch in 0..<2 {
            let spread = ch == 0 ? 0 : 23
            var combs = combT.map { [Float](repeating: 0, count: Int(Double($0 + spread) * scale)) }
            var cIdx = [Int](repeating: 0, count: 8), cStore = [Float](repeating: 0, count: 8)
            var aps = apT.map { [Float](repeating: 0, count: Int(Double($0 + spread) * scale)) }
            var aIdx = [Int](repeating: 0, count: 4)
            let fb = Float(room), d1 = Float(damp), d2 = 1 - Float(damp)
            let src = ch == 0 ? input.l : input.r
            var dst = [Float](repeating: 0, count: input.n)
            for i in 0..<input.n {
                let x = src[i] * 0.015
                var acc: Float = 0
                for c in 0..<8 {
                    let y = combs[c][cIdx[c]]
                    cStore[c] = y * d2 + cStore[c] * d1
                    combs[c][cIdx[c]] = x + cStore[c] * fb
                    cIdx[c] = (cIdx[c] + 1) % combs[c].count
                    acc += y
                }
                for a in 0..<4 {
                    let b = aps[a][aIdx[a]]
                    aps[a][aIdx[a]] = acc + b * 0.5
                    acc = b - acc
                    aIdx[a] = (aIdx[a] + 1) % aps[a].count
                }
                dst[i] = acc
            }
            if ch == 0 { out.l = dst } else { out.r = dst }
        }
        return out
    }
}

// MARK: - DSP plumbing

struct Bus {
    var l: [Float], r: [Float]
    let n: Int
    init(_ n: Int) { self.n = n; l = [Float](repeating: 0, count: n); r = [Float](repeating: 0, count: n) }
    mutating func add(_ o: Bus, gain: Float) {
        for i in 0..<min(n, o.n) { l[i] += o.l[i] * gain; r[i] += o.r[i] * gain }
    }
    mutating func highpass(sr: Double, hz: Double) {
        let a = Float(exp(-2 * .pi * hz / sr))
        var pl: Float = 0, pr: Float = 0, yl: Float = 0, yr: Float = 0
        for i in 0..<n {
            yl = a * (yl + l[i] - pl); pl = l[i]; l[i] = yl
            yr = a * (yr + r[i] - pr); pr = r[i]; r[i] = yr
        }
    }
}

struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    static func bandpass(sr: Double, hz: Double, q: Double) -> Biquad {
        let w = 2 * .pi * hz / sr, alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }
    static func lowpass(sr: Double, hz: Double, q: Double) -> Biquad {
        let w = 2 * .pi * hz / sr, alpha = sin(w) / (2 * q), a0 = 1 + alpha, c = cos(w)
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
    static func highpass(sr: Double, hz: Double, q: Double) -> Biquad {
        let w = 2 * .pi * hz / sr, alpha = sin(w) / (2 * q), a0 = 1 + alpha, c = cos(w)
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
    /// Take new coefficients, keep the filter state (for sweeps).
    mutating func retune(_ o: Biquad) { b0 = o.b0; b1 = o.b1; b2 = o.b2; a1 = o.a1; a2 = o.a2 }
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Deterministic PRNG (so a given spec always renders the same track).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// 16-bit stereo PCM WAV.
func writeWAV(_ url: URL, l: [Float], r: [Float], sr: Int) throws {
    let n = min(l.count, r.count)
    var pcm = [Int16](repeating: 0, count: n * 2)
    for i in 0..<n {
        pcm[i * 2] = Int16(clamp(l[i], -1, 1) * 32000)
        pcm[i * 2 + 1] = Int16(clamp(r[i], -1, 1) * 32000)
    }
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4)); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr * 4)); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4))
    pcm.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    try data.write(to: url)
}
