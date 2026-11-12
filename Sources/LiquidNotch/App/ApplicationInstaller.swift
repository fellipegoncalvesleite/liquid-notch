import AppKit
import OSLog

/// Liquid Notch lives in Applications (11-11, owner: "make it a proper app, has to be put in Applications"). A public
/// build opened from anywhere else (Downloads, the Desktop) asks once, moves itself there with no copy left behind and
/// opens again from there. `/Applications` when it can write there (an administrator account), else the user's own
/// `~/Applications`. Your own builds never ask: build_app.sh marks only public release builds (`LNMovesToApplications`).
enum ApplicationInstaller {
    enum Plan: Equatable {
        case stay
        case move(from: URL, to: URL)
    }

    static let appName = "Liquid Notch.app"
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "install")

    /// Where the app should be. `original` is where a translocated app really is (macOS runs a downloaded app from a
    /// random read-only copy until it's moved; the move must take the real one).
    static func plan(bundle: URL, original: URL?, home: URL, systemApplicationsWritable: Bool) -> Plan {
        let source = (original ?? bundle).standardizedFileURL
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let user = home.appendingPathComponent("Applications", isDirectory: true)
        if isInside(source, system) || isInside(source, user) { return .stay }
        let folder = systemApplicationsWritable ? system : user
        return .move(from: source, to: folder.appendingPathComponent(appName, isDirectory: true))
    }

    static func isInside(_ app: URL, _ folder: URL) -> Bool {
        let a = app.resolvingSymlinksInPath().standardizedFileURL.path
        let f = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return a.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    /// Asks and moves when it has to. True when the app is leaving (moved and reopening, or quit); false to start here.
    @MainActor
    static func moveIfNeeded(arguments: [String]) -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "LNMovesToApplications") as? Bool == true,
              !arguments.contains("--no-move") else { return false }
        let bundle = Bundle.main.bundleURL
        let plan = plan(bundle: bundle, original: translocatedOriginal(of: bundle),
                        home: FileManager.default.homeDirectoryForCurrentUser,
                        systemApplicationsWritable: FileManager.default.isWritableFile(atPath: "/Applications"))
        guard case .move(let from, let to) = plan else { return false }

        NSApp.activate()
        let ask = NSAlert()
        ask.messageText = "Move Liquid Notch to Applications?"
        ask.informativeText = "Liquid Notch runs from your Applications folder. It moves itself there, with no copy left behind, and opens again."
        ask.addButton(withTitle: "Move to Applications")
        ask.addButton(withTitle: "Quit")
        guard ask.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return true
        }
        do {
            try move(from: from, to: to)
        } catch {
            log.error("move to \(to.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            fail(error.localizedDescription)
            return true
        }
        log.notice("moved to \(to.path, privacy: .public)")
        reopen(to, arguments: Array(arguments.dropFirst()))
        return true
    }

    /// An older copy already there goes to the Trash first; the move falls back to a copy when the source can't be
    /// moved (a read-only disk). The quarantine flag comes off the moved app, which you already chose to open.
    private static func move(from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: to.path) { try fm.trashItem(at: to, resultingItemURL: nil) }
        do { try fm.moveItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", to.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    @MainActor
    private static func reopen(_ app: URL, arguments: [String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { opened, error in
            Task { @MainActor in
                if opened == nil { fail(error?.localizedDescription ?? "It couldn't open from Applications.") } else { NSApp.terminate(nil) }
            }
        }
    }

    @MainActor
    private static func fail(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't move Liquid Notch to Applications"
        alert.informativeText = "\(reason) Drag Liquid Notch into your Applications folder yourself, then open it from there."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Where a translocated app really is (Security's SecTranslocate functions, looked up at runtime as every
    /// move-to-Applications helper does); nil when it isn't translocated.
    private static func translocatedOriginal(of url: URL) -> URL? {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let isSym = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSym = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        var translocated: DarwinBoolean = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil).boolValue, translocated.boolValue,
              let original = unsafeBitCast(originalSym, to: Original.self)(url as CFURL, nil) else { return nil }
        return original.takeRetainedValue() as URL
    }
}
