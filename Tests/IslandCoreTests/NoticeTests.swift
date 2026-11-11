import XCTest
import IslandCore

/// Notifications in the notch (banners only since 11-11): where an arrival goes, and hover opening its card.
final class NoticeTests: XCTestCase {
    private let player = CardSize(width: 372, height: 168, radius: 34)
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func n(_ id: String, _ app: String = "com.apple.mail", title: String? = "Beatriz Lima", body: String? = "See you at ten",
                   thread: String? = nil, ago: Double = 0, level: NoticeLevel = .active) -> Notice {
        Notice(id: id, app: app, appName: app == "com.apple.mail" ? "Mail" : "WhatsApp", title: title, body: body,
               thread: thread, date: t0.addingTimeInterval(-ago), level: level)
    }

    // MARK: Where an arrival goes (sim `notify`)

    func testArrivals() {
        let c = DesktopContext()
        XCTAssertEqual(NoticeArrival.of(n("a"), context: c, trayOpen: false), .ears)
        XCTAssertEqual(NoticeArrival.of(n("a", level: .passive), context: c, trayOpen: false), .skip)
        XCTAssertEqual(NoticeArrival.of(n("a"), context: c, trayOpen: true), .skip)
        var focus = c; focus.focusOn = true
        XCTAssertEqual(NoticeArrival.of(n("a"), context: focus, trayOpen: false), .skip)
        XCTAssertEqual(NoticeArrival.of(n("a", level: .timeSensitive), context: focus, trayOpen: false), .ears)
        XCTAssertEqual(NoticeArrival.of(n("a", level: .critical), context: focus, trayOpen: false), .ears)
        var front = c; front.frontmostApp = "com.apple.mail"
        XCTAssertEqual(NoticeArrival.of(n("a"), context: front, trayOpen: false), .skip)
        var sharing = c; sharing.sharing = true
        XCTAssertEqual(NoticeArrival.of(n("a", level: .critical), context: sharing, trayOpen: false), .skip)
        var full = c; full.fullscreen = true
        XCTAssertEqual(NoticeArrival.of(n("a"), context: full, trayOpen: false), .skip)
    }

    // MARK: The island

    func testHoveringANotificationOpensItsCard() {
        var i = Island()
        i.apply(.show(.notice, opened: false))
        XCTAssertEqual(i.mode, .compact)
        i.apply(.hover)
        XCTAssertEqual(i.mode, .card)
        XCTAssertEqual(i.cardOwner, .activity)
        XCTAssertEqual(i.cardSize(player: player), ActivitySpec[.notice].card)
        // Another activity's ears still don't open on hover.
        var j = Island()
        j.apply(.show(.charging))
        j.apply(.hover)
        XCTAssertNotEqual(j.mode, .card)
    }
}
