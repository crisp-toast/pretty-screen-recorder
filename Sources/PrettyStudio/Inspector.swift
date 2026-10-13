import SwiftUI
import AppKit
import PrettyCore

// MARK: - Building blocks (CleanShot-like dark controls)

struct Label2: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary) }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.055)))
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Label2(text: title); Spacer(); Text(format(value)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit() }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

struct Segmented: View {
    let options: [(String, String)]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { opt in
                Button { selection = opt.0 } label: {
                    Text(opt.1).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selection == opt.0 ? Color.accentColor : Color.white.opacity(0.08)))
                        .foregroundStyle(selection == opt.0 ? .white : .primary)
                }.buttonStyle(.plain)
            }
        }
    }
}

struct CheckRow: View {
    let title: String
    @Binding var on: Bool
    var body: some View { Toggle(title, isOn: $on).toggleStyle(.checkbox).font(.system(size: 12.5)) }
}

struct SwitchRow: View {
    let title: String
    @Binding var on: Bool
    var body: some View {
        HStack { Text(title).font(.system(size: 12.5)); Spacer(); Toggle("", isOn: $on).toggleStyle(.switch).controlSize(.small).labelsHidden() }
    }
}

let namedColors: [(String, Color)] = [
    ("blue", Color(red: 0.23, green: 0.51, blue: 0.96)), ("white", .white), ("black", .black), ("red", Color(red: 0.94, green: 0.27, blue: 0.27)),
    ("orange", Color(red: 0.98, green: 0.45, blue: 0.09)), ("yellow", Color(red: 0.98, green: 0.8, blue: 0.08)), ("green", Color(red: 0.13, green: 0.77, blue: 0.37)),
    ("purple", Color(red: 0.66, green: 0.33, blue: 0.97)), ("pink", Color(red: 0.93, green: 0.28, blue: 0.6)),
]

extension Color {
    init(hex: String) {
        let c = RGBA.parse(hex) ?? RGBA(0.5, 0.5, 0.5)
        self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.tab {
                case .cursor: CursorPanel(p: $model.project)
                case .keystrokes: KeystrokePanel(p: $model.project, hasKeys: !model.studio.events.keys.isEmpty)
                case .audio: AudioPanel(model: model)
                case .camera: CameraPanel(model: model)
                case .background: BackgroundPanel(model: model)
                case .motion: MotionPanel(p: $model.project)
                case .zoom: ZoomPanel(model: model)
                case .text: TextPanel(model: model)
                }
            }
            .padding(16)
        }
    }
}

struct CursorPanel: View {
    @Binding var p: Project
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label2(text: "Cursor")
            SwitchRow(title: "Show cursor", on: $p.cursor.show)
            SliderRow(title: "Size", value: $p.cursor.size, range: 0.75...3, format: { String(format: "%.1fx", $0) })
            Label2(text: "Style")
            HStack(spacing: 8) {
                ForEach([("macos", "cursorarrow"), ("white", "cursorarrow"), ("dot", "circle.fill"), ("touch", "hand.point.up.fill")], id: \.0) { s in
                    Button { p.cursor.style = s.0 } label: {
                        Image(systemName: s.1).font(.system(size: 15, weight: .medium))
                            .foregroundStyle(s.0 == "white" ? Color.white : (s.0 == "dot" ? Color.gray : Color.primary))
                            .frame(width: 40, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.cursor.style == s.0 ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).help(s.0)
                }
            }
            Label2(text: "Motion")
            Segmented(options: [("natural", "Natural"), ("smooth", "Smooth"), ("raw", "Raw")], selection: $p.cursor.motion)
            Label2(text: "Clicks")
            CheckRow(title: "Press effect", on: $p.cursor.pressEffect)
            CheckRow(title: "Ripple animation", on: $p.cursor.ripple.enabled)
            if p.cursor.ripple.enabled {
                Card {
                    Label2(text: "Color")
                    HStack(spacing: 7) {
                        ForEach(namedColors, id: \.0) { c in
                            Circle().fill(c.1).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(p.cursor.ripple.color == c.0 ? Color.accentColor : Color.white.opacity(0.25), lineWidth: p.cursor.ripple.color == c.0 ? 2.5 : 1))
                                .onTapGesture { p.cursor.ripple.color = c.0 }
                        }
                    }
                    Label2(text: "Style")
                    Segmented(options: [("outline", "Outline"), ("filled", "Filled")], selection: $p.cursor.ripple.style)
                }
            }
            Label2(text: "Options")
            CheckRow(title: "Hide cursor when not moving", on: $p.cursor.hideWhenIdle)
            CheckRow(title: "Hide cursor while typing", on: $p.cursor.hideWhileTyping)
            CheckRow(title: "Cursor shadow", on: $p.cursor.shadow)
        }
    }
}

struct KeystrokePanel: View {
    @Binding var p: Project
    let hasKeys: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label2(text: "Keystrokes")
            SwitchRow(title: "Show keystrokes", on: $p.keystrokes.show)
            if !hasKeys {
                Text("No keystrokes were recorded. Agents can add them with `pretty mark key`.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SliderRow(title: "Size", value: $p.keystrokes.size, range: 0.6...2, format: { String(format: "%.1fx", $0) })
            Label2(text: "Style")
            Segmented(options: [("dark", "Dark"), ("light", "Light")], selection: $p.keystrokes.theme)
            Label2(text: "Show")
            Segmented(options: [("all", "All keys"), ("shortcuts", "Shortcuts only")], selection: $p.keystrokes.mode)
            Label2(text: "Position")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"], id: \.self) { pos in
                    Button { p.keystrokes.position = pos } label: {
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)).frame(height: 30)
                            .overlay(alignment: alignment(pos)) { RoundedRectangle(cornerRadius: 2).fill(p.keystrokes.position == pos ? Color.accentColor : Color.white.opacity(0.5)).frame(width: 16, height: 6).padding(5) }
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.keystrokes.position == pos ? Color.accentColor : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }
            }
            SliderRow(title: "Hold", value: $p.keystrokes.hold, range: 0.4...3, format: { String(format: "%.1fs", $0) })
        }
    }
    func alignment(_ pos: String) -> Alignment {
        switch pos {
        case "top-left": return .topLeading
        case "top-center": return .top
        case "top-right": return .topTrailing
        case "bottom-left": return .bottomLeading
        case "bottom-right": return .bottomTrailing
        default: return .bottom
        }
    }
}

struct AudioPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label2(text: "Microphone")
            if model.project.source.mic == nil && (model.studio.asset?.tracks(withMediaType: .audio).count ?? 0) < 2 {
                Card { HStack(spacing: 10) { Image(systemName: "mic.slash"); Text("No microphone was selected for this recording.").font(.system(size: 12)) }.foregroundStyle(.secondary) }
            } else {
                SwitchRow(title: "Include microphone", on: $model.project.audio.mic)
                SliderRow(title: "Microphone volume", value: $model.project.audio.micVolume, range: 0...2)
            }
            Label2(text: "System audio")
            SwitchRow(title: "Include system audio", on: $model.project.audio.system)
            Card { SliderRow(title: "System audio volume", value: $model.project.audio.systemVolume, range: 0...2) }
            Label2(text: "Clicks")
            SwitchRow(title: "Click sounds", on: $model.project.audio.clickSounds)
            Label2(text: "Music")
            Card {
                HStack {
                    Text(model.project.audio.music.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None").font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let u = panel.url { model.project.audio.music.path = u.path }
                    }.controlSize(.small)
                    if model.project.audio.music.path != nil { Button { model.project.audio.music.path = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }
                SliderRow(title: "Music volume", value: $model.project.audio.music.volume, range: 0...1)
                CheckRow(title: "Duck under voice", on: $model.project.audio.music.duck)
            }
            SwitchRow(title: "Normalize loudness (−14 LUFS)", on: $model.project.audio.normalize)
            Text("The preview plays recorded audio; music, click sounds and normalization are applied on export.").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

struct CameraPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label2(text: "Camera")
            if model.project.source.camera == nil {
                Card {
                    HStack(spacing: 10) { Image(systemName: "video.slash"); Text("No camera was recorded.").font(.system(size: 12)) }.foregroundStyle(.secondary)
                    Button("Add camera / presenter video…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]
                        if panel.runModal() == .OK, let u = panel.url {
                            let dst = model.studio.baseURL.appendingPathComponent("sources/camera.\(u.pathExtension)")
                            try? FileManager.default.removeItem(at: dst)
                            try? FileManager.default.copyItem(at: u, to: dst)
                            model.project.source.camera = "sources/camera.\(u.pathExtension)"
                        }
                    }.controlSize(.small)
                }
            } else {
                SwitchRow(title: "Show camera", on: $model.project.camera.show)
                Label2(text: "Shape")
                HStack(spacing: 8) {
                    ForEach([("circle", "circle.fill"), ("square", "square.fill"), ("rectangle", "rectangle.fill"), ("vertical", "rectangle.portrait.fill")], id: \.0) { s in
                        Button { model.project.camera.shape = s.0 } label: {
                            Image(systemName: s.1).frame(width: 44, height: 32)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.project.camera.shape == s.0 ? Color.accentColor : .clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
                SliderRow(title: "Size", value: $model.project.camera.size, range: 0.1...0.5)
                Label2(text: "Position")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 3), spacing: 6) {
                    ForEach(["top-left", "top-center", "top-right", "middle-left", "center", "middle-right", "bottom-left", "bottom-center", "bottom-right"], id: \.self) { pos in
                        Circle().fill(model.project.camera.position == pos ? Color.accentColor : Color.white.opacity(0.18)).frame(width: 12, height: 12)
                            .frame(width: 44, height: 28).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                            .onTapGesture { model.project.camera.position = pos }
                    }
                }
                CheckRow(title: "Flip horizontally", on: $model.project.camera.flip)
                CheckRow(title: "Shrink during zooms", on: $model.project.camera.shrinkOnZoom)
                SliderRow(title: "Border", value: $model.project.camera.border, range: 0...12, format: { String(format: "%.0fpx", $0) })
            }
        }
    }
}

struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel
    @State private var showAll = false
    static var swatchCache: [String: NSImage] = [:]

    var body: some View {
        let p = $model.project
        VStack(alignment: .leading, spacing: 14) {
            Label2(text: "Background")
            HStack(spacing: 8) {
                Button("None") { p.wrappedValue.background.type = "none" }.buttonStyle(.bordered)
                Button("Blurred") { p.wrappedValue.background.type = "blur" }.buttonStyle(.bordered)
            }.controlSize(.small)
            HStack { Label2(text: "Gradients"); Spacer(); Button(showAll ? "Show less" : "Show more") { showAll.toggle() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 5), spacing: 8) {
                ForEach(Array(Backgrounds.presets.prefix(showAll ? 20 : 10)), id: \.name) { g in
                    Image(nsImage: swatch(g.name)).resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.wrappedValue.background.type == "gradient" && p.wrappedValue.background.preset == g.name && p.wrappedValue.background.colors.isEmpty ? Color.white : .clear, lineWidth: 2))
                        .onTapGesture { p.wrappedValue.background.type = "gradient"; p.wrappedValue.background.preset = g.name; p.wrappedValue.background.colors = [] }
                        .help(g.name)
                }
            }
            Label2(text: "Wallpaper")
            HStack(spacing: 8) {
                if let img = p.wrappedValue.background.image, let ns = NSImage(contentsOf: model.studio.resolve(img)) {
                    Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.wrappedValue.background.type == "image" ? Color.white : .clear, lineWidth: 2))
                        .onTapGesture { p.wrappedValue.background.type = "image" }
                }
                Button {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let u = panel.url { p.wrappedValue.background.type = "image"; p.wrappedValue.background.image = u.path }
                } label: { Image(systemName: "plus").frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08))) }.buttonStyle(.plain)
            }
            if p.wrappedValue.background.type == "image" {
                SliderRow(title: "Wallpaper blur", value: p.background.blur, range: 0...60, format: { String(format: "%.0f", $0) })
            }
            Label2(text: "Plain color")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 8), count: 8), spacing: 8) {
                ForEach(["#000000", "#FFFFFF", "#EF4444", "#F97316", "#FACC15", "#22C55E", "#3B82F6", "#A855F7",
                         "#1C1C1E", "#F4F4F6", "#FCA5A5", "#FDBA74", "#FDE68A", "#86EFAC", "#93C5FD", "#D8B4FE"], id: \.self) { c in
                    Circle().fill(Color(hex: c)).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(p.wrappedValue.background.type == "color" && p.wrappedValue.background.color.uppercased() == c ? Color.accentColor : Color.white.opacity(0.2), lineWidth: 1.5))
                        .onTapGesture { p.wrappedValue.background.type = "color"; p.wrappedValue.background.color = c }
                }
            }
            ColorPicker("Custom color", selection: Binding(get: { Color(hex: p.wrappedValue.background.color) },
                                                           set: { p.wrappedValue.background.type = "color"; p.wrappedValue.background.color = $0.hexString }))
                .font(.system(size: 12))
            Divider().opacity(0.4)
            Label2(text: "Aspect ratio")
            Picker("", selection: p.layout.aspect) {
                ForEach(["auto", "16:9", "9:16", "1:1", "4:5", "5:4", "4:3", "3:4", "3:2", "21:9"], id: \.self) { Text($0 == "auto" ? "Auto" : $0).tag($0) }
            }.labelsHidden().onChange(of: model.project.layout.aspect) { _, _ in model.project.export.preset = nil }
            Label2(text: "Frame")
            Picker("", selection: p.frame.type) {
                ForEach(["auto", "none", "window", "browser", "iphone", "ipad", "android", "macbook"], id: \.self) { Text($0.capitalized).tag($0) }
            }.labelsHidden()
            Segmented(options: [("light", "Light"), ("dark", "Dark")], selection: p.frame.theme)
            SliderRow(title: "Padding", value: p.layout.padding, range: 0...0.3)
            SliderRow(title: "Shadow", value: p.layout.shadow, range: 0...1)
            SliderRow(title: "Corners", value: p.layout.corners, range: 0...0.1)
            SliderRow(title: "Title space (top)", value: p.layout.headroom, range: 0...0.35)
            SliderRow(title: "CTA space (bottom)", value: p.layout.footroom, range: 0...0.35)
            Segmented(options: [("contain", "Fit"), ("cover", "Fill & follow")], selection: p.layout.fit)
        }
    }

    func swatch(_ name: String) -> NSImage {
        if let c = Self.swatchCache[name] { return c }
        var spec = BackgroundSpec(); spec.preset = name
        let img = Backgrounds.render(spec, size: CGSize(width: 80, height: 80), brand: [], baseURL: nil)
        let cg = Render.context.createCGImage(img, from: CGRect(x: 0, y: 0, width: 80, height: 80), format: .RGBA8, colorSpace: sRGB)!
        let ns = NSImage(cgImage: cg, size: NSSize(width: 40, height: 40))
        Self.swatchCache[name] = ns
        return ns
    }
}

struct MotionPanel: View {
    @Binding var p: Project
    var body: some View {
        let levels = ["off", "low", "medium", "high"]
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label2(text: "Motion Blur"); Spacer(); Text(p.motion.blur.capitalized).font(.system(size: 12, weight: .semibold)) }
            Slider(value: Binding(get: { Double(levels.firstIndex(of: p.motion.blur) ?? 2) }, set: { p.motion.blur = levels[Int($0.rounded())] }),
                   in: 0...3, step: 1).controlSize(.small)
            Label2(text: "Zoom animations")
            Segmented(options: [("smooth", "Smooth"), ("dynamic", "Dynamic")], selection: $p.motion.zoomAnimation)
            Label2(text: "3D tilt")
            SliderRow(title: "Tilt X", value: $p.layout.tiltX, range: -20...20, format: { String(format: "%.0f°", $0) })
            SliderRow(title: "Tilt Y", value: $p.layout.tiltY, range: -20...20, format: { String(format: "%.0f°", $0) })
        }
    }
}

struct ZoomPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let id = model.selectedZoom, let z = model.project.zoom.segments.first(where: { $0.id == id }) {
                HStack { Label2(text: "Zoom level"); Spacer(); Text("\(Int((z.level * 100).rounded()))%").font(.system(size: 12, weight: .semibold)) }
                Slider(value: Binding(get: { z.level }, set: { v in model.updateZoom(id) { $0.level = (v * 20).rounded() / 20 } }), in: 1.1...3.5).controlSize(.small)
                Button("Apply Zoom Level to All") {
                    for i in model.project.zoom.segments.indices { model.project.zoom.segments[i].level = z.level }
                    model.project.zoom.level = z.level
                }.buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                Label2(text: "Zoom mode")
                Segmented(options: [("follow", "Follow Cursor"), ("manual", "Manual")],
                          selection: Binding(get: { z.mode }, set: { m in
                              model.updateZoom(id) { $0.mode = m }
                              if m == "manual" { model.manualFocusPick = true }
                          }))
                if z.mode == "manual" {
                    Button(model.manualFocusPick ? "Click the preview to set focus…" : "Pick focus on preview") { model.manualFocusPick.toggle() }
                        .buttonStyle(.bordered).controlSize(.small)
                    if let f = z.focus { Text(String(format: "Focus %.2f, %.2f", f.x, f.y)).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Label2(text: "Animation")
                Segmented(options: [("smooth", "Smooth"), ("dynamic", "Dynamic")], selection: $model.project.motion.zoomAnimation)
                Button(role: .destructive) { model.deleteSelected() } label: { Label("Delete Zoom", systemImage: "trash") }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Label2(text: "Zooms")
                Text("Click the zoom track to add a zoom. Click a zoom to edit it; drag its edges to change timing.").font(.system(size: 12)).foregroundStyle(.secondary)
                SliderRow(title: "Default level", value: $model.project.zoom.level, range: 1.1...3, format: { String(format: "%.0f%%", $0 * 100) })
                Button("Regenerate Smart Zooms") { model.regenerateZooms() }.buttonStyle(.bordered).controlSize(.small)
                SliderRow(title: "Follow dead zone", value: $model.project.zoom.followDeadzone, range: 0...0.9)
            }
        }
    }
}

struct TextPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label2(text: "Text overlays"); Spacer()
                Button {
                    var o = Overlay(); o.type = "text"; o.text = "Your headline"; o.start = model.currentTime; o.end = model.currentTime + 3
                    model.project.overlays.append(o); model.selectedText = model.project.overlays.count - 1
                } label: { Image(systemName: "plus") }.buttonStyle(.bordered).controlSize(.small)
            }
            ForEach(Array(model.project.overlays.enumerated()), id: \.offset) { i, o in
                if o.type == "text" {
                    Button { model.selectedText = i } label: {
                        HStack { Text(o.text ?? "").lineLimit(1).font(.system(size: 12)); Spacer()
                            Text(String(format: "%.1f–%.1fs", o.start, o.end)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary) }
                            .padding(8).background(RoundedRectangle(cornerRadius: 7).fill(model.selectedText == i ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
                    }.buttonStyle(.plain)
                }
            }
            if let i = model.selectedText, i < model.project.overlays.count {
                let b = $model.project.overlays[i]
                Card {
                    TextField("Text", text: Binding(get: { b.wrappedValue.text ?? "" }, set: { b.wrappedValue.text = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Picker("Style", selection: b.style) { ForEach(["hero", "title", "subtitle", "kicker", "caption", "label"], id: \.self) { Text($0.capitalized).tag($0) } }
                    Picker("Position", selection: b.position) { ForEach(["top", "center", "bottom"], id: \.self) { Text($0.capitalized).tag($0) } }
                    Picker("Animation", selection: Binding(get: { b.wrappedValue.animation }, set: { b.wrappedValue.animation = $0 })) { ForEach(["rise", "pop", "fade", "slide", "typewriter", "none"], id: \.self) { Text($0.capitalized).tag($0) } }
                    HStack {
                        Stepper(String(format: "Start %.1fs", b.wrappedValue.start), value: b.start, in: 0...max(model.duration, 0.1), step: 0.1)
                    }
                    Stepper(String(format: "End %.1fs", b.wrappedValue.end), value: b.end, in: 0...max(model.duration + 5, 0.1), step: 0.1)
                    SliderRow(title: "Size", value: b.size, range: 0.5...2, format: { String(format: "%.1fx", $0) })
                    Button(role: .destructive) { model.project.overlays.remove(at: i); model.selectedText = nil } label: { Label("Delete", systemImage: "trash") }
                        .controlSize(.small)
                }.font(.system(size: 12))
            }
        }
    }
}
