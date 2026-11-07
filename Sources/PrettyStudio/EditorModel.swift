import Foundation
import SwiftUI
import AVFoundation
import Combine
import PrettyCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case cursor, keystrokes, audio, camera, background, motion, zoom, text
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cursor: return "cursorarrow.rays"
        case .keystrokes: return "command"
        case .audio: return "speaker.wave.2.fill"
        case .camera: return "video.fill"
        case .background: return "photo.fill"
        case .motion: return "circle.dotted.and.circle"
        case .zoom: return "plus.magnifyingglass"
        case .text: return "textformat"
        }
    }
    var title: String {
        switch self {
        case .cursor: return "Cursor"
        case .keystrokes: return "Keystrokes"
        case .audio: return "Audio"
        case .camera: return "Camera"
        case .background: return "Background"
        case .motion: return "Motion"
        case .zoom: return "Zoom"
        case .text: return "Text"
        }
    }
}

/// One open project. `project` is the source of truth; edits re-derive the Studio and
/// are written back to project.json (debounced), so agents and the editor can collaborate
/// on the same file — external changes are picked up live.
@MainActor
final class EditorModel: ObservableObject {
    let bundleURL: URL
    @Published var project: Project { didSet { if project != oldValue { projectChanged() } } }
    @Published private(set) var studio: Studio
    @Published var tab: InspectorTab = .cursor
    @Published var selectedZoom: String? { didSet { if selectedZoom != nil { tab = .zoom } } }
    @Published var selectedText: Int?
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var bladeMode = false
    @Published var splits: [Double] = []           // source times (UI only until a piece is deleted)
    @Published var selectedPiece: Int?
    @Published var edited = false
    @Published var exportSettings: ExportSettings?
    @Published var thumbnails: [CGImage] = []
    @Published var renderVersion = 0
    /// Bumped only when the project changes (the preview rebuilds its Composer).
    private(set) var projectVersion = 0
    @Published var manualFocusPick = false

    let player = AVPlayer()
    private(set) var videoOutput: AVPlayerItemVideoOutput?
    private(set) var compositionAsset: AVAsset?
    private var timeObserver: Any?
    private var saveWork: DispatchWorkItem?
    private var lastWrittenData: Data?
    private var watcher: DispatchSourceFileSystemObject?
    private var lastMapSignature = ""

    init(bundleURL: URL) throws {
        self.bundleURL = bundleURL
        let studio = try Studio(url: bundleURL)
        self.studio = studio
        self.project = studio.project
        self.lastWrittenData = try? Data(contentsOf: studio.projectURL)
        rebuildPlayer()
        exportSettings = try? ExportSettings.resolve(studio)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.isPlaying { self.currentTime = t.seconds.isFinite ? t.seconds : 0 }
                if self.isPlaying && self.player.rate == 0 { self.isPlaying = false }
            }
        }
        watch()
        Task { await self.makeThumbnails() }
        if let t = ProcessInfo.processInfo.environment["PRETTY_AUTOPLAY"], let at = Double(t) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.seek(to: at); self.togglePlay() }
        }
    }

    var name: String { project.name }
    var duration: Double { studio.outputDuration }

    // MARK: Edits

    private func projectChanged() {
        edited = true
        do {
            studio = try Studio(project: project, projectURL: studio.projectURL, baseURL: studio.baseURL)
        } catch {
            NSLog("studio rebuild failed: \(error)")
        }
        exportSettings = try? ExportSettings.resolve(studio)
        let sig = "\(project.timeline)"
        if sig != lastMapSignature { rebuildPlayer() }
        projectVersion += 1
        renderVersion += 1
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func saveNow() {
        guard let data = try? prettyJSON(project) else { return }
        lastWrittenData = data
        try? data.write(to: studio.projectURL, options: .atomic)
    }

    /// Reload when another process (an agent) rewrites project.json.
    private func watch() {
        let path = studio.projectURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let data = try? Data(contentsOf: self.studio.projectURL), data != self.lastWrittenData,
                   let p = try? JSONDecoder().decode(Project.self, from: data) {
                    self.lastWrittenData = data
                    self.project = p
                }
                // Atomic writes replace the file: re-arm on the new inode.
                if src.data.contains(.rename) || src.data.contains(.delete) {
                    src.cancel(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.watch() }
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher?.cancel()
        watcher = src
    }

    // MARK: Player

    func rebuildPlayer() {
        lastMapSignature = "\(project.timeline)"
        guard let info = studio.assetInfo, let vtrack = info.videoTrack else { return }
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        let audioSrc = info.audioTracks
        let ca = audioSrc.compactMap { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        var at = CMTime.zero
        let ts: CMTimeScale = 60000
        for seg in studio.map.segments {
            if seg.isHold {
                // Freeze-frame: one frame of video stretched to the hold, silence for audio.
                let frame = CMTimeRange(start: CMTime(seconds: seg.srcStart, preferredTimescale: ts), duration: CMTime(value: 1, timescale: 60))
                let hold = CMTime(seconds: seg.holdDuration, preferredTimescale: ts)
                try? cv.insertTimeRange(frame, of: vtrack, at: at)
                cv.scaleTimeRange(CMTimeRange(start: at, duration: frame.duration), toDuration: hold)
                for track in ca { track.insertEmptyTimeRange(CMTimeRange(start: at, duration: hold)) }
                at = at + hold
                continue
            }
            let r = CMTimeRange(start: CMTime(seconds: seg.srcStart, preferredTimescale: ts), end: CMTime(seconds: seg.srcEnd, preferredTimescale: ts))
            try? cv.insertTimeRange(r, of: vtrack, at: at)
            for (i, a) in audioSrc.enumerated() where i < ca.count { try? ca[i].insertTimeRange(r, of: a, at: at) }
            var dur = r.duration
            if abs(seg.rate - 1) > 0.001 {
                let scaled = CMTime(seconds: dur.seconds / seg.rate, preferredTimescale: ts)
                comp.scaleTimeRange(CMTimeRange(start: at, duration: dur), toDuration: scaled)
                dur = scaled
            }
            at = at + dur
        }
        cv.preferredTransform = info.transform
        let item = AVPlayerItem(asset: comp)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        videoOutput = out
        compositionAsset = comp
        player.replaceCurrentItem(with: item)
        seek(to: min(currentTime, max(0, duration - 0.01)))
    }

    func togglePlay() {
        if isPlaying { player.pause(); isPlaying = false }
        else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play(); isPlaying = true
        }
    }

    func seek(to t: Double) {
        let c = clamp(t, 0, max(0, duration))
        currentTime = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        renderVersion += 1
    }

    func step(_ frames: Int) { seek(to: currentTime + Double(frames) / 60) }

    // MARK: Thumbnails

    func makeThumbnails() async {
        guard let asset = studio.asset else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let n = 24
        var imgs: [CGImage] = []
        for i in 0..<n {
            let s = studio.sourceDuration * (Double(i) + 0.5) / Double(n)
            if let (img, _) = try? await gen.image(at: CMTime(seconds: s, preferredTimescale: 600)) { imgs.append(img) }
        }
        thumbnails = imgs
    }

    // MARK: Zoom editing (UI works in output time; storage is source time)

    func addZoom(atOutput t: Double) {
        let s0 = studio.map.source(atOutput: max(0, t - 0.2))
        let s1 = studio.map.source(atOutput: min(duration, t + 2.2))
        var z = ZoomSegment(start: s0, end: max(s1, s0 + 0.5), level: project.zoom.level, mode: project.zoom.mode)
        if let c = studio.cursor.hasData ? studio.cursor.position(at: s0) : nil {
            z.focus = NPoint(x: round3(Double(c.x) / studio.videoSize.width), y: round3(Double(c.y) / studio.videoSize.height))
        }
        project.zoom.segments.append(z)
        project.zoom.segments.sort { $0.start < $1.start }
        selectedZoom = z.id
    }

    func updateZoom(_ id: String, outStart: Double? = nil, outEnd: Double? = nil, _ change: ((inout ZoomSegment) -> Void)? = nil) {
        guard let i = project.zoom.segments.firstIndex(where: { $0.id == id }) else { return }
        var z = project.zoom.segments[i]
        if let a = outStart { z.start = round3(studio.map.source(atOutput: max(0, a))) }
        if let b = outEnd { z.end = round3(studio.map.source(atOutput: min(duration, b))) }
        if z.end - z.start < 0.3 { z.end = z.start + 0.3 }
        change?(&z)
        z.auto = false
        project.zoom.segments[i] = z
    }

    func deleteSelected() {
        if let id = selectedZoom {
            project.zoom.segments.removeAll { $0.id == id }
            selectedZoom = nil
            tab = .cursor
        } else if let p = selectedPiece {
            cutPiece(p)
        } else if let i = selectedText, i < project.overlays.count {
            project.overlays.remove(at: i); selectedText = nil
        }
    }

    // MARK: Cutting

    /// Pieces of the timeline between splits, in source time (within kept content).
    var pieces: [(Double, Double)] {
        let a = studio.map.segments.first?.srcStart ?? 0
        let b = studio.map.segments.last?.srcEnd ?? studio.sourceDuration
        let pts = ([a] + splits.filter { $0 > a && $0 < b }.sorted() + [b])
        return zip(pts, pts.dropFirst()).map { ($0, $1) }
    }

    func splitAtPlayhead() { split(atOutput: currentTime) }

    func split(atOutput t: Double) {
        let s = round3(studio.map.source(atOutput: t))
        if !splits.contains(where: { abs($0 - s) < 0.05 }) { splits.append(s) }
        splits.sort()
    }

    func cutPiece(_ i: Int) {
        let ps = pieces
        guard i < ps.count, ps.count > 1 else { return }
        project.timeline.cuts.append(TimeRange(start: ps[i].0, end: ps[i].1))
        splits.removeAll { abs($0 - ps[i].0) < 0.01 || abs($0 - ps[i].1) < 0.01 }
        selectedPiece = nil
    }

    func resetCuts() {
        project.timeline.cuts = []
        project.timeline.speed = project.timeline.speed.filter { !$0.auto }
        splits = []
    }

    // MARK: Soundtrack

    /// Narration error to show (no voice set up, network failure).
    @Published var narrationError: String? = nil
    @Published var narrating = false

    /// Speak a line at an output time with the studio voice (ElevenLabs / OpenAI), off the main thread.
    func addNarration(_ text: String, at t: Double) {
        let dir = studio.baseURL.appendingPathComponent("sources/vo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(format: "vo_%02d_%d", project.audio.voiceover.count, Int(Date().timeIntervalSince1970) % 100000)
        let spec = project.audio.voice
        guard Narrator.isAvailable(spec) else { narrationError = Narrator.unavailableReason(spec); return }
        narrating = true
        Task.detached {
            do {
                let sp = try Narrator.synthesize(text, spec: spec, to: dir.appendingPathComponent(name))
                await MainActor.run {
                    self.narrating = false
                    self.project.audio.voiceover.append(VoiceClip(path: "sources/vo/\(URL(fileURLWithPath: sp.file).lastPathComponent)", at: round3(t),
                                                                  text: sp.text, duration: sp.duration, words: sp.words, time: "output"))
                    self.project.audio.voiceover.sort { $0.at < $1.at }
                    if self.project.audio.mode == "music" || self.project.audio.mode == "none" { self.project.audio.mode = "both" }
                }
            } catch {
                await MainActor.run { self.narrating = false; self.narrationError = "\(error)" }
            }
        }
    }

    @Published var usingTrack: String? = nil

    /// Use a real track (catalog or licensed library): download, analyze tempo, copy into the bundle.
    func useTrack(_ t: MusicLibrary.Track) {
        usingTrack = t.id
        let base = studio.baseURL
        let hasVoice = !project.audio.voiceover.isEmpty
        Task.detached {
            var spec = try? MusicLibrary.spec(for: t)
            if let s = spec?.path {
                let src = URL(fileURLWithPath: s)
                let dst = base.appendingPathComponent("sources/music.\(src.pathExtension)")
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { spec?.path = "sources/music.\(src.pathExtension)" }
                spec?.volume = hasVoice ? 0.2 : 0.6
            }
            let final = spec
            await MainActor.run {
                self.usingTrack = nil
                if let spec = final {
                    self.project.audio.music = spec
                    if self.project.audio.mode == "voiceover" || self.project.audio.mode == "none" { self.project.audio.mode = hasVoice ? "both" : "music" }
                }
            }
        }
    }

    func setMusic(_ u: URL) {
        project.audio.music.path = u.path
        project.audio.music.generate = nil
        let url = u
        Task.detached {
            let r = try? BeatDetect.analyze(url)
            await MainActor.run { self.project.audio.music.bpm = r?.bpm; self.project.audio.music.beatOffset = r?.firstBeat }
        }
    }

    func generateMusic(mood: String, bpm: Double?, done: @escaping () -> Void) {
        var g = MusicGenSpec(); g.mood = mood; g.bpm = bpm
        let out = studio.baseURL.appendingPathComponent("sources/music.wav")
        let dur = duration
        Task.detached {
            let r = try? MusicGen.render(g, duration: dur, to: out)
            await MainActor.run {
                if let r {
                    self.project.audio.music.path = "sources/music.wav"; self.project.audio.music.bpm = r.bpm
                    self.project.audio.music.beatOffset = 0; self.project.audio.music.offset = 0; self.project.audio.music.generate = g
                    self.project.audio.music.track = nil; self.project.audio.music.title = "Original score"; self.project.audio.music.artist = "Pretty Studio"
                    self.project.audio.music.license = MusicLicense(name: "Generated (Pretty Studio)", source: "generated")
                    if self.project.audio.mode == "voiceover" || self.project.audio.mode == "none" { self.project.audio.mode = "both" }
                }
                done()
            }
        }
    }

    // MARK: Auto

    func regenerateZooms() {
        let auto = AutoEdit.smartZooms(events: studio.events, duration: studio.sourceDuration, level: project.zoom.level,
                                       mode: project.zoom.mode, kind: project.source.kind)
        let manual = project.zoom.segments.filter { !$0.auto }
        project.zoom.segments = (manual + auto.filter { a in !manual.contains { $0.start < a.end && a.start < $0.end } }).sorted { $0.start < $1.start }
    }

    func compressIdle() {
        guard let v = studio.videoURL else { return }
        let spec = project.timeline.idle
        let ev = studio.events, dur = studio.sourceDuration
        let ts = project.timeline.trimStart, te = project.timeline.trimEnd
        Task.detached {
            let fr = Media.freezes(v)
            let r = AutoEdit.idleRanges(events: ev, duration: dur, freezes: fr, spec: spec, trimStart: ts, trimEnd: te)
            await MainActor.run {
                self.project.timeline.idle.compress = true
                self.project.timeline.cuts = self.project.timeline.cuts.filter { !$0.auto } + r.cuts
                self.project.timeline.speed = self.project.timeline.speed.filter { !$0.auto } + r.speed
            }
        }
    }
}
