import AppKit
import SwiftUI
import PrettyCore

/// Pretty Studio editor: AppKit-managed windows hosting SwiftUI editors, one per project.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var editors: [URL: (NSWindow, EditorModel)] = [:]
    var welcome: NSWindow?
    var openedAtLaunch = false
    var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Projects passed on the command line (pretty open / direct launch).
        for arg in CommandLine.arguments.dropFirst() where arg.hasSuffix(".prettystudio") || arg.hasSuffix("project.json") {
            open(URL(fileURLWithPath: arg))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            if editors.isEmpty { showWelcome() }
        }
        installKeys()
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { open(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func open(_ url: URL) {
        let bundle = Studio.locate(url).base.standardizedFileURL
        if let (w, _) = editors[bundle] { w.makeKeyAndOrderFront(nil); return }
        do {
            let model = try EditorModel(bundleURL: bundle)
            let host = NSHostingController(rootView: EditorView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = model.name
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.setContentSize(NSSize(width: 1440, height: 900))
            w.minSize = NSSize(width: 1100, height: 700)
            w.center()
            w.setFrameAutosaveName("PrettyStudioEditor")
            w.isReleasedWhenClosed = false
            w.makeKeyAndOrderFront(nil)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    model.saveNow(); model.player.pause()
                    self?.editors[bundle] = nil
                }
            }
            editors[bundle] = (w, model)
            welcome?.close(); welcome = nil
            NSDocumentController.shared.noteNewRecentDocumentURL(bundle)
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't open project"; a.informativeText = "\(error)"; a.runModal()
        }
    }

    func showWelcome() {
        if let w = welcome { w.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: WelcomeView(open: { [weak self] u in self?.open(u) }, openPanel: { [weak self] in self?.openPanel() },
                                                             importVideo: { [weak self] in self?.importVideo() }))
        let w = NSWindow(contentViewController: host)
        w.title = "Pretty Studio"
        w.setContentSize(NSSize(width: 760, height: 520))
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        welcome = w
    }

    @objc func openPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.treatsFilePackagesAsDirectories = false
        p.message = "Choose a .prettystudio project"
        if p.runModal() == .OK { p.urls.forEach(open) }
    }

    @objc func importVideo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        p.message = "Choose a screen recording to polish"
        guard p.runModal() == .OK, let v = p.url else { return }
        var o = ProjectIO.NewOptions()
        o.video = v
        let b = v.deletingPathExtension().appendingPathExtension(ProjectIO.bundleExtension)
        do { open(try ProjectIO.create(at: b, o)) } catch {
            let a = NSAlert(); a.messageText = "Import failed"; a.informativeText = "\(error)"; a.runModal()
        }
    }

    @objc func exportFront() {
        if let m = frontModel() { NotificationCenter.default.post(name: .prettyExport, object: m) }
    }

    func frontModel() -> EditorModel? {
        guard let key = NSApp.keyWindow else { return nil }
        return editors.values.first { $0.0 === key }?.1
    }

    /// Editor shortcuts: Space play/pause, ←/→ frame step, B blade, ⌘B split, Delete removes selection.
    func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let m = self.frontModel() else { return e }
            if let r = NSApp.keyWindow?.firstResponder, r is NSTextView { return e } // typing in a field
            let cmd = e.modifierFlags.contains(.command)
            switch (e.keyCode, cmd) {
            case (49, false): m.togglePlay(); return nil
            case (123, false): m.step(e.modifierFlags.contains(.shift) ? -60 : -1); return nil
            case (124, false): m.step(e.modifierFlags.contains(.shift) ? 60 : 1); return nil
            case (11, false): m.bladeMode.toggle(); return nil
            case (11, true): m.splitAtPlayhead(); return nil
            case (51, false), (117, false): m.deleteSelected(); return nil
            case (53, false): m.bladeMode = false; m.selectedZoom = nil; m.selectedPiece = nil; m.manualFocusPick = false; return nil
            default: return e
            }
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pretty Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Pretty Studio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Pretty Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open Project…", action: #selector(openPanel), keyEquivalent: "o")
        file.addItem(withTitle: "New from Video…", action: #selector(importVideo), keyEquivalent: "n")
        file.addItem(withTitle: "Export…", action: #selector(exportFront), keyEquivalent: "e")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
