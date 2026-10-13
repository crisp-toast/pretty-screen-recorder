import Foundation

/// Builds the final soundtrack with ffmpeg: recorded audio re-timed through the edit
/// (cuts + speed), microphone, music bed with fades and ducking, voiceover clips,
/// optional click sounds, loudness normalization.
public enum AudioMix {
    /// Returns false when there was nothing to mix (and silentIfEmpty is false).
    public static func render(studio: Studio, to out: URL, duration: Double, silentIfEmpty: Bool, includeContent: Bool) throws -> Bool {
        let a = studio.project.audio
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
                var chain = "[\(input):\(stream)]atrim=start=\(s.srcStart):end=\(s.srcEnd),asetpts=PTS-STARTPTS"
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
            for (k, v) in a.voiceover.enumerated() {
                let u = studio.resolve(v.path)
                guard FileManager.default.fileExists(atPath: u.path) else { Log.warn("voiceover missing: \(u.path)"); continue }
                inputs += ["-i", u.path]
                let ms = Int(max(0, v.at) * 1000)
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
            if let mpath = a.music.path {
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
                        filters.append("\(vlabel)asplit=2[vkey][vout]")
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
        try Media.ffmpegRun(inputs + ["-filter_complex", graph, "-map", "[out]", "-t", String(format: "%.3f", duration),
                                      "-c:a", "aac", "-b:a", "192k", "-ar", "48000", out.path])
        return true
    }
}
