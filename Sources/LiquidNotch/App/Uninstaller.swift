import AppKit
import OSLog
import ServiceManagement

/// Uninstall Liquid Notch… in the island's menu (11-11): takes back everything the app set up, then moves itself to the
/// Trash and quits. Your wallpaper goes back first (its backup lives in the support folder that goes next); the
/// Claude and Codex hooks come out of their files (the backups made when they went in stay: they're copies of your
/// own files); the login item and the privacy permissions go (where macOS lets an app reset its own); then the
/// support files, caches and settings.
enum Uninstaller {
    static let bundleID = "com.fellipe.liquidnotch"
    private static let log = Logger(subsystem: bundleID, category: "install")

    /// The app's own files in the Library, all named after it. Nothing outside these, ever.
    static func leftovers(home: URL) -> [URL] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return [
            "Application Support/Liquid Notch",
            "Caches/\(bundleID)",
            "HTTPStorages/\(bundleID)",
            "HTTPStorages/\(bundleID).binarycookies",
            "Saved Application State/\(bundleID).savedState",
            "WebKit/\(bundleID)",
            "Preferences/\(bundleID).plist",
        ].map { library.appendingPathComponent($0) }
    }

    @MainActor
    static func confirmAndRun() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Uninstall Liquid Notch?"
        alert.informativeText = "This removes its settings and files, its Claude and Codex hooks, its login item and its privacy permissions, puts your wallpaper back, and moves Liquid Notch to the Trash."
        alert.addButton(withTitle: "Cancel")
        let uninstall = alert.addButton(withTitle: "Uninstall")
        uninstall.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        run()
    }

    @MainActor
    private static func run() {
        LockWallpaper.shared.restoreOnQuit()
        try? HookInstaller.uninstall()
        try? SMAppService.mainApp.unregister()
        let tcc = Process()
        tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tcc.arguments = ["reset", "All", bundleID]
        try? tcc.run()
        tcc.waitUntilExit()
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        for url in leftovers(home: FileManager.default.homeDirectoryForCurrentUser) {
            try? FileManager.default.removeItem(at: url)
        }
        let app = Bundle.main.bundleURL
        do {
            try FileManager.default.trashItem(at: app, resultingItemURL: nil)
            log.notice("uninstalled; \(app.path, privacy: .public) is in the Trash")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Liquid Notch couldn't move itself to the Trash"
            alert.informativeText = "Everything else is gone. Drag Liquid Notch from your Applications folder to the Trash to finish."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        // Straight out: quitting normally would write settings back (the adapter stops when its pipe closes).
        exit(0)
    }
}
