import SwiftUI
import AppKit
import PrettyCore

struct RecentProject: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let modified: Date
    let project: String
}

struct WelcomeView: View {
    let open: (URL) -> Void
    let openPanel: () -> Void
    let importVideo: () -> Void
    @State private var recents: [RecentProject] = []

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [Color(red: 0.43, green: 0.36, blue: 1), Color(red: 0.0, green: 0.76, blue: 1), Color(red: 1, green: 0.37, blue: 0.64)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "cursorarrow.rays").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white))
                Text("Pretty Studio").font(.system(size: 26, weight: .bold))
                Text("Polish screen recordings into product videos.\nAgents drive it with the `pretty` CLI; you can fine-tune here.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                Button { openPanel() } label: { Label("Open Project…", systemImage: "folder").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { importVideo() } label: { Label("New from Video…", systemImage: "film").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            .padding(28)
            .frame(width: 300)
            .background(Color(white: 0.13))
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent projects").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(16)
                if recents.isEmpty {
                    Text("No projects on Master Storage yet.\nRecord one: pretty record web storyboard.json")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(16)
                    Spacer()
                } else {
                    List(recents) { r in
                        Button { open(r.url) } label: {
                            HStack {
                                Image(systemName: "film.stack").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).font(.system(size: 13, weight: .medium))
                                    Text("\(r.project) · \(r.modified.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(white: 0.1))
        }
        .preferredColorScheme(.dark)
        .task { recents = Self.scan() }
    }

    static func scan() -> [RecentProject] {
        var out: [RecentProject] = []
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/Volumes/Master Storage/Projects")
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        for p in projects {
            for sub in ["video", "exports", "marketing"] {
                let dir = p.appendingPathComponent(sub)
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for i in items where i.pathExtension == ProjectIO.bundleExtension {
                    let pj = i.appendingPathComponent("project.json")
                    let mod = (try? pj.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let name = (try? ProjectIO.load(i).name) ?? i.deletingPathExtension().lastPathComponent
                    out.append(RecentProject(url: i, name: name, modified: mod, project: p.lastPathComponent))
                }
            }
        }
        for u in NSDocumentController.shared.recentDocumentURLs where u.pathExtension == ProjectIO.bundleExtension && !out.contains(where: { $0.url == u }) {
            if let p = try? ProjectIO.load(u) {
                out.append(RecentProject(url: u, name: p.name, modified: .distantPast, project: u.deletingLastPathComponent().lastPathComponent))
            }
        }
        return out.sorted { $0.modified > $1.modified }.prefix(40).map { $0 }
    }
}
