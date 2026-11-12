import XCTest
import IslandCore

/// The idle tray (sim probe `TRAY1`, design 2026-11-01-idle-tray): what a press on the notch opens.
final class TrayTests: XCTestCase {
    private let player = CardSize(width: 372, height: 168, radius: 34)

    func testEmptyNotchOpensTheToolsAtThePlayersSize() {
        var i = Island()
        XCTAssertTrue(i.canOpenEmptyTray)
        i.apply(.openTray)
        XCTAssertTrue(i.trayOpen)
        XCTAssertEqual(i.mode, .card)
        let g = i.groups(.card)
        XCTAssertTrue(g.tray)
        XCTAssertFalse(g.player)
        XCTAssertEqual(i.cardSize(player: player), player)
        i.apply(.close)
        XCTAssertFalse(i.trayOpen)
        XCTAssertEqual(i.mode, .idle)
    }

    func testMediaHiddenByItsOwnAppDoesNotImmediatelyCloseTheTools() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.context(DesktopContext(frontmostApp: BundleID.music)))
        XCTAssertEqual(i.mode, .idle)
        XCTAssertTrue(i.canOpenEmptyTray)

        i.apply(.openTray)
        XCTAssertTrue(i.opened)
        XCTAssertTrue(i.trayShows)
        XCTAssertEqual(i.mode, .card)
        XCTAssertTrue(i.groups(i.mode).tray)
        XCTAssertFalse(i.groups(i.mode).player)
        XCTAssertEqual(i.cardSize(player: player), player)

        i.apply(.context(DesktopContext(frontmostApp: BundleID.music)))
        XCTAssertTrue(i.trayShows, "a context refresh must leave the explicitly opened tools available")
        i.apply(.context(DesktopContext()))
        XCTAssertTrue(i.trayShows)
        XCTAssertTrue(i.groups(i.mode).player, "when media becomes visible, the tools move beside the player")
    }

    // One click for the music, two for the music and the tools (owner, 11-01).
    func testOneClickOpensThePlayerAloneASecondAddsTheTools() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.open(.media))
        XCTAssertFalse(i.groups(.card).tray)
        XCTAssertEqual(i.cardSize(player: player), player)
        i.apply(.openTray)
        XCTAssertTrue(i.groups(.card).tray && i.groups(.card).player)
        XCTAssertEqual(i.cardSize(player: player).width, 372 + Island.trayColumn)
        i.apply(.close)
        i.apply(.open(.media))             // it closes back to the player alone
        XCTAssertFalse(i.groups(.card).tray)
    }

    func testWithASongTheTrayIsThePlayersCardWithTheToolsBeside() {
        var i = Island()
        i.apply(.startMedia)
        XCTAssertFalse(i.canOpenEmptyTray)
        i.apply(.openTray)
        XCTAssertFalse(i.trayOpen)
        XCTAssertEqual(i.mode, .card)
        let g = i.groups(.card)
        XCTAssertTrue(g.tray && g.player)
        XCTAssertEqual(i.cardSize(player: player).width, 372 + Island.trayColumn)
    }

    // The double-click on the notch opens the tools whatever is in the ears (owner, 11-11); the activity waits in a ball.
    func testTheToolsOpenOverAnActivityInTheEars() {
        var i = Island()
        i.apply(.show(.timer))
        i.apply(.openTray)
        XCTAssertTrue(i.opened)
        XCTAssertTrue(i.trayShows)
        XCTAssertTrue(i.trayOver)
        XCTAssertTrue(i.bubbleParties(.card).contains(.activity))
        i.apply(.close)
        XCTAssertFalse(i.trayOver)
        XCTAssertEqual(i.mode, .compact)    // the timer is back in the ears
    }

    // The first press of a double-click opened the activity's card; the second (on the notch) brings the tools.
    func testTheToolsTakeAnOpenCardsPlace() {
        var i = Island()
        i.apply(.show(.timer, opened: false))
        i.apply(.open(.activity))
        XCTAssertFalse(i.trayShows)
        i.apply(.openTray)
        XCTAssertTrue(i.trayShows)

        var j = Island()                    // the player's card gains the tools beside it, as before
        j.apply(.startMedia)
        j.apply(.show(.timer, opened: false))
        j.apply(.open(.activity))
        j.apply(.openTray)
        XCTAssertTrue(j.groups(.card).tray && j.groups(.card).player)
    }

    // Bug 11-10: something running but hidden (here the meeting, with Calendar in front) left the notch looking empty,
    // and a press there did nothing because the tray asked `live` instead of what shows.
    func testAHiddenActivityLeavesTheEmptyNotchPressable() {
        var i = Island()
        i.apply(.context(DesktopContext(frontmostApp: BundleID.calendar)))
        i.apply(.show(.meeting, opened: false))
        XCTAssertNil(i.arrangement.ears)
        XCTAssertTrue(i.canOpenEmptyTray)
        i.apply(.openTray)
        XCTAssertTrue(i.trayShows)
        XCTAssertEqual(i.mode, .card)
    }

    // Bug 11-10: the ears emptied under an open card (log: opened=true, mode=idle) and presses found nothing.
    func testAnIslandOpenOverNothingCloses() {
        var i = Island()
        i.apply(.show(.meeting, opened: false))
        i.apply(.open(.activity))
        XCTAssertTrue(i.opened)
        i.apply(.context(DesktopContext(frontmostApp: BundleID.calendar)))   // its own app comes forward: it hides
        XCTAssertFalse(i.opened)
        XCTAssertEqual(i.mode, .idle)
        XCTAssertTrue(i.canOpenEmptyTray)
    }

    func testAnythingArrivingTakesTheTraysPlace() {
        var i = Island()
        i.apply(.openTray)
        i.apply(.show(.timer, opened: false))
        XCTAssertFalse(i.trayOpen)
        XCTAssertEqual(i.mode, .compact)

        var j = Island()
        j.apply(.openTray)
        j.apply(.startMedia)               // a song starting under the open tray: the tray gains the player
        XCTAssertFalse(j.trayOpen)
        XCTAssertEqual(j.mode, .card)
        XCTAssertTrue(j.groups(.card).player && j.groups(.card).tray)
    }

    func testNothingOpensOverAMenuOrFullscreen() {
        for c in [DesktopContext(menuOpen: true), DesktopContext(fullscreen: true), DesktopContext(locked: true)] {
            var i = Island()
            i.apply(.context(c))
            XCTAssertFalse(i.canOpenEmptyTray)
            i.apply(.openTray)
            XCTAssertEqual(i.mode, .idle)
        }
        var i = Island()
        i.apply(.openTray)
        i.apply(.context(DesktopContext(menuOpen: true)))
        XCTAssertFalse(i.trayOpen)
    }

    // The scroll's steps with a song: the player, then the tools alone in its place (the player's size), then back.
    func testToolsOnlyTakeThePlayersPlaceAndStepBack() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.open(.media))
        XCTAssertTrue(i.groups(.card).player)
        i.apply(.openToolsOnly)
        XCTAssertTrue(i.trayShows)
        XCTAssertTrue(i.toolsOnly)
        XCTAssertTrue(i.groups(.card).tray)
        XCTAssertFalse(i.groups(.card).player, "the tools alone, no player beside them")
        XCTAssertEqual(i.cardSize(player: player), player)
        i.apply(.closeTools)
        XCTAssertTrue(i.opened)
        XCTAssertFalse(i.trayShows)
        XCTAssertFalse(i.toolsOnly)
        XCTAssertTrue(i.groups(.card).player)
        i.apply(.close)
        XCTAssertFalse(i.opened)
    }

    // The double-click's tools stay beside the player.
    func testOpenTrayWithASongStillPutsTheToolsBeside() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.open(.media))
        i.apply(.openTray)
        XCTAssertFalse(i.toolsOnly)
        XCTAssertTrue(i.groups(.card).player)
        XCTAssertTrue(i.groups(.card).tray)
    }
}
