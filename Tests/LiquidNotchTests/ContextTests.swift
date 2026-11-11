import CoreGraphics
import IslandCore
import XCTest
@testable import LiquidNotch

/// P3: what the window list says (fullscreen, menus), and how the system's context reaches the island.
@MainActor
final class ContextTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    let bar = 37.5
    typealias W = ContextSensing.WindowInfo

    func testFullscreenWholeScreenOrBelowTheNotch() {
        XCTAssertTrue(ContextSensing.fullscreen([W(pid: 7, layer: 0, bounds: screen)], frontPID: 7, screen: screen, menuBarHeight: bar))
        // Below the notch with the menu bar hidden: a fullscreen Space.
        let belowNotch = CGRect(x: 0, y: 38, width: 1710, height: 1074)
        XCTAssertTrue(ContextSensing.fullscreen([W(pid: 7, layer: 0, bounds: belowNotch)], frontPID: 7, screen: screen, menuBarHeight: bar))
    }

    // The same rect with the menu bar showing is a zoomed window, not fullscreen (seen live on 11-01).
    func testZoomedWindowIsNotFullscreen() {
        let zoomed = CGRect(x: 0, y: 38, width: 1710, height: 1074)
        let menuBar = W(pid: 99, layer: Int(CGWindowLevelForKey(.mainMenuWindow)), bounds: CGRect(x: 0, y: 0, width: 1710, height: 38),
                        owner: "Window Server")
        XCTAssertFalse(ContextSensing.fullscreen([W(pid: 7, layer: 0, bounds: zoomed), menuBar], frontPID: 7, screen: screen,
                                                 menuBarHeight: bar))
    }

    // Bug 11-11: Claude in front with no window showing hid the session last looked at; only a real window counts.
    func testShowsWindowNeedsARealWindow() {
        let menuBar = W(pid: 7, layer: Int(CGWindowLevelForKey(.mainMenuWindow)), bounds: CGRect(x: 0, y: 0, width: 1710, height: 38))
        XCTAssertFalse(ContextSensing.showsWindow([], pid: 7))
        XCTAssertFalse(ContextSensing.showsWindow([menuBar], pid: 7))
        XCTAssertFalse(ContextSensing.showsWindow([W(pid: 7, layer: 0, bounds: CGRect(x: 0, y: 0, width: 40, height: 30))], pid: 7))
        XCTAssertFalse(ContextSensing.showsWindow([W(pid: 8, layer: 0, bounds: CGRect(x: 0, y: 40, width: 900, height: 700))], pid: 7))
        XCTAssertTrue(ContextSensing.showsWindow([W(pid: 7, layer: 0, bounds: CGRect(x: 0, y: 40, width: 900, height: 700))], pid: 7))
    }

    func testNotFullscreen() {
        // A big window that isn't fullscreen, another app's fullscreen window, a fullscreen overlay above layer 0.
        let zoomed = CGRect(x: 0, y: 62, width: 1710, height: 1040)
        XCTAssertFalse(ContextSensing.fullscreen([W(pid: 7, layer: 0, bounds: zoomed)], frontPID: 7, screen: screen, menuBarHeight: bar))
        XCTAssertFalse(ContextSensing.fullscreen([W(pid: 8, layer: 0, bounds: screen)], frontPID: 7, screen: screen, menuBarHeight: bar))
        XCTAssertFalse(ContextSensing.fullscreen([W(pid: 7, layer: 25, bounds: screen)], frontPID: 7, screen: screen, menuBarHeight: bar))
    }

    func testMenuFromTheMenuBar() {
        let menu = ContextSensing.popUpMenuLayer
        XCTAssertTrue(ContextSensing.menuOpen([W(pid: 5, layer: menu, bounds: CGRect(x: 300, y: 37, width: 240, height: 300))],
                                              ownPID: 1, screen: screen, menuBarHeight: bar))
        // A context menu in the middle of the screen, our own menu, a sliver: none of them.
        XCTAssertFalse(ContextSensing.menuOpen([W(pid: 5, layer: menu, bounds: CGRect(x: 300, y: 500, width: 240, height: 300))],
                                               ownPID: 1, screen: screen, menuBarHeight: bar))
        XCTAssertFalse(ContextSensing.menuOpen([W(pid: 1, layer: menu, bounds: CGRect(x: 300, y: 37, width: 240, height: 300))],
                                               ownPID: 1, screen: screen, menuBarHeight: bar))
        XCTAssertFalse(ContextSensing.menuOpen([W(pid: 5, layer: menu, bounds: CGRect(x: 300, y: 37, width: 240, height: 2))],
                                               ownPID: 1, screen: screen, menuBarHeight: bar))
    }

    private func director() -> IslandDirector {
        let d = IslandDirector()
        d.schedule = ManualScheduler().schedule
        return d
    }

    // The system's context drives the island; faking it in the panel turns Live off until it's back on.
    func testLiveAndFakedContext() {
        let d = director()
        d.startMusic()
        d.systemContextChanged(DesktopContext(menuOpen: true))
        XCTAssertEqual(d.mode, .idle)
        d.setLiveContext(false)
        d.setContext(DesktopContext())
        d.systemContextChanged(DesktopContext(fullscreen: true))
        XCTAssertEqual(d.mode, .compact, "faked context wins while Live is off")
        d.setLiveContext(true)
        XCTAssertEqual(d.mode, .idle)
    }

    // Typing is read when an alert arrives: it doesn't open, and the context doesn't stay "typing".
    func testTypingReadAtShowTime() {
        let d = director()
        d.typingNow = { true }
        d.show(.incoming)
        XCTAssertFalse(d.island.opened)
        XCTAssertFalse(d.island.context.typing)
        d.endActivity()
        d.typingNow = { false }
        d.show(.incoming)
        XCTAssertTrue(d.island.opened)
    }

    // Per-app rules are data: FaceTime in front hides the call, Keynote in front is presenting.
    func testAppRulesTable() {
        XCTAssertTrue(AppRules.hosts(BundleID.faceTime, .call))
        XCTAssertFalse(AppRules.hosts(BundleID.faceTime, .timer))
        XCTAssertTrue(DesktopContext(frontmostApp: BundleID.keynote).presenting)
    }

    // FOCUS1 (11-11, "it doesn't recognize if it's already on or which mode"): the active mode from macOS's Focus
    // database, named from its configuration (a custom one too), off when nothing is asserted, the tray following it.
    func testFOCUS1WhichFocusIsOn() throws {
        let assertions: [String: Any] = ["data": [["storeAssertionRecords": [[
            "assertionDetails": ["assertionDetailsModeIdentifier": "com.apple.focus.reading-1A2B",
                                 "assertionDetailsReason": "user-action"],
        ]]]]]
        let configs: [String: Any] = ["data": [["modeConfigurations": [
            "com.apple.focus.reading-1A2B": ["mode": ["name": "Reading", "modeIdentifier": "com.apple.focus.reading-1A2B",
                                                      "symbolImageName": "book.fill"]],
            "com.apple.donotdisturb.mode.default": ["mode": ["name": "Do Not Disturb",
                                                             "modeIdentifier": "com.apple.donotdisturb.mode.default"]],
        ]]]]
        let m = try XCTUnwrap(FocusDatabase.active(assertions: assertions, configurations: configs))
        XCTAssertEqual(m.name, "Reading")
        XCTAssertEqual(m.symbol, "book.fill")
        XCTAssertNil(FocusDatabase.active(assertions: ["data": [["storeAssertionRecords": []]]], configurations: configs))
        XCTAssertEqual(FocusDatabase.fallbackName("com.apple.donotdisturb.mode.default"), "Do Not Disturb")
        XCTAssertEqual(FocusDatabase.fallbackName("com.apple.sleep.sleep-mode"), "Sleep-Mode")
        XCTAssertNil(FocusDatabase.read(folder: URL(fileURLWithPath: "/nonexistent")), "unreadable: nil, not off")

        let tray = TrayModel()
        tray.systemFocus("Work")
        XCTAssertEqual(tray.focus, .work)
        tray.systemFocus("Reading")
        XCTAssertEqual(tray.focusName, "Reading")
        XCTAssertNil(tray.focus, "a custom mode lights no built-in pill")
        tray.focusTurnedOff()
        XCTAssertNil(tray.focusName)
    }
}
