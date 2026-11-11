import AppKit
import XCTest
@testable import LiquidNotch

/// Notchless displays (11-11): which screen the island goes on and what notch it draws there, from plain screen
/// readings, so every case runs without the hardware.
@MainActor
final class NotchGeometryTests: XCTestCase {
    /// The M5's built-in screen: 1710×1112, notch 208×37.5 at x 751–959.
    private let notched = NotchGeometry.Screen(
        displayID: 1, isBuiltIn: true, frame: NSRect(x: 0, y: 0, width: 1710, height: 1112),
        visibleFrame: NSRect(x: 0, y: 0, width: 1710, height: 1074.5), safeTop: 37.5,
        auxLeftWidth: 751, auxRightWidth: 751, scale: 2)
    /// An M1 Air: built in, no notch, a 24 pt menu bar.
    private let air = NotchGeometry.Screen(
        displayID: 2, isBuiltIn: true, frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 876), safeTop: 0,
        auxLeftWidth: nil, auxRightWidth: nil, scale: 2)
    /// An external display to the right, 25 pt menu bar.
    private let external = NotchGeometry.Screen(
        displayID: 3, isBuiltIn: false, frame: NSRect(x: 1710, y: 0, width: 2560, height: 1440),
        visibleFrame: NSRect(x: 1710, y: 0, width: 2560, height: 1415), safeTop: 0,
        auxLeftWidth: nil, auxRightWidth: nil, scale: 1)

    func testRealNotchIsReadFromTheAuxiliaryAreas() {
        let g = NotchGeometry.choose([notched], placement: .main, mode: .auto)!.geometry
        XCTAssertFalse(g.isVirtual)
        XCTAssertEqual(g.notchMinX, 751)
        XCTAssertEqual(g.notchMaxX, 959)
        XCTAssertEqual(g.notchHeight, 37.5)
    }

    func testNotchlessScreenGetsAVirtualNotchTheMenuBarsHeight() {
        let g = NotchGeometry.choose([air], placement: .main, mode: .auto)!.geometry
        XCTAssertTrue(g.isVirtual)
        XCTAssertEqual(g.notchWidth, NotchGeometry.virtualWidth)
        XCTAssertEqual(g.notchCenterX, 720)
        XCTAssertEqual(g.notchHeight, 24)
    }

    func testAlwaysVirtualOnANotchedScreenStaysCentredWithTheMenuBarsHeight() {
        let g = NotchGeometry.choose([notched], placement: .main, mode: .alwaysVirtual)!.geometry
        XCTAssertTrue(g.isVirtual)
        XCTAssertEqual(g.notchWidth, NotchGeometry.virtualWidth)
        XCTAssertEqual(g.notchCenterX, 855)
        XCTAssertEqual(g.notchHeight, 37.5)
    }

    func testAHiddenMenuBarFallsBackToTheStatusBarThickness() {
        var s = air
        s.visibleFrame = s.frame
        let g = NotchGeometry.choose([s], placement: .main, mode: .auto, statusBarThickness: 24)!.geometry
        XCTAssertEqual(g.notchHeight, 24)
    }

    func testVirtualNotchOnASecondScreenUsesThatScreensOwnCoordinates() {
        let g = NotchGeometry.choose([external, notched], placement: .main, mode: .auto)!.geometry
        XCTAssertEqual(g.displayID, 3)
        XCTAssertEqual(g.notchCenterX, 1710 + 1280)
        XCTAssertEqual(g.notchHeight, 25)
        XCTAssertEqual(g.scale, 1)
    }

    func testBuiltInPlacementPrefersTheBuiltInScreenEvenWhenItIsntMain() {
        let g = NotchGeometry.choose([external, notched], placement: .builtIn, mode: .auto)!.geometry
        XCTAssertEqual(g.displayID, 1)
        XCTAssertFalse(g.isVirtual)
    }

    func testBuiltInPlacementWithTheLidClosedFallsBackToMain() {
        let g = NotchGeometry.choose([external], placement: .builtIn, mode: .auto)!.geometry
        XCTAssertEqual(g.displayID, 3)
        XCTAssertTrue(g.isVirtual)
    }

    func testNoScreensMeansNothing() {
        XCTAssertNil(NotchGeometry.choose([], placement: .main, mode: .auto))
    }

    func testPanelHangsFromTheTopCentredOnTheNotch() {
        let g = NotchGeometry.choose([air], placement: .main, mode: .auto)!.geometry
        let f = g.panelFrame(size: CGSize(width: 760, height: 420))
        XCTAssertEqual(f.midX, g.notchCenterX)
        XCTAssertEqual(f.maxY, 900)
    }

    /// The island is drawn at the panel's centre, and the panel's origin is a whole point: on an odd-width screen the
    /// virtual notch must sit on that same point, or the hit test and the drawing disagree by half a point.
    func testVirtualNotchOnAnOddWidthScreenSitsWhereThePanelDrawsIt() {
        var s = air
        s.frame.size.width = 1365
        s.visibleFrame.size.width = 1365
        let g = NotchGeometry.choose([s], placement: .main, mode: .auto)!.geometry
        let f = g.panelFrame(size: CGSize(width: 760, height: 420))
        XCTAssertEqual(f.midX, g.notchCenterX)
        XCTAssertEqual(f.minX, f.minX.rounded())
    }
}
