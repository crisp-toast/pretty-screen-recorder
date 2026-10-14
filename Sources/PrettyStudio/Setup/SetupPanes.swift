import SwiftUI
import AppKit
import PrettyCore

// MARK: - Shared pieces

/// Pretty Studio's signature colors (the app icon's gradient).
enum Brand {
    static let violet = Color(red: 0.43, green: 0.36, blue: 1)
    static let cyan = Color(red: 0.0, green: 0.76, blue: 1)
    static let pink = Color(red: 1, green: 0.37, blue: 0.64)
    static let gradient = LinearGradient(colors: [violet, cyan, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// A slow, soft glow of the app's colors behind the content.
struct AmbientGlow: View {
    @State private var phase = false
    var body: some View {
        ZStack {
            Circle().fill(Brand.violet.opacity(0.32)).frame(width: 420).blur(radius: 120)
                .offset(x: phase ? -170 : -120, y: phase ? -230 : -190)
            Circle().fill(Brand.cyan.opacity(0.22)).frame(width: 360).blur(radius: 120)
                .offset(x: phase ? 220 : 170, y: phase ? -170 : -220)
            Circle().fill(Brand.pink.opacity(0.14)).frame(width: 300).blur(radius: 110)
                .offset(x: phase ? 60 : 110, y: phase ? -260 : -300)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { phase = true } }
    }
}

struct StepHeader: View {
    var symbol: String
    var tint: Color = Brand.violet
    var title: String
    var subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.gradient))
                .shadow(color: tint.opacity(0.45), radius: 16, y: 6)
            Text(title).font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
        }
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct StatusDot: View {
    var state: SetupModel.Check.State
    var body: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
        case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .checking: ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Essentials

struct EssentialsPane: View {
    @ObservedObject var m: SetupModel
    var body: some View {
        Panel {
            ForEach(Array(m.checks.enumerated()), id: \.element.id) { i, c in
                HStack(spacing: 14) {
                    Image(systemName: c.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.system(size: 13, weight: .semibold))
                        Text(c.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    if let fix = c.fix { Button(fix) { m.perform(c) }.controlSize(.small) }
                    StatusDot(state: c.state).font(.system(size: 16))
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                if i < m.checks.count - 1 { Divider().padding(.leading, 52) }
            }
            if m.checks.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary); Spacer() }.padding(24)
            }
        }
        .onAppear { if m.checks.isEmpty { m.runChecks() } }
    }
}

// MARK: - Voice

struct ProviderCard: View {
    var title: String
    var detail: String
    var symbol: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(selected ? Color.white : Color.secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Color.accentColor : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct VoiceCard: View {
    var v: Narrator.VoiceInfo
    var selected: Bool
    var playing: Bool
    var loading: Bool
    var select: () -> Void
    var play: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                ZStack {
                    Circle().fill(selected ? Color.accentColor : Color.white.opacity(0.1)).frame(width: 30, height: 30)
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                }
            }.buttonStyle(.plain).help("Hear \(v.name)")
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(tags).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(selected ? Color.accentColor : Color.white.opacity(0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
    var tags: String {
        let keys = ["accent", "gender", "age", "use_case", "use case", "descriptive"]
        let ls = keys.compactMap { v.labels[$0] }.map { $0.replacingOccurrences(of: "_", with: " ") }
        if !ls.isEmpty { return ls.prefix(3).joined(separator: " · ").capitalized }
        return v.description ?? ""
    }
}

struct VoicePane: View {
    @ObservedObject var m: SetupModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProviderCard(title: "No narration", detail: "Your product's words carry the story as kinetic type. Never a robotic voice.",
                             symbol: "textformat.size", selected: m.provider == "none") { m.provider = "none" }
                ProviderCard(title: "ElevenLabs", detail: "The most natural voices, with Eleven v4. Word-exact timing.",
                             symbol: "waveform", selected: m.provider == "elevenlabs") { m.provider = "elevenlabs" }
                ProviderCard(title: "OpenAI", detail: "Expressive voices you direct in plain words (marin, cedar).",
                             symbol: "sparkles", selected: m.provider == "openai") { m.provider = "openai" }
            }
            if m.provider != "none" { keySection }
            if case .valid = m.keyState { voiceSection }
            if m.provider == "elevenlabs", let note = m.planNote {
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { m.refreshVoiceState(); m.refreshVideo() }
    }

    var providerName: String { m.provider == "openai" ? "OpenAI" : "ElevenLabs" }
    var keyURL: URL { URL(string: m.provider == "openai" ? "https://platform.openai.com/api-keys" : "https://elevenlabs.io/app/settings/api-keys")! }

    @ViewBuilder var keySection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("\(providerName) API key", systemImage: "key.fill").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Link(destination: keyURL) { Label("Get a key", systemImage: "arrow.up.right").font(.system(size: 12)) }
                }
                switch m.keyState {
                case .valid(let masked):
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Connected").font(.system(size: 12.5, weight: .medium))
                        Text(masked).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Replace…") { m.keyState = .none }.controlSize(.small)
                        Button("Remove", role: .destructive) { m.removeKey() }.controlSize(.small)
                    }
                default:
                    HStack(spacing: 8) {
                        SecureField(m.provider == "openai" ? "sk-…" : "Paste your API key", text: $m.keyInput)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                            .onSubmit { m.verifyKey() }
                        Button {
                            if let s = NSPasteboard.general.string(forType: .string) { m.keyInput = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        } label: { Image(systemName: "doc.on.clipboard") }.help("Paste")
                        Button(m.keyState == .verifying ? "Checking…" : "Connect") { m.verifyKey() }
                            .buttonStyle(.borderedProminent).disabled(m.keyInput.isEmpty || m.keyState == .verifying)
                    }
                    if case .invalid(let msg) = m.keyState {
                        Label(msg, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange)
                    }
                }
                Text("Stored in your login Keychain — never in projects or logs. Agents on this Mac can narrate with it; it's only sent to \(providerName).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    @ViewBuilder var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Voice").font(.system(size: 13, weight: .semibold))
                if m.loadingVoices { ProgressView().controlSize(.small) }
                Spacer()
                if m.provider == "elevenlabs" && m.voices.count > 8 {
                    TextField("Search voices", text: $m.voiceSearch).textFieldStyle(.roundedBorder).frame(width: 180).font(.system(size: 12))
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(m.filteredVoices, id: \.id) { v in
                        VoiceCard(v: v, selected: m.settings.voice.voiceId == v.id, playing: m.playingID == v.id,
                                  loading: m.synthesizing && m.playingID == v.id,
                                  select: { m.choose(v) }, play: { m.preview(v) })
                    }
                }
            }
            .frame(height: compact ? 170 : 190)
            HStack(spacing: 12) {
                if m.provider == "elevenlabs" {
                    Picker("Model", selection: Binding(get: { m.settings.voice.model ?? m.models.first ?? "eleven_v4" }, set: { m.settings.voice.model = $0 })) {
                        ForEach(m.models.isEmpty ? ["eleven_v4"] : m.models, id: \.self) { Text(SetupModel.modelName($0)).tag($0) }
                    }.frame(width: 250)
                    HStack(spacing: 6) {
                        Text("Expressive").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Slider(value: $m.settings.voice.style, in: 0...1).frame(width: 90)
                    }
                } else {
                    TextField("Direction (e.g. warm, upbeat product narrator)", text: Binding(get: { m.settings.voice.instructions ?? "" },
                                                                                          set: { m.settings.voice.instructions = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                }
                HStack(spacing: 6) {
                    Text("Pace").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Slider(value: $m.settings.voice.speed, in: 0.85...1.15).frame(width: 80)
                }
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                TextField("Try a line", text: $m.sampleText).textFieldStyle(.roundedBorder).font(.system(size: 12))
                Button { m.sample() } label: {
                    Label(m.synthesizing ? "Generating…" : "Hear it", systemImage: "play.circle.fill")
                }.disabled(m.synthesizing || m.settings.voice.voiceId == nil)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Music

struct MusicPane: View {
    @ObservedObject var m: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Panel {
                sourceRow(symbol: "waveform.badge.magnifyingglass", tint: Brand.violet, title: "Original score, composed for each video",
                          detail: "ElevenLabs Music writes a cinematic track that follows the edit — a quiet hook, a build through the demo, a lift at the reveal, a resolve on the end card. Needs a paid ElevenLabs plan.",
                          on: $m.settings.music.useComposed)
                Divider().padding(.leading, 52)
                sourceRow(symbol: "speaker.wave.2.fill", tint: .teal, title: "Sound design",
                          detail: "Subtle whooshes on transitions, a shimmer when the device lands, an impact on the end card.",
                          on: $m.settings.music.useSfx)
                Divider().padding(.leading, 52)
                HStack(spacing: 14) {
                    icon("folder.fill.badge.person.crop", .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your licensed library").font(.system(size: 13, weight: .semibold))
                        Text(m.settings.music.licensedFolder.map { "\(m.licensedCount) tracks in \(URL(fileURLWithPath: $0).lastPathComponent) — used first when they fit" }
                             ?? "Tracks you've licensed from Epidemic Sound, Artlist, Musicbed… used first when they fit.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(m.settings.music.licensedFolder == nil ? "Choose Folder…" : "Change…") { m.chooseLicensedFolder() }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.vertical, 12)
                Divider().padding(.leading, 52)
                sourceRow(symbol: "music.quarternote.3", tint: .orange, title: "Classic catalog — Kevin MacLeod (CC BY)",
                          detail: "Free with credit, but many tracks read as stock music. Off by default; a last resort.",
                          on: $m.settings.music.useIncompetech)
            }
            if let note = m.planNote {
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $m.settings.music.creditsOnScreen) {
                Text("Show the music credit at the end of videos when the license asks for one").font(.system(size: 12))
            }.toggleStyle(.checkbox)
            Text("Chart hits can't be licensed by credit alone — they need sync and master licenses. Each render writes a credits.txt with the exact lines to publish.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { m.loadMusic(); m.refreshVideo() }
    }

    func icon(_ s: String, _ c: Color) -> some View {
        Image(systemName: s).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.gradient))
    }

    func sourceRow(symbol: String, tint: Color, title: String, detail: String, on: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            icon(symbol, tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: on).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - Agents

struct AgentsPane: View {
    @ObservedObject var m: SetupModel
    let prompt = "Use Pretty Studio to make a 20-second TikTok ad for my app — tailored copy, kinetic type on the beat, real music."
    var body: some View {
        let _ = m.agentsVersion
        VStack(alignment: .leading, spacing: 12) {
            Panel {
                row(symbol: "terminal.fill", title: "Command-line tool", detail: m.cliInstalled.map { "pretty → \($0)" } ?? "Installs `pretty` in ~/.local/bin so agents can record, direct and render.",
                    ok: m.cliInstalled != nil, action: m.bundledCLI == nil ? nil : (m.cliInstalled == nil ? "Install" : "Reinstall")) { m.installCLI() }
                Divider().padding(.leading, 52)
                row(symbol: "book.closed.fill", title: "Agent skill", detail: m.skillInstalled ? "Claude Code and Codex know how to use Pretty Studio." : "Teaches Claude Code and Codex the workflow.",
                    ok: m.skillInstalled, action: m.skillInstalled ? "Update" : "Install") { m.installSkill() }
            }
            if m.cliInstalled != nil && !m.pathHasLocalBin {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Add ~/.local/bin to your PATH so shells find `pretty`.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Line") { m.copy("export PATH=\"$HOME/.local/bin:$PATH\"", note: "Copied — add it to ~/.zshrc") }.controlSize(.small)
                }
            }
            Text("Try asking your agent").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
            HStack(alignment: .top) {
                Text(prompt).font(.system(size: 12.5)).textSelection(.enabled)
                Spacer()
                Button { m.copy(prompt) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
        }
        .onAppear { m.checkShellPath() }
    }

    func row(symbol: String, title: String, detail: String, ok: Bool, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.gray.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            if let action { Button(action, action: perform).controlSize(.small) }
            StatusDot(state: ok ? .ok : .warn).font(.system(size: 16))
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}


// MARK: - Video & 3D

struct VideoPane: View {
    @ObservedObject var m: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Panel {
                tool(symbol: "cube.transparent.fill", tint: .orange, title: "3D device shots",
                     detail: m.blenderPath != nil ? "Ready: your real screen on a 3D phone or iPad — hero turns, orbits, flat-to-standing, close-ups, two-device duos — rendered with Blender."
                        : "Install Blender (free) and Pretty Studio renders 3D device shots for you — hero turns, orbits, close-ups, duos.",
                     ok: m.blenderPath != nil, action: m.blenderPath == nil ? ("Copy Install", "brew install --cask blender") : nil)
            }
            Text("AI B-roll — emotional shots a recording can't give you (hands, places, light). Your UI is never generated.")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
            Panel {
                keyRow("gemini", title: "Google Veo", detail: "Gemini API key", link: "https://aistudio.google.com/apikey")
                Divider().padding(.leading, 16)
                keyRow("openai", title: "OpenAI Sora 2", detail: "Same key as the OpenAI narrator", link: "https://platform.openai.com/api-keys")
                Divider().padding(.leading, 16)
                keyRow("fal", title: "fal.ai", detail: "Kling, Veo, Seedance and more with one key", link: "https://fal.ai/dashboard/keys")
            }
            Text("Keys are stored in your login Keychain. Generated clips are cached, labeled as AI footage, and every one is reviewed before it ships.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { m.refreshVideo() }
    }

    func tool(symbol: String, tint: Color, title: String, detail: String, ok: Bool, action: (String, String)?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let (label, cmd) = action { Button(label) { m.copy(cmd, note: "Copied “\(cmd)” — paste it into Terminal.") }.controlSize(.small) }
            StatusDot(state: ok ? .ok : .warn).font(.system(size: 16))
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    func keyRow(_ account: String, title: String, detail: String, link: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if let u = URL(string: link) { Link(destination: u) { Label("Get a key", systemImage: "arrow.up.right").font(.system(size: 11.5)) } }
            }
            switch m.videoKeyState[account] ?? .none {
            case .valid(let masked):
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Connected").font(.system(size: 12))
                    Text(masked).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { m.removeVideoKey(account) }.controlSize(.small)
                }
            default:
                HStack(spacing: 8) {
                    SecureField("Paste key", text: Binding(get: { m.videoKeyInput[account] ?? "" }, set: { m.videoKeyInput[account] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .onSubmit { m.connectVideo(account) }
                    Button(m.videoKeyState[account] == .verifying ? "Checking…" : "Connect") { m.connectVideo(account) }
                        .disabled((m.videoKeyInput[account] ?? "").isEmpty || m.videoKeyState[account] == .verifying)
                }.controlSize(.small)
                if case .invalid(let msg) = m.videoKeyState[account] ?? .none {
                    Text(msg).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 11)
    }
}
