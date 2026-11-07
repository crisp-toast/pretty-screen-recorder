import AppKit

/// "Move to Applications": when Pretty Studio is launched from its disk image, Downloads, or a
/// translocated quarantine copy, offer to install it properly — then relaunch from there.
@MainActor
enum Installer {
    static let declinedKey = "moveToApplicationsDeclined"

    static var needsMove: Bool {
        let url = Bundle.main.bundleURL
        let path = url.path
        let home = NSHomeDirectory()
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return false }
        if UserDefaults.standard.bool(forKey: declinedKey) { return false }
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        let translocated = path.contains("/AppTranslocation/")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first.map { path.hasPrefix($0.path) } ?? false
        return readOnly || translocated || downloads
    }

    /// Returns true when the app is relaunching from /Applications (the caller should stop launching).
    static func offerMoveIfNeeded() -> Bool {
        guard needsMove else { return false }
        let a = NSAlert()
        a.messageText = "Move to Applications?"
        a.informativeText = "Pretty Studio works best from your Applications folder. Your projects, music and settings stay where they are."
        a.icon = NSApp.applicationIconImage
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not Now")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        let r = a.runModal()
        if a.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: declinedKey) }
        guard r == .alertFirstButtonReturn else { return false }
        do {
            let dst = try install()
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: dst, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return true
        } catch {
            let e = NSAlert()
            e.messageText = "Couldn't move Pretty Studio"
            e.informativeText = "\(error.localizedDescription)\n\nDrag Pretty Studio into the Applications folder in Finder instead."
            e.runModal()
            return false
        }
    }

    static func install() throws -> URL {
        let src = Bundle.main.bundleURL
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: "/Applications")
        if !fm.isWritableFile(atPath: dir.path) {
            dir = URL(fileURLWithPath: NSHomeDirectory() + "/Applications")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dst.path) {
            // Replace the old copy (to the Trash, so nothing is lost).
            try fm.trashItem(at: dst, resultingItemURL: nil)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [src.path, dst.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "Pretty Studio", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "copy failed"]) }
        // Clear quarantine on the copy we made from our own (already opened) bundle.
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", dst.path]
        try? x.run(); x.waitUntilExit()
        return dst
    }
}
