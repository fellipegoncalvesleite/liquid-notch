import AppKit
import ApplicationServices
import CoreBluetooth
import EventKit
import IOBluetooth
import OSLog
import SQLite3

/// `--spike`: tries each P4 data source once and logs what works (subsystem com.fellipe.liquidnotch,
/// category spike). Numbers and yes/no only: never message text, names or calendar titles.
@MainActor
enum Spikes {
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "spike")

    static func run() {
        notifications()
        messages()
        accessibility()
        calendar()
        bluetooth()
        hudTap()
    }

    /// The notification database (usernoted's, Full Disk Access): tables, the record columns, counts, and the key
    /// names and value types inside the newest record's plist. Never a title, body or app name.
    private static func notifications() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        log.notice("notifications: folder readable \(!files.isEmpty, privacy: .public), files \(files.sorted().joined(separator: " "), privacy: .public)")
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dir.appendingPathComponent("db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            log.notice("notifications: open failed"); return
        }
        func query(_ sql: String, _ row: (OpaquePointer) -> Void) -> Bool {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
                log.notice("notifications: '\(sql, privacy: .public)' failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                return false
            }
            defer { sqlite3_finalize(st) }
            while sqlite3_step(st) == SQLITE_ROW { row(st) }
            return true
        }
        func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "nil" }
        var tables: [String] = []
        guard query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", { tables.append(text($0, 0)) }) else { return }
        log.notice("notifications: tables \(tables.joined(separator: " "), privacy: .public)")
        for table in ["record", "app"] where tables.contains(table) {
            var columns: [String] = []
            _ = query("PRAGMA table_info(\(table))") { columns.append("\(text($0, 1)):\(text($0, 2))") }
            var count = 0
            _ = query("SELECT COUNT(*) FROM \(table)") { count = Int(sqlite3_column_int64($0, 0)) }
            log.notice("notifications: \(table, privacy: .public) \(count, privacy: .public) rows, columns \(columns.joined(separator: " "), privacy: .public)")
        }
        guard tables.contains("record") else { return }
        // Which records macOS's panel still shows (11-07: the panel listed one while the table held 35).
        for table in ["delivered", "displayed", "requests"] where tables.contains(table) {
            var columns: [String] = []
            _ = query("PRAGMA table_info(\(table))") { columns.append("\(text($0, 1)):\(text($0, 2))") }
            var count = 0
            _ = query("SELECT COUNT(*) FROM \(table)") { count = Int(sqlite3_column_int64($0, 0)) }
            log.notice("notifications: \(table, privacy: .public) \(count, privacy: .public) rows, columns \(columns.joined(separator: " "), privacy: .public)")
        }
        // What a `delivered` / `displayed` list holds: its plist's shape, and how many records it names (numbers only).
        var recIDs = Set<Int64>()
        _ = query("SELECT rec_id FROM record") { recIDs.insert(sqlite3_column_int64($0, 0)) }
        for table in ["delivered", "displayed"] where tables.contains(table) {
            var shapes: [String: Int] = [:], named = Set<Int64>(), entries = 0
            _ = query("SELECT list FROM \(table)") { st in
                guard let bytes = sqlite3_column_blob(st, 0) else { shapes["null", default: 0] += 1; return }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(st, 0)))
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                    shapes["bytes\(data.count)", default: 0] += 1; return
                }
                if let a = plist as? [Any] {
                    shapes["array of " + Set(a.map { String(describing: type(of: $0)) }).sorted().joined(separator: "/"), default: 0] += 1
                    entries += a.count
                    for v in a { if let n = v as? NSNumber, recIDs.contains(n.int64Value) { named.insert(n.int64Value) } }
                } else { shapes[String(describing: type(of: plist)), default: 0] += 1 }
            }
            log.notice("notifications: \(table, privacy: .public) lists \(shapes.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", "), privacy: .public); \(entries, privacy: .public) entries, \(named.count, privacy: .public) of \(recIDs.count, privacy: .public) records named; test named \(named.contains(3580), privacy: .public)")
        }
        // Per app (bundle IDs and counts only): records, delivered UUIDs, the newest's age and style.
        _ = query("""
            SELECT a.identifier, COUNT(r.rec_id), length(d.list) / 16, MAX(r.delivered_date), MIN(r.style), MAX(r.style), SUM(r.presented)
            FROM app a JOIN record r ON r.app_id = a.app_id LEFT JOIN delivered d ON d.app_id = a.app_id GROUP BY a.app_id
            """) { st in
            let age = Int(Date().timeIntervalSinceReferenceDate - sqlite3_column_double(st, 3))
            log.notice("notifications: app \(text(st, 0), privacy: .public) records \(sqlite3_column_int(st, 1), privacy: .public) delivered \(sqlite3_column_int(st, 2), privacy: .public) newest \(age / 3600, privacy: .public) h ago style \(sqlite3_column_int(st, 4), privacy: .public)-\(sqlite3_column_int(st, 5), privacy: .public) presented \(sqlite3_column_int(st, 6), privacy: .public)")
        }
        // Where macOS 27 keeps each app's notification settings (ncprefs moved out of ~/Library/Preferences): file names,
        // and for a plist with an `apps` array, the flags of the apps that have records (bundle IDs and numbers only).
        var withRecords = Set<String>()
        _ = query("SELECT DISTINCT a.identifier FROM app a JOIN record r ON r.app_id = a.app_id") { withRecords.insert(text($0, 0).lowercased()) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for group in ["group.com.apple.usernoted", "group.com.apple.UserNotifications"] {
            let root = home.appendingPathComponent("Library/Group Containers/\(group)")
            let found = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { !$0.path.contains("/db2/") }
            log.notice("notifications: \(group, privacy: .public) files \(found.map { $0.path.replacingOccurrences(of: root.path, with: "") }.sorted().prefix(30).joined(separator: " "), privacy: .public)")
            for f in found where f.pathExtension == "plist" {
                guard let d = try? Data(contentsOf: f), let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                      let apps = p["apps"] as? [[String: Any]] else { continue }
                log.notice("notifications: \(f.lastPathComponent, privacy: .public) has \(apps.count, privacy: .public) apps, keys \((apps.first?.keys.sorted() ?? []).joined(separator: " "), privacy: .public)")
                for a in apps {
                    guard let id = a["bundle-id"] as? String, withRecords.contains(id.lowercased()) || id == "com.apple.mail" else { continue }
                    let flags = (a["flags"] as? NSNumber)?.intValue ?? -1
                    log.notice("notifications: prefs \(id, privacy: .public) flags \(flags, privacy: .public) = \(String(flags, radix: 2), privacy: .public)")
                }
            }
        }
        // The owner's test notification only (title "Liquid Notch test", sent 11-07 with their go): its uuid and rec_id.
        _ = query("SELECT rec_id, hex(uuid), data, presented FROM record ORDER BY delivered_date DESC LIMIT 30") { st in
            guard let bytes = sqlite3_column_blob(st, 2),
                  let plist = try? PropertyListSerialization.propertyList(from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(st, 2))), format: nil) as? [String: Any],
                  (plist["req"] as? [String: Any])?["titl"] as? String == "Liquid Notch test" else { return }
            log.notice("notifications: test rec \(sqlite3_column_int64(st, 0), privacy: .public) uuid \(text(st, 1), privacy: .public) presented \(sqlite3_column_int(st, 3), privacy: .public)")
        }
        _ = query("SELECT COUNT(DISTINCT app_id), MAX(delivered_date) FROM record") {
            let newest = sqlite3_column_double($0, 1)
            let age = newest > 0 ? Int(Date().timeIntervalSinceReferenceDate - newest) : -1
            log.notice("notifications: \(sqlite3_column_int64($0, 0), privacy: .public) apps, newest delivered \(age, privacy: .public) s ago")
        }
        // The newest record's plist: key names and value types only.
        _ = query("SELECT data, length(uuid) FROM record ORDER BY delivered_date DESC LIMIT 3") { st in
            guard let bytes = sqlite3_column_blob(st, 0) else { log.notice("notifications: data is null"); return }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(st, 0)))
            func shape(_ v: Any, _ depth: Int) -> String {
                switch v {
                case let d as [String: Any]:
                    guard depth < 3 else { return "{…}" }
                    return "{" + d.keys.sorted().map { "\($0)=\(shape(d[$0]!, depth + 1))" }.joined(separator: " ") + "}"
                case let a as [Any]: return "[\(a.count)]"
                case is String: return "str"
                case is Date: return "date"
                case is Data: return "data"
                case is NSNumber: return "num"
                default: return "?"
                }
            }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                log.notice("notifications: data \(data.count, privacy: .public) bytes, not a plist (first \(data.prefix(8).map { String(format: "%02x", $0) }.joined(), privacy: .public))")
                return
            }
            log.notice("notifications: uuid \(sqlite3_column_int(st, 1), privacy: .public) bytes; data \(shape(plist, 0), privacy: .public)")
        }
    }

    private static func messages() {
        guard MessageStore.readable else { log.notice("messages: chat.db not readable (no Full Disk Access)"); return }
        // What's in the Messages folder and the database (sizes and counts only).
        let dir = MessageStore.url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let listing = files.map { f in "\(f.lastPathComponent)=\((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)" }
        log.notice("messages: folder \(listing.sorted().joined(separator: " "), privacy: .public)")
        log.notice("messages: counts \(MessageStore.counts(), privacy: .public)")
        let t0 = Date()
        guard let rows = MessageStore.latest(200) else { log.notice("messages: query failed"); return }
        let ms = Date().timeIntervalSince(t0) * 1000
        let incoming = rows.filter { !$0.fromMe }
        let decoded = incoming.filter { $0.text != nil }.count
        let age = rows.first.map { Int(Date().timeIntervalSince($0.date)) } ?? -1
        log.notice("messages: read \(rows.count, privacy: .public) rows in \(Int(ms), privacy: .public) ms; incoming \(incoming.count, privacy: .public), text decoded \(decoded, privacy: .public); in groups \(rows.filter { $0.groupName != nil }.count, privacy: .public); newest \(age, privacy: .public) s ago")
    }

    private static func accessibility() {
        guard AXIsProcessTrusted() else { log.notice("accessibility: not trusted"); return }
        let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        guard let pid = nc?.processIdentifier else { log.notice("accessibility: trusted; Notification Center not running"); return }
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        log.notice("accessibility: trusted; Notification Center windows readable \(err == .success, privacy: .public), count \((windows as? [AXUIElement])?.count ?? -1, privacy: .public)")
    }

    private static func calendar() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { log.notice("calendar: status \(status.rawValue, privacy: .public)"); return }
        let store = EKEventStore()
        let start = Date(), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        let links = events.filter { e in
            let text = [e.url?.absoluteString, e.notes, e.location].compactMap { $0 }.joined(separator: " ")
            return text.range(of: #"https://\S*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|facetime\.apple\.com)\S*"#,
                              options: .regularExpression) != nil
        }
        log.notice("calendar: \(events.count, privacy: .public) events in the next 24 h, \(links.count, privacy: .public) with a join link")
    }

    private static func bluetooth() {
        guard CBManager.authorization == .allowedAlways else {
            log.notice("bluetooth: authorization \(CBManager.authorization.rawValue, privacy: .public)"); return
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let pods = paired.filter { ($0.name ?? "").localizedCaseInsensitiveContains("AirPods") }
        let connected = pods.filter { $0.isConnected() }
        // AirPods' battery comes from private getters (AirPane reads them the same way).
        let keys = ["batteryPercentLeft", "batteryPercentRight", "batteryPercentCase", "batteryPercentSingle"]
        let readable = connected.first.map { d in keys.filter { d.responds(to: NSSelectorFromString($0)) } } ?? []
        log.notice("bluetooth: \(paired.count, privacy: .public) paired, \(pods.count, privacy: .public) AirPods, \(connected.count, privacy: .public) connected; battery getters \(readable.joined(separator: ","), privacy: .public)")
    }

    /// The system HUD can only be replaced by catching the volume and brightness keys first.
    private static func hudTap() {
        let mask = CGEventMask(1 << 14)       // NX_SYSDEFINED: media and brightness keys
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, _, e, _ in Unmanaged.passUnretained(e) },
                                    userInfo: nil)
        log.notice("hud: event tap for the volume and brightness keys \(tap != nil ? "can" : "can't", privacy: .public) be created")
        if let tap { CFMachPortInvalidate(tap) }
    }
}
