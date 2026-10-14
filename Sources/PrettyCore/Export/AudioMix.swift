import Foundation

/// Builds the final soundtrack with ffmpeg: recorded audio re-timed through the edit
/// (cuts + speed), microphone, music bed with fades and ducking, voiceover clips,
/// optional click sounds, loudness normalization.
public enum AudioMix {
    /// Returns false when there was nothing to mix (and silentIfEmpty is false).
    public static func render(studio: Studio, to out: URL, duration: Double, silentIfEmpty: Bool, includeContent: Bool,
                              preset: String? = nil) throws -> Bool {
        let a = studio.project.audio
        let plan = studio.audioPlan(preset: preset ?? studio.project.export.preset)
        var inputs: [String] = []
        var filters: [String] = []
        var mixLabels: [String] = []
        var voiceLabels: [String] = []
        var idx = 0
        let segs = studio.map.segments

        func retimed(_ input: Int, stream: String, volume: Double, label: String) {
            // Cut + speed the stream exactly like the video.
            var parts: [String] = []
            for (k, s) in segs.enumerated() {
                var chain: String
                if s.isHold {
                    // Freeze-frame: silence for the hold's duration.
                    chain = "[\(input):\(stream)]atrim=start=\(s.srcStart):end=\(s.srcStart + 0.02),asetpts=PTS-STARTPTS,volume=0"
                    chain += ",aresample=48000,aformat=channel_layouts=stereo,apad=whole_dur=\(s.holdDuration),atrim=0:\(s.holdDuration)[\(label)s\(k)]"
                    filters.append(chain); parts.append("[\(label)s\(k)]"); continue
                }
                chain = "[\(input):\(stream)]atrim=start=\(s.srcStart):end=\(s.srcEnd),asetpts=PTS-STARTPTS"
                if abs(s.rate - 1) > 0.001 { chain += ",atempo=\(clamp(s.rate, 0.5, 100))" }
                chain += ",aresample=48000,aformat=channel_layouts=stereo[\(label)s\(k)]"
                filters.append(chain)
                parts.append("[\(label)s\(k)]")
            }
            filters.append("\(parts.joined())concat=n=\(segs.count):v=0:a=1,volume=\(volume)[\(label)]")
        }

        if includeContent {
            if a.system, let v = studio.videoURL, let pr = try? Media.probe(v), pr.audioStreams > 0 {
                inputs += ["-i", v.path]
                retimed(idx, stream: "a:0", volume: a.systemVolume, label: "sys")
                mixLabels.append("[sys]")
                if pr.audioStreams > 1 && a.mic && studio.project.source.mic == nil {
                    retimed(idx, stream: "a:1", volume: a.micVolume, label: "mic")
                    voiceLabels.append("[mic]")
                }
                idx += 1
            }
            if a.mic, let m = studio.project.source.mic {
                let u = studio.resolve(m)
                if FileManager.default.fileExists(atPath: u.path) {
                    inputs += ["-i", u.path]
                    retimed(idx, stream: "a:0", volume: a.micVolume, label: "mic")
                    voiceLabels.append("[mic]"); idx += 1
                }
            }
            for (k, item) in (plan.voice ? studio.voiceClips() : []).enumerated() {
                let v = item.clip
                let u = studio.resolve(v.path)
                guard FileManager.default.fileExists(atPath: u.path) else { Log.warn("voiceover missing: \(u.path)"); continue }
                inputs += ["-i", u.path]
                let ms = Int(max(0, item.at) * 1000)
                filters.append("[\(idx):a:0]aresample=48000,aformat=channel_layouts=stereo,volume=\(v.volume),adelay=\(ms)|\(ms)[vo\(k)]")
                voiceLabels.append("[vo\(k)]"); idx += 1
            }
            if a.clickSounds, !studio.cursor.clicks.isEmpty {
                let times = studio.cursor.clicks.compactMap { c -> Double? in
                    studio.map.isKept(source: c.t) ? studio.map.output(atSource: c.t) : nil
                }
                if !times.isEmpty {
                    let track = out.deletingLastPathComponent().appendingPathComponent("clicks.wav")
                    try Media.clickTrack(times: times, duration: duration, volume: a.clickVolume, to: track)
                    inputs += ["-i", track.path]
                    filters.append("[\(idx):a:0]aresample=48000,aformat=channel_layouts=stereo[clicks]")
                    mixLabels.append("[clicks]"); idx += 1
                }
            }
            if (plan.music || plan.voice) && !a.sfx.isEmpty {
                let clips = a.sfx.compactMap { c -> (url: URL, at: Double, volume: Double)? in
                    let u = studio.resolve(c.path)
                    return FileManager.default.fileExists(atPath: u.path) ? (u, c.at, c.volume * a.sfxVolume) : nil
                }
                if !clips.isEmpty {
                    let track = out.deletingLastPathComponent().appendingPathComponent("sfx.wav")
                    try Media.sfxTrack(clips: clips, duration: duration, to: track)
                    inputs += ["-i", track.path]
                    filters.append("[\(idx):a:0]aresample=48000,aformat=channel_layouts=stereo[sfx]")
                    mixLabels.append("[sfx]"); idx += 1
                }
            }
            if plan.music, let mpath = a.music.path {
                let u = studio.resolve(mpath)
                if FileManager.default.fileExists(atPath: u.path) {
                    inputs += ["-stream_loop", "-1", "-ss", "\(a.music.offset)", "-i", u.path]
                    let fo = max(0, duration - a.music.fadeOut)
                    filters.append("[\(idx):a:0]atrim=0:\(duration),asetpts=PTS-STARTPTS,aresample=48000,aformat=channel_layouts=stereo,volume=\(a.music.volume),afade=t=in:st=0:d=\(a.music.fadeIn),afade=t=out:st=\(fo):d=\(a.music.fadeOut)[music]")
                    idx += 1
                    if a.music.duck && !voiceLabels.isEmpty {
                        // Sidechain: voices push the music down.
                        let vmix = voiceLabels.count > 1 ? "\(voiceLabels.joined())amix=inputs=\(voiceLabels.count):normalize=0[voices]" : nil
                        if let vmix { filters.append(vmix) }
                        let vlabel = vmix != nil ? "[voices]" : voiceLabels[0]
                        // Pad the voice bus to the full length: sidechaincompress stops when its key ends,
                        // which would silence the music after the last line.
                        filters.append("\(vlabel)apad=whole_dur=\(duration),atrim=0:\(duration),asplit=2[vkey][vout]")
                        filters.append("[music][vkey]sidechaincompress=threshold=0.03:ratio=8:attack=20:release=400[mducked]")
                        mixLabels.append("[mducked]"); mixLabels.append("[vout]")
                        voiceLabels = []
                    } else {
                        mixLabels.append("[music]")
                    }
                } else { Log.warn("music missing: \(u.path)") }
            }
            mixLabels += voiceLabels
        }

        if mixLabels.isEmpty {
            guard silentIfEmpty else { return false }
            try Media.ffmpegRun(["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000", "-t", "\(duration)",
                                 "-c:a", "aac", "-b:a", "128k", out.path])
            return true
        }
        var final = mixLabels.count > 1 ? "\(mixLabels.joined())amix=inputs=\(mixLabels.count):normalize=0:dropout_transition=0" : "\(mixLabels[0])anull"
        // Pad/trim to the video duration, then normalize.
        final += ",apad,atrim=0:\(duration)"
        if a.normalize { final += ",loudnorm=I=-14:TP=-1:LRA=11" }
        final += ",aresample=48000[out]"
        filters.append(final)
        let graph = filters.joined(separator: ";")
        // -t guarantees termination: the looped music input never ends on its own.
        guard a.normalize else {
            try Media.ffmpegRun(inputs + ["-filter_complex", graph, "-map", "[out]", "-t", String(format: "%.3f", duration),
                                          "-c:a", "aac", "-b:a", "192k", "-ar", "48000", out.path])
            return true
        }
        // Loudness, exactly: single-pass loudnorm lands a few LU off on short edits, so measure the
        // premaster and trim it to -14 LUFS with a true-peak limiter.
        let pre = out.deletingLastPathComponent().appendingPathComponent("premaster.wav")
        try Media.ffmpegRun(inputs + ["-filter_complex", graph, "-map", "[out]", "-t", String(format: "%.3f", duration), "-c:a", "pcm_s24le", pre.path])
        var gain = Media.integratedLoudness(pre).map { clamp(-14 - $0, -12, 12) } ?? 0
        let limited = out.deletingLastPathComponent().appendingPathComponent("limited.wav")
        // Converge on the ENCODED result: the limiter shaves transients after the gain, and AAC's
        // low-pass removes ultrasonic energy some tracks carry — both lower the measured loudness.
        for _ in 0..<4 {
            try Media.ffmpegRun(["-i", pre.path, "-af", String(format: "volume=%.2fdB,alimiter=limit=0.891:attack=4:release=80:level=disabled", gain),
                                 "-c:a", "pcm_s24le", limited.path])
            try Media.ffmpegRun(["-i", limited.path, "-c:a", "aac", "-b:a", "192k", "-ar", "48000", out.path])
            let now = Media.integratedLoudness(out)
            if ProcessInfo.processInfo.environment["PRETTY_DEBUG"] != nil { Log.warn("loudness pass: gain \(gain) → \(now.map { String($0) } ?? "?") LUFS") }
            guard let now, abs(-14 - now) > 0.3 else { break }
            gain = clamp(gain + (-14 - now), -12, 18)
        }
        try? FileManager.default.removeItem(at: pre)
        try? FileManager.default.removeItem(at: limited)
        return true
    }
}
