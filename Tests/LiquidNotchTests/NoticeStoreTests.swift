import IslandCore
import SQLite3
import XCTest
@testable import LiquidNotch

/// Notifications (11-07, design 2026-11-07-notifications): reading macOS's list from a database laid out like
/// usernoted's (NSTORE1), and the director's rules (NDIR1–NDIR4; banners only since 11-11).
@MainActor
final class NoticeStoreTests: XCTestCase {
    /// A database with usernoted's `app` and `record` tables (macOS 27.0.1's columns) and these records.
    private func database(_ records: [(rec: Int, app: String, plist: [String: Any], delivered: Double)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notices-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            create table app (app_id integer primary key, identifier varchar, badge integer);
            create table record (rec_id integer primary key, app_id integer, uuid blob, data blob, request_date real,
              request_last_date real, delivered_date real, presented bool, style integer, snooze_fire_date real);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        var apps: [String: Int] = [:]
        for r in records {
            let appID = apps[r.app] ?? (apps.count + 1)
            if apps[r.app] == nil {
                apps[r.app] = appID
                XCTAssertEqual(sqlite3_exec(db, "insert into app values (\(appID), '\(r.app)', 0)", nil, nil, nil), SQLITE_OK)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: r.plist, format: .binary, options: 0)
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "insert into record (rec_id, app_id, uuid, data, delivered_date) values (?, ?, ?, ?, ?)", -1, &stmt, nil), SQLITE_OK)
            let uuid = withUnsafeBytes(of: UUID().uuid) { Data($0) }
            sqlite3_bind_int(stmt, 1, Int32(r.rec))
            sqlite3_bind_int(stmt, 2, Int32(appID))
            _ = uuid.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(uuid.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_bind_double(stmt, 5, r.delivered)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        return url
    }

    // NSTORE1: every field, the level from `intl`, the record's own app over a prefixed identifier, newest first, a
    // record that isn't a plist skipped, our own notifications left out.
    func testNSTORE1ReadsRecordsLikeUsernoteds() throws {
        let now = Date().timeIntervalSinceReferenceDate
        let url = try database([
            (1, "com.apple.mail", ["app": "com.apple.mail", "req": ["titl": "Beatriz Lima", "subt": "Re: Saturday", "body": "See you at ten", "thre": "inbox"]], now - 60),
            (2, "_SYSTEM_CENTER_:com.apple.iCal", ["intl": 2, "req": ["titl": "Design review", "body": "In 10 minutes"]], now - 10),
            (3, "com.apple.AppStore", ["app": "com.apple.AppStore", "intl": 0, "req": ["titl": "3 apps were updated"]], now - 5),
            (4, "com.apple.findmy", ["app": "com.apple.findmy", "req": ["body": "Your AirPods were left behind"]], now - 30),
            (5, Bundle.main.bundleIdentifier ?? "x", ["app": Bundle.main.bundleIdentifier ?? "x", "req": ["titl": "ours"]], now),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try XCTUnwrap(NotificationStore.read(at: url, skip: []))
        XCTAssertEqual(rows.map(\.rec), [3, 2, 4, 1], "newest first, ours left out")
        let mail = try XCTUnwrap(rows.first { $0.rec == 1 }?.notice)
        XCTAssertEqual(mail.app, "com.apple.mail")
        XCTAssertEqual(mail.title, "Beatriz Lima")
        XCTAssertEqual(mail.subtitle, "Re: Saturday")
        XCTAssertEqual(mail.body, "See you at ten")
        XCTAssertEqual(mail.thread, "inbox")
        XCTAssertEqual(mail.level, .active)
        XCTAssertEqual(mail.id.count, 32, "the uuid as hex")
        XCTAssertEqual(mail.date.timeIntervalSinceReferenceDate, now - 60, accuracy: 0.001)
        let cal = try XCTUnwrap(rows.first { $0.rec == 2 }?.notice)
        XCTAssertEqual(cal.app, "com.apple.iCal", "the prefix comes off")
        XCTAssertEqual(cal.level, .timeSensitive)
        XCTAssertEqual(rows.first { $0.rec == 3 }?.notice.level, .passive)
        let find = try XCTUnwrap(rows.first { $0.rec == 4 }?.notice)
        XCTAssertNil(find.title)
        XCTAssertEqual(find.head, find.appName)
    }

    // NSTORE2: Claude's and Codex's notifications stay out (their balls already show them), AirPane's too (the notch's own
    // AirPods activity); so does a record older than a week.
    func testNSTORE2AppsShownElsewhereAndOldOnesStayOut() throws {
        XCTAssertEqual(NotificationStore.shownElsewhere, ["com.anthropic.claudefordesktop", "com.openai.codex"])
        let now = Date().timeIntervalSinceReferenceDate
        let url = try database([
            (1, "com.openai.codex", ["app": "com.openai.codex", "req": ["titl": "Done"]], now - 60),
            (2, "com.apple.mail", ["app": "com.apple.mail", "req": ["titl": "New"]], now - 60),
            (3, "com.apple.mail", ["app": "com.apple.mail", "req": ["titl": "Old"]], now - 8 * 24 * 3600),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try XCTUnwrap(NotificationStore.read(at: url))
        XCTAssertEqual(rows.map(\.rec), [2])
    }

    private func director() -> (IslandDirector, ManualScheduler) {
        let d = IslandDirector(), s = ManualScheduler()
        d.schedule = s.schedule
        d.clock = { 0 }
        d.frontmostApp = { "" }
        return (d, s)
    }

    private func notice(_ id: String, app: String = "com.apple.mail", thread: String? = nil, level: NoticeLevel = .active) -> Notice {
        Notice(id: id, app: app, appName: "Mail", title: "Beatriz Lima", body: "See you at ten", thread: thread, date: Date(), level: level)
    }

    // NDIR1: an arrival opens as its card by itself, closes into the ears after the banner's time, then leaves for good.
    func testNDIR1AnArrivalIsABannerThenLeaves() {
        let (d, s) = director()
        let n = notice("a1")
        d.noticesChanged(all: [n], arrived: [n])
        XCTAssertEqual(d.island.activity?.id, .notice)
        XCTAssertEqual(d.notice(for: d.island.activity!).id, "a1")
        XCTAssertEqual(d.island.mode, .card, "it arrives as its card")
        s.advance(IslandDirector.noticeBannerSeconds + 0.1)
        XCTAssertEqual(d.island.mode, .compact, "then waits in the ears")
        s.advance(10)
        XCTAssertNil(d.island.activity, "and leaves; nothing keeps it")
    }

    // NDIR2: the pointer on the card keeps it open past the banner's time; × dismisses it at once.
    func testNDIR2HoverKeepsItAndXDismisses() {
        let (d, s) = director()
        let n = notice("a1")
        d.noticesChanged(all: [n], arrived: [n])
        d.pointerMoved(hit: .card, corridor: false, buttonDown: false)
        s.advance(IslandDirector.noticeBannerSeconds + 0.1)
        XCTAssertEqual(d.island.mode, .card, "held while the pointer is on it")
        d.dismissNotice(n)
        XCTAssertNil(d.island.activity)
    }

    // NDIR3: arriving while a card is open, it never takes the card: it waits and comes when the card closes.
    func testNDIR3ItWaitsForAnOpenCard() {
        let (d, _) = director()
        d.startMusic()
        d.pointerDown(at: .zero, hit: .ears)
        XCTAssertTrue(d.island.opened)
        let n = notice("a1")
        d.noticesChanged(all: [n], arrived: [n])
        XCTAssertEqual(d.island.cardOwner, .media)
        XCTAssertNotEqual(d.island.activity?.id, .notice)
        d.clickOutside()
        XCTAssertEqual(d.island.activity?.id, .notice, "it comes once the card closes")
    }

    // NDIR4: passive, from the app in front, or during a Focus (unless time-sensitive) nothing shows.
    func testNDIR4QuietArrivals() {
        let (d, _) = director()
        let p = notice("p", level: .passive)
        d.noticesChanged(all: [p], arrived: [p])
        XCTAssertNil(d.island.activity)
        var c = d.island.context
        c.focusOn = true
        d.setContext(c)
        let q = notice("q")
        d.noticesChanged(all: [q, p], arrived: [q])
        XCTAssertNil(d.island.activity)
        let t = notice("t", level: .timeSensitive)
        d.noticesChanged(all: [t, q, p], arrived: [t])
        XCTAssertEqual(d.island.activity?.id, .notice, "time-sensitive comes through a Focus")
    }
}
