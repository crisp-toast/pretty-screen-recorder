import SwiftUI
import AppKit
import PrettyCore

/// First-run setup: welcome → essentials → voice → music → agents → done.
struct OnboardingView: View {
    @ObservedObject var m: SetupModel
    var finish: (_ openProject: Bool) -> Void

    enum Step: Int, CaseIterable { case welcome, essentials, voice, music, video, agents, done }
    @State private var step: Step = OnboardingView.initialStep
    @State private var forward = true

    /// `--onboarding-step N` opens a given step (for reviewing the flow).
    static var initialStep: Step {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--onboarding-step"), i + 1 < args.count, let n = Int(args[i + 1]), let s = Step(rawValue: n) { return s }
        return .welcome
    }

    var body: some View {
        ZStack {
            VisualEffect(material: .underWindowBackground).ignoresSafeArea()
            Color(red: 0.05, green: 0.05, blue: 0.08).opacity(0.62).ignoresSafeArea()
            AmbientGlow().offset(y: -40)
            VStack(spacing: 0) {
                ZStack {
                    page(step)
                        .id(step)
                        .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
            if let t = m.toast {
                VStack { Spacer(); Text(t).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThickMaterial)).padding(.bottom, 74) }
                    .transition(.opacity)
                    .task(id: t) { try? await Task.sleep(nanoseconds: 2_600_000_000); withAnimation { m.toast = nil } }
            }
        }
        .frame(width: 780, height: 640)
        .preferredColorScheme(.dark)
    }

    func go(_ s: Step) {
        forward = s.rawValue > step.rawValue
        m.stopPlayback()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { step = s }
    }

    @ViewBuilder func page(_ s: Step) -> some View {
        switch s {
        case .welcome: WelcomePage()
        case .essentials:
            scroll {
                StepHeader(symbol: "checklist", tint: .green, title: "The essentials",
                           subtitle: "Pretty Studio uses a few tools that live on your Mac. Here's where things stand.")
                EssentialsPane(m: m)
                Button { m.runChecks() } label: { Label(m.checking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        case .voice:
            scroll {
                StepHeader(symbol: "waveform", tint: Brand.violet, title: "Choose a narrator",
                           subtitle: "Narration is studio-grade or not at all. Without a voice, your product's own words become beat-synced type.")
                VoicePane(m: m)
            }
        case .music:
            scroll {
                StepHeader(symbol: "music.note", tint: .orange, title: "Music that moves",
                           subtitle: "An original score composed to each edit, sound design, and your licensed library — all cleared and credited.")
                MusicPane(m: m)
            }
        case .video:
            scroll {
                StepHeader(symbol: "cube.transparent.fill", tint: .pink, title: "Depth and emotion",
                           subtitle: "Real 3D device shots of your app, and cinematic AI B-roll for the human moments — your UI always stays real.")
                VideoPane(m: m)
            }
        case .agents:
            scroll {
                StepHeader(symbol: "terminal.fill", tint: .gray, title: "Let your agents in",
                           subtitle: "Claude Code and Codex can record, direct, narrate and render with the same polish — from the command line.")
                AgentsPane(m: m)
            }
        case .done: DonePage(m: m)
        }
    }

    func scroll<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) { c() }.padding(.horizontal, 48).padding(.top, 44).padding(.bottom, 20)
        }
    }

    var footer: some View {
        ZStack {
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s == step ? Color.white : Color.white.opacity(0.22))
                        .frame(width: s == step ? 18 : 7, height: 7)
                        .animation(.spring(response: 0.4), value: step)
                }
            }
            HStack(spacing: 10) {
                if step != .welcome && step != .done {
                    Button("Back") { go(Step(rawValue: step.rawValue - 1)!) }.controlSize(.large)
                }
                Spacer()
                switch step {
                case .welcome:
                    Button { go(.essentials) } label: { Text("Get Started").frame(minWidth: 110) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                case .done:
                    Button { m.finish(); finish(false) } label: { Text("Start Creating").frame(minWidth: 110) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                default:
                    if step == .voice && m.provider != "none" && m.settings.voice.voiceId == nil {
                        Button("Skip for Now") { m.provider = "none"; go(.music) }.controlSize(.large)
                    }
                    Button { go(Step(rawValue: step.rawValue + 1)!) } label: { Text("Continue").frame(minWidth: 110) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

struct WelcomePage: View {
    @State private var appear = false
    let features: [(String, Color, String, String)] = [
        ("scope", .pink, "Directed, not recorded", "Every click has a reason and lands on the word — or the beat — that calls for it."),
        ("cube.transparent", Brand.violet, "Depth, not screenshots", "Your app on a real 3D phone, kinetic type, and cinematic B-roll — tailored to this product."),
        ("music.note", .orange, "Scored, not stocked", "An original score that follows your edit, with sound design — licensed and credited."),
        ("terminal.fill", .gray, "Built for agents", "Claude Code and Codex drive it end to end with the same polish."),
    ]
    var body: some View {
        VStack(spacing: 26) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 112, height: 112)
                .shadow(color: Brand.violet.opacity(0.5), radius: 26, y: 10)
                .scaleEffect(appear ? 1 : 0.86).opacity(appear ? 1 : 0)
            VStack(spacing: 8) {
                Text("Welcome to Pretty Studio").font(.system(size: 34, weight: .bold))
                Text("Product videos that feel made for your product — by you or your agents.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .opacity(appear ? 1 : 0).offset(y: appear ? 0 : 10)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(features.enumerated()), id: \.offset) { i, f in
                    HStack(spacing: 16) {
                        Image(systemName: f.0).font(.system(size: 22, weight: .semibold)).foregroundStyle(f.1).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.2).font(.system(size: 14, weight: .semibold))
                            Text(f.3).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                    }
                    .opacity(appear ? 1 : 0).offset(y: appear ? 0 : 12)
                    .animation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.25 + Double(i) * 0.08), value: appear)
                }
            }
            .frame(maxWidth: 540)
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { appear = true } }
    }
}

struct DonePage: View {
    @ObservedObject var m: SetupModel
    @State private var appear = false
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Color.green.opacity(0.18)).frame(width: 120, height: 120).scaleEffect(appear ? 1 : 0.5)
                Image(systemName: "checkmark").font(.system(size: 50, weight: .bold)).foregroundStyle(.green)
                    .scaleEffect(appear ? 1 : 0.3).opacity(appear ? 1 : 0)
            }
            VStack(spacing: 8) {
                Text("You're all set").font(.system(size: 34, weight: .bold))
                Text("Change any of this later in Settings (⌘,).").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                summary("waveform", "Narration", voiceSummary)
                summary("music.note", "Music", musicSummary)
                summary("cube.transparent", "Video & 3D", [m.blenderPath != nil ? "3D shots" : nil, VideoAI.available().isEmpty ? nil : "AI B-roll (" + VideoAI.available().joined(separator: ", ") + ")"].compactMap { $0 }.joined(separator: " · ").ifEmpty("Not set up"))
                summary("terminal.fill", "Agents", m.cliInstalled != nil ? "`pretty` is installed" : "Command-line tool not installed")
            }
            .frame(maxWidth: 440)
            .opacity(appear ? 1 : 0).offset(y: appear ? 0 : 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.65).delay(0.1)) { appear = true } }
    }
    var voiceSummary: String {
        let v = m.settings.voice
        if v.provider == "none" || v.voiceId == nil { return "Off — on-screen type tells the story" }
        return "\(v.voiceName ?? "Voice") · \(v.provider == "openai" ? "OpenAI" : "ElevenLabs")"
    }
    var musicSummary: String {
        var parts: [String] = []
        if m.settings.music.useComposed { parts.append("composed scores") }
        if m.settings.music.useSfx { parts.append("sound design") }
        if m.settings.music.useIncompetech { parts.append("classic catalog") }
        if m.licensedCount > 0 { parts.append("\(m.licensedCount) licensed tracks") }
        if m.settings.music.useGenerated { parts.append("generated fallback") }
        return parts.isEmpty ? "No music sources" : parts.joined(separator: " + ")
    }
    func summary(_ s: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s).frame(width: 22).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(value).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// Settings (⌘,): the same panes as onboarding.
struct SettingsView: View {
    @ObservedObject var m: SetupModel
    var reopenOnboarding: () -> Void
    var body: some View {
        TabView {
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                EssentialsPane(m: m)
                HStack {
                    Button("Check Again") { m.runChecks() }
                    Spacer()
                    Button("Show Welcome Tour…") { reopenOnboarding() }
                }.controlSize(.small)
            }.padding(24) }
            .tabItem { Label("General", systemImage: "gearshape") }
            ScrollView { VoicePane(m: m, compact: true).padding(24) }
                .tabItem { Label("Voice", systemImage: "waveform") }
            ScrollView { MusicPane(m: m).padding(24) }
                .tabItem { Label("Music", systemImage: "music.note") }
            ScrollView { VideoPane(m: m).padding(24) }
                .tabItem { Label("Video & 3D", systemImage: "cube.transparent") }
            ScrollView { AgentsPane(m: m).padding(24) }
                .tabItem { Label("Agents", systemImage: "terminal") }
        }
        .frame(width: 720, height: 560)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let t = m.toast {
                Text(t).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThickMaterial)).padding(.bottom, 16)
                    .task(id: t) { try? await Task.sleep(nanoseconds: 2_600_000_000); m.toast = nil }
            }
        }
    }
}


extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
