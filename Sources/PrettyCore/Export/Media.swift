import Foundation

/// Thin wrappers around external tools (ffmpeg / ffprobe / node / xcrun).
public enum Media {
    public static func which(_ tool: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    public static var ffmpeg: String { which("ffmpeg") ?? "ffmpeg" }
    public static var ffprobe: String { which("ffprobe") ?? "ffprobe" }

    @discardableResult
    public static func run(_ exe: String, _ args: [String], cwd: URL? = nil, quiet: Bool = true, env: [String: String]? = nil) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe.hasPrefix("/") ? exe : (which(exe) ?? "/usr/bin/env"))
        p.arguments = exe.hasPrefix("/") || which(exe) != nil ? args : [exe] + args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; group.leave() } else { outData.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; group.leave() } else {
                errData.append(d)
                if !quiet { FileHandle.standardError.write(d) }
            }
        }
        try p.run()
        p.waitUntilExit()
        group.wait()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    public static func ffmpegRun(_ args: [String]) throws {
        let r = try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + args)
        if r.status != 0 { throw fail("ffmpeg failed: \(r.err.suffix(1200))") }
    }

    public struct Probe {
        public var duration: Double
        public var width: Int
        public var height: Int
        public var fps: Double
        public var audioStreams: Int
        public var videoCodec: String
    }

    public static func probe(_ url: URL) throws -> Probe {
        let r = try run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height,r_frame_rate:format=duration", "-of", "json", url.path])
        guard r.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else {
            throw fail("ffprobe failed on \(url.lastPathComponent): \(r.err)")
        }
        let streams = obj["streams"] as? [[String: Any]] ?? []
        let v = streams.first { ($0["codec_type"] as? String) == "video" }
        let fpsStr = v?["r_frame_rate"] as? String ?? "0/1"
        let parts = fpsStr.split(separator: "/").compactMap { Double($0) }
        let fps = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 0
        let dur = Double((obj["format"] as? [String: Any])?["duration"] as? String ?? "0") ?? 0
        return Probe(duration: dur, width: v?["width"] as? Int ?? 0, height: v?["height"] as? Int ?? 0, fps: fps,
                     audioStreams: streams.filter { ($0["codec_type"] as? String) == "audio" }.count,
                     videoCodec: v?["codec_name"] as? String ?? "")
    }

    /// Frozen (visually static) intervals via ffmpeg's freezedetect.
    public static func freezes(_ url: URL, minDuration: Double = 0.5) -> [(Double, Double)] {
        guard let r = try? run(ffmpeg, ["-hide_banner", "-nostats", "-i", url.path, "-map", "0:v:0",
                                        "-vf", "scale=480:-2,freezedetect=n=0.0025:d=\(minDuration)", "-f", "null", "-"]) else { return [] }
        var out: [(Double, Double)] = []
        var start: Double? = nil
        for line in r.err.split(separator: "\n") {
            if let rg = line.range(of: "freeze_start: ") { start = Double(line[rg.upperBound...].trimmingCharacters(in: .whitespaces)) }
            if let rg = line.range(of: "freeze_end: "), let s = start, let e = Double(line[rg.upperBound...].trimmingCharacters(in: .whitespaces)) {
                out.append((s, e)); start = nil
            }
        }
        if let s = start, let d = try? probe(url).duration { out.append((s, d)) }
        return out
    }

    /// A short, soft mouse-click sample (synthesized; no assets needed), 48 kHz mono floats.
    static func clickSamples() -> [Float] {
        let sr = 48000.0, n = Int(0.06 * sr)
        var out = [Float](repeating: 0, count: n)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        var lp = 0.0
        for i in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int64(bitPattern: seed >> 11) % 2000) / 1000.0
            let t = Double(i) / sr
            let env = exp(-t * 140) * (t < 0.0015 ? t / 0.0015 : 1)
            let tone = sin(2 * .pi * 2300 * t) * exp(-t * 220)
            lp += (noise - lp) * 0.35
            out[i] = Float((lp * 0.55 + tone * 0.45) * env)
        }
        return out
    }

    /// A full-length stereo WAV with a click at each time — one input for the mixer instead
    /// of dozens of delayed copies (which can deadlock ffmpeg's filter graph).
    public static func clickTrack(times: [Double], duration: Double, volume: Double, to url: URL) throws {
        let sr = 48000
        let n = max(1, Int(duration * Double(sr)))
        var mix = [Float](repeating: 0, count: n)
        let click = clickSamples()
        for t in times {
            let start = Int(t * Double(sr))
            for (i, v) in click.enumerated() where start + i >= 0 && start + i < n { mix[start + i] += v * Float(volume) }
        }
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 4)); data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr * 4)); u16(4); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(n * 4))
        var pcm = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n { let v = Int16(clamp(Double(mix[i]), -1, 1) * 22000); pcm[i * 2] = v; pcm[i * 2 + 1] = v }
        pcm.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url)
    }
}
