import Foundation

/// What the soundtrack carries for a given export, and why.
public struct AudioPlan: Codable {
    public var music: Bool
    public var voice: Bool
    public var mode: String
    public var reason: String

    /// Resolve `audio.mode`. "auto" follows platform conventions:
    /// - web-hero / gif: silent (autoplays muted, loops)
    /// - App Store previews: music bed (autoplay is muted; narration is optional)
    /// - TikTok / Reels / Shorts / Instagram / X / square: narration + ducked music, captions burned in
    /// - YouTube / LinkedIn / walkthroughs: narration first; a quiet music bed if one is provided
    public static func resolve(_ audio: AudioSpec, preset: String?, hasVoice: Bool, hasMusic: Bool) -> AudioPlan {
        switch audio.mode {
        case "none": return AudioPlan(music: false, voice: false, mode: "none", reason: "set to none")
        case "music": return AudioPlan(music: hasMusic, voice: false, mode: "music", reason: hasMusic ? "set to music" : "set to music, but no music track")
        case "voiceover": return AudioPlan(music: false, voice: hasVoice, mode: "voiceover", reason: hasVoice ? "set to voiceover" : "set to voiceover, but no narration")
        case "both": return AudioPlan(music: hasMusic, voice: hasVoice, mode: "both", reason: "set to both")
        default: break
        }
        let p = (preset ?? "").lowercased()
        func pick(_ m: Bool, _ v: Bool, _ why: String) -> AudioPlan {
            let mm = m && hasMusic, vv = v && hasVoice
            let mode = mm && vv ? "both" : mm ? "music" : vv ? "voiceover" : "none"
            var reason = why
            if v && !hasVoice && mm { reason += " — music, with the words on screen (no narrator set up)" }
            else if m && !hasMusic && vv { reason += " (no music track)" }
            return AudioPlan(music: mm, voice: vv, mode: mode, reason: "auto: " + reason)
        }
        if ["web-hero", "gif"].contains(p) { return pick(false, false, "\(p) plays muted on loop — silent") }
        if p.hasPrefix("app-store") {
            return hasMusic ? pick(true, false, "App Store previews autoplay muted — music bed, no narration")
                            : pick(false, true, "App Store preview with narration only")
        }
        if ["tiktok", "reels", "shorts", "instagram", "square", "x"].contains(p) {
            return pick(true, true, hasVoice ? "short-form social — narration + ducked music, captions burned in" : "short-form social")
        }
        return pick(true, true, hasVoice ? "walkthrough — narration leads, music sits underneath if provided" : "walkthrough")
    }

    /// Caption chunks from word-timed voiceover clips (output time).
    public static func captions(from clips: [(at: Double, clip: VoiceClip)], maxWords: Int) -> [CaptionItem] {
        var out: [CaptionItem] = []
        for (at, clip) in clips {
            let firstIndex = out.count
            guard let text = clip.text, !text.isEmpty else { continue }
            let words = clip.words ?? Voice.estimateWords(text, duration: clip.duration ?? Double(text.count) / 14)
            let end = at + (clip.duration ?? ((words.last?.t ?? 0) + 0.6))
            var chunk: [WordTime] = []
            func flush(_ nextStart: Double?) {
                guard let first = chunk.first else { return }
                let s = at + first.t
                let e = min(nextStart.map { at + $0 } ?? end, end + 0.25)
                out.append(CaptionItem(start: round3(max(0, s - 0.05)), end: round3(max(s + 0.4, e)), text: chunk.map(\.w).joined(separator: " ")))
                chunk = []
            }
            for (i, w) in words.enumerated() {
                chunk.append(w)
                let punct = w.w.last.map { ",.;:!?—".contains($0) } ?? false
                if chunk.count >= maxWords || (punct && chunk.count >= 2) {
                    flush(i + 1 < words.count ? words[i + 1].t : nil)
                }
            }
            flush(nil)
            // Never strand a one- or two-word tail ("one swipe / away."): fold it into the chunk before.
            if out.count - firstIndex >= 2, let last = out.last, last.text.split(separator: " ").count <= 2 {
                let prev = out[out.count - 2]
                if prev.text.split(separator: " ").count + last.text.split(separator: " ").count <= maxWords + 2 {
                    out.removeLast(2)
                    out.append(CaptionItem(start: prev.start, end: last.end, text: prev.text + " " + last.text))
                }
            }
        }
        return out
    }
}
