import AppKit
import ApplicationServices
import IslandCore
import OSLog
import SQLite3

private let noticeLog = Logger(subsystem: "com.fellipe.liquidnotch", category: "notices")

/// macOS's own notification list (11-07, docs/superpowers/specs/2026-11-07-notifications-design.md): usernoted's
/// database, readable with Full Disk Access. Each record has its app, the plist of the request (title `titl`, subtitle
/// `subt`, body `body`, thread `thre`), the interruption level (`intl`) and when it was delivered. The list is read off
/// the main thread and watched through the database's write-ahead log, so an arrival lands at once. Nothing a
/// notification says is ever logged.
final class NotificationStore: @unchecked Sendable {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2")
    static var database: URL { folder.appendingPathComponent("db") }
    /// The most it keeps (macOS holds a few hundred at most).
    static let limit = 200
    /// Setup's "Notifications in the notch" switch (on unless turned off), and the note it posts when it changes.
    static let enabledKey = "noticesOn"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }   // opt-in (11-11)
    static let toggled = Notification.Name("LiquidNotchNoticesToggled")

    /// The database can be read (Full Disk Access).
    static var readable: Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        return sqlite3_exec(db, "select 1 from record limit 1", nil, nil, nil) == SQLITE_OK
    }

    /// Main thread: everything macOS holds now (newest first) and the ones that arrived since the last read.
    var onChange: (@MainActor (_ all: [Notice], _ arrived: [Notice]) -> Void)?

    private let queue = DispatchQueue(label: "com.fellipe.liquidnotch.notices", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var poll: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var lastRec: Int64 = -1
    private var running = false

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            reload()
            watch()
            // A safety net: a write the log watch missed (it's re-armed when the log is replaced) shows within 20 s.
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(5))
            t.setEventHandler { [weak self] in self?.reload() }
            t.resume()
            poll = t
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            sources.forEach { $0.cancel() }; sources = []
            poll?.cancel(); poll = nil
            lastRec = -1
        }
    }

    /// The folder (a new log file) and the log itself (writes); both re-arm when the log is replaced.
    private func watch() {
        sources.forEach { $0.cancel() }; sources = []
        for path in [Self.folder.path, Self.folder.appendingPathComponent("db-wal").path] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
            s.setEventHandler { [weak self] in
                guard let self else { return }
                if s.data.contains(.delete) || s.data.contains(.rename) { watch() }
                soon()
            }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
    }

    private func soon() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        pending = w
        queue.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func reload() {
        guard running, let rows = Self.read() else { return }
        let first = lastRec < 0
        let arrived = first ? [] : rows.filter { $0.rec > lastRec }.map(\.notice)
        lastRec = max(lastRec, rows.map(\.rec).max() ?? 0)
        if first {
            // Numbers only: how many, and which interruption levels macOS wrote.
            let levels = Dictionary(grouping: rows, by: { $0.notice.level.rawValue }).mapValues(\.count)
            noticeLog.notice("notices: \(rows.count, privacy: .public) records from \(Set(rows.map(\.notice.app)).count, privacy: .public) apps, levels \(levels.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "), privacy: .public)")
        } else if !arrived.isEmpty {
            noticeLog.notice("notices: \(arrived.count, privacy: .public) arrived")
        }
        let all = rows.map(\.notice)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?(all, arrived) }
        }
    }

    // MARK: Reading

    struct Row { let rec: Int64; let notice: Notice }

    /// Apps the notch already shows on its own: Claude's and Codex's sessions are its balls, so their notifications would
    /// say it twice (11-07: 32 of the 36 records here, and macOS's own panel listed none of them).
    static let shownElsewhere: Set<String> = [Agents.app(.claude), Agents.app(.codex)]
    /// What the center keeps from before: the last week (the database also holds months-old ones the panel no longer shows).
    static let maxAge: TimeInterval = 7 * 24 * 3600

    /// Every record, newest first (nil: not readable), less ours, the apps the notch shows elsewhere and those older
    /// than a week.
    static func read(at url: URL = database, limit: Int = limit, skip: Set<String> = shownElsewhere, now: Date = Date()) -> [Row]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        let sql = """
            select r.rec_id, hex(r.uuid), a.identifier, r.data, r.delivered_date
            from record r join app a on a.app_id = r.app_id
            order by r.delivered_date desc, r.rec_id desc limit ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rec = sqlite3_column_int64(stmt, 0)
            let uuid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "rec\(rec)"
            let ident = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            guard let bytes = sqlite3_column_blob(stmt, 3) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 3)))
            let delivered = sqlite3_column_double(stmt, 4)
            guard let n = decode(data, id: uuid, identifier: ident, delivered: delivered) else { continue }
            if n.app == Bundle.main.bundleIdentifier || skip.contains(n.app) { continue }   // never our own
            if now.timeIntervalSince(n.date) > maxAge { continue }
            out.append(Row(rec: rec, notice: n))
        }
        return out
    }

    /// One record's plist. Its own `app` wins over the table's identifier (system ones carry a prefix there).
    static func decode(_ data: Data, id: String, identifier: String, delivered: Double) -> Notice? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let req = plist["req"] as? [String: Any] ?? [:]
        let raw = (plist["app"] as? String) ?? identifier
        let app = raw.components(separatedBy: ":").last ?? raw
        let level = (plist["intl"] as? NSNumber).flatMap { NoticeLevel(rawValue: $0.intValue) } ?? .active
        let date = delivered > 0 ? Date(timeIntervalSinceReferenceDate: delivered)
                                 : (plist["date"] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } ?? Date()
        return Notice(id: id, app: app, appName: AppNames.name(for: app),
                      title: req["titl"] as? String, subtitle: req["subt"] as? String, body: req["body"] as? String,
                      thread: req["thre"] as? String, date: date, level: level)
    }
}

/// An app's name and icon by bundle ID, looked up once.
enum AppNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String: String] = [:]

    static func name(for bundleID: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let n = names[bundleID] { return n }
        var n = bundleID.components(separatedBy: ".").last ?? bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            n = FileManager.default.displayName(atPath: url.path)
            if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        }
        names[bundleID] = n
        return n
    }
}

@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]

    /// The app's own icon (nil: no app with that ID here).
    static func icon(for bundleID: String) -> NSImage? {
        if let i = icons[bundleID] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = i
        return i
    }
}

/// Opens a notification where it points (11-07, tried live with the owner's go): the item in macOS's own panel is pressed
/// over Accessibility, which is a click on it (the thread, the email); it's found by the record's UUID, the panel's
/// identifier without dashes. A banner on screen is pressed in place; otherwise the clock in the menu bar
/// (`MenuBarAgent`'s `com.apple.menuextra.clock`) opens the panel for a moment (~0.25 s to find it), and macOS closes it
/// once the notification opens. Not in the panel (a closed stack there, or one macOS no longer lists): the panel closes
/// and the app comes forward.
enum NoticeOpener {
    private static let queue = DispatchQueue(label: "com.fellipe.liquidnotch.notice-open", qos: .userInitiated)

    @MainActor static func open(_ n: Notice) {
        let app = n.app, id = n.id.replacingOccurrences(of: "-", with: "").uppercased()
        queue.async {
            let t0 = Date()
            let pressed = AXIsProcessTrusted() && pressInPanel(id)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            noticeLog.notice("notices: open \(pressed ? "pressed in the panel" : "not in the panel, the app comes forward", privacy: .public) (\(ms, privacy: .public) ms)")
            guard !pressed else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { openApp(app) } }
        }
    }

    @MainActor private static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private static func pressInPanel(_ id: String) -> Bool {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return false }
        let root = AXUIElementCreateApplication(nc.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        if let e = find(id, in: root) { return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }
        guard let clock = clock() else { return false }
        _ = AXUIElementPerformAction(clock, kAXPressAction as CFString)
        for _ in 0..<24 {   // up to 1.2 s for the panel to fill
            Thread.sleep(forTimeInterval: 0.05)
            if let e = find(id, in: root) { return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }
        }
        _ = AXUIElementPerformAction(clock, kAXPressAction as CFString)   // not there: the panel goes away again
        return false
    }

    private static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }

    private static func find(_ id: String, in root: AXUIElement) -> AXUIElement? {
        var stack = [root], seen = 0
        while let e = stack.popLast(), seen < 800 {
            seen += 1
            if let i = attr(e, kAXIdentifierAttribute as String) as? String, i.count >= 32,
               i.replacingOccurrences(of: "-", with: "").uppercased() == id { return e }
            stack.append(contentsOf: children(e))
        }
        return nil
    }

    private static func clock() -> AXUIElement? {
        guard let bar = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        var stack = [AXUIElementCreateApplication(bar.processIdentifier)], seen = 0
        while let e = stack.popLast(), seen < 400 {
            seen += 1
            if attr(e, kAXIdentifierAttribute as String) as? String == "com.apple.menuextra.clock" { return e }
            stack.append(contentsOf: children(e))
        }
        return nil
    }
}
