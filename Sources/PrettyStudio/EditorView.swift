import SwiftUI
import AppKit
import PrettyCore

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                iconRail
                Divider().opacity(0.3)
                InspectorView(model: model)
                    .frame(width: 280)
                    .background(Color(white: 0.135))
                Divider().opacity(0.3)
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        PreviewView(model: model)
                            .padding(18)
                        if model.manualFocusPick {
                            Text("Click where the zoom should focus").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.accentColor)).padding(22)
                        }
                    }
                    transport
                }
                .background(Color(white: 0.118))
            }
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    Button { model.bladeMode.toggle() } label: {
                        Image(systemName: "scissors").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(model.bladeMode ? Color.accentColor : Color.white.opacity(0.07)))
                    }.buttonStyle(.plain).help("Cut tool (B). ⌘B splits at the playhead; select a piece and press Delete.")
                    Spacer()
                }
                .padding(.top, 34).frame(width: 52)
                TimelineView(model: model)
            }
            .frame(height: 168)
            .background(Color(white: 0.1))
        }
        .background(Color(white: 0.118))
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.24, green: 0.51, blue: 0.97))
        .sheet(isPresented: $showExport) { ExportSheet(model: model, isPresented: $showExport) }
        .onReceive(NotificationCenter.default.publisher(for: .prettyExport)) { n in
            if (n.object as? EditorModel) === model { showExport = true }
        }
    }

    var titleBar: some View {
        ZStack {
            HStack(spacing: 6) {
                Text(model.name).font(.system(size: 13, weight: .semibold))
                if model.edited { Text("Edited").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                if model.isPlaying == false && model.studio.events.clicks.isEmpty && model.studio.hasVideo {
                    Text("No cursor data").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.bundleURL]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.bordered).controlSize(.small).help("Show project in Finder")
                Button("Export") { showExport = true }
                    .buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut("e", modifiers: .command)
            }
            .padding(.trailing, 12)
        }
        .frame(height: 38)
        .background(Color(white: 0.16))
    }

    var iconRail: some View {
        VStack(spacing: 12) {
            ForEach(InspectorTab.allCases) { tab in
                Button { model.tab = tab; if tab != .zoom { model.selectedZoom = nil } } label: {
                    Image(systemName: tab.symbol).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(model.tab == tab ? Color.accentColor : Color.clear))
                        .foregroundStyle(model.tab == tab ? .white : .secondary)
                }.buttonStyle(.plain).help(tab.title)
            }
            Spacer()
        }
        .padding(.top, 14)
        .frame(width: 52)
        .background(Color(white: 0.135))
    }

    var transport: some View {
        HStack {
            Text("\(fmt(model.currentTime)) / \(fmt(model.duration))").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Spacer()
            HStack(spacing: 22) {
                Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18)) }
                Button { model.seek(to: model.duration) } label: { Image(systemName: "forward.end.fill") }
            }.buttonStyle(.plain).font(.system(size: 14))
            Spacer()
            if let s = model.exportSettings {
                Text("\(s.width)×\(s.height) · \(s.fps) fps").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18).frame(height: 40)
    }

    func fmt(_ t: Double) -> String { String(format: "%02d:%02d.%d", Int(t) / 60, Int(t) % 60, Int((t * 10).truncatingRemainder(dividingBy: 10))) }
}

extension Notification.Name { static let prettyExport = Notification.Name("prettyExport") }

// MARK: - Export

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Binding var isPresented: Bool
    @State private var preset = "auto"
    @State private var resolution = "1080p"
    @State private var quality = 2.0
    @State private var fps = 60
    @State private var audio = true
    @State private var progress: Double?
    @State private var result: String?
    @State private var error: String?

    let qualities = ["low", "medium", "high", "max"]

    var spec: ExportSpec {
        var e = ExportSpec()
        if preset != "auto" { e.preset = preset } else { e.resolution = resolution; e.fps = fps }
        e.quality = qualities[Int(quality)]
        e.audio = audio
        return e
    }

    var settings: ExportSettings? { try? ExportSettings.resolve(model.studio, overrides: spec) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.system(size: 15, weight: .bold))
            Picker("Preset", selection: $preset) {
                Text("Custom").tag("auto")
                ForEach(Presets.all.filter { !["reels", "shorts"].contains($0.name) }, id: \.name) { Text($0.name).tag($0.name) }
            }
            if preset == "auto" {
                Picker("Resolution", selection: $resolution) {
                    ForEach(["original", "4k", "1440p", "1080p", "720p"], id: \.self) { r in
                        Text(r == "original" ? "Original" : r).tag(r)
                    }
                }
                Picker("Frame rate", selection: $fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.pickerStyle(.segmented)
            }
            Divider()
            HStack { Text("Quality"); Spacer(); Text(qualities[Int(quality)].capitalized).foregroundStyle(.secondary) }
            Slider(value: $quality, in: 0...3, step: 1)
            Divider()
            Toggle("Audio", isOn: $audio).toggleStyle(.switch)
            Divider()
            if let s = settings {
                HStack { Text("Output").foregroundStyle(.secondary); Spacer(); Text("\(s.width)×\(s.height) · \(s.fps) fps · \(s.format.uppercased())") }
                HStack { Text("Estimated file size").foregroundStyle(.secondary); Spacer()
                    Text(String(format: "~%.1f MB", Double(s.bitrate) * model.duration / 8 / 1_048_576)) }
                ForEach(s.notes, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange) }
            }
            if let p = progress { ProgressView(value: p) }
            if let r = result {
                HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(URL(fileURLWithPath: r).lastPathComponent).lineLimit(1) }
            }
            if let e = error { Text(e).font(.system(size: 11)).foregroundStyle(.red).lineLimit(4) }
            HStack {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if let r = result {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r)]) }
                }
                Button("Export") { run() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(progress != nil && result == nil)
            }
        }
        .padding(22)
        .frame(width: 380)
        .onAppear { if let pr = model.project.export.preset { preset = pr } }
    }

    func run() {
        model.saveNow()
        guard let s = settings else { return }
        let project = model.project
        let pURL = model.studio.projectURL, base = model.studio.baseURL
        let renders = base.appendingPathComponent("renders")
        let ext = s.format == "gif" ? "gif" : s.format == "webm" ? "webm" : (s.codec == "prores" ? "mov" : "mp4")
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var n = 1
        var out: URL
        repeat {
            out = renders.appendingPathComponent(String(format: "%@_%@_%@_v%02d.%@", df.string(from: Date()),
                                                        project.name.lowercased().replacingOccurrences(of: " ", with: "-"),
                                                        s.preset?.name ?? "\(s.width)x\(s.height)", n, ext))
            n += 1
        } while FileManager.default.fileExists(atPath: out.path)
        progress = 0; result = nil; error = nil
        let target = out
        Task.detached {
            do {
                let studio = try Studio(project: project, projectURL: pURL, baseURL: base)
                let ex = Exporter(studio: studio, settings: s)
                ex.progress = { p in DispatchQueue.main.async { progress = p } }
                let r = try ex.run(to: target)
                await MainActor.run { result = r.output; progress = 1 }
            } catch {
                await MainActor.run { self.error = "\(error)"; progress = nil }
            }
        }
    }
}
