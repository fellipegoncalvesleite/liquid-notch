import XCTest
@testable import LiquidNotch

/// The ears fit whatever notch they get (11-11): unchanged in a real notch, scaled down under a 24 pt menu bar, and the
/// island never taller than the notch at rest with something showing.
@MainActor
final class EarMetricsTests: XCTestCase {
    func testARealNotchKeepsTheDesign() {
        XCTAssertEqual(EarMetrics.scale(notchHeight: 37.5), 1)
        XCTAssertEqual(EarMetrics.scale(notchHeight: 32), 1)
        XCTAssertEqual(EarMetrics.radius(18, notchHeight: 37.5), 18)
    }

    func testA24ptMenuBarGetsAnEighteenPointCoverWithThreePointMargins() {
        let e = EarMetrics.scale(notchHeight: 24)
        XCTAssertEqual(EarMetrics.designCover * e, 18, accuracy: 0.001)
        XCTAssertEqual((24 - EarMetrics.designCover * e) / 2, 3, accuracy: 0.001)
    }

    /// The ears, their pill ends and every ball stay inside the notch's height: on a notchless Mac anything lower would
    /// hang over the windows' title bars.
    func testShapesStayInsideTheNotch() {
        for nh in [24.0, 37.5] {
            var t = ShapeTargets(notchHalfWidth: 92.5, notchHeight: nh, tuning: Tuning())
            t.context.bubbleModes = [.duo]
            t.context.leftBallModes = [.duo]
            t.context.moreModes = [.duo]
            for mode in [PresentationMode.compact, .duo, .hud] {
                let s = t.resting(mode)
                XCTAssertLessThanOrEqual(s.mainHeight, nh, "\(mode) at \(nh)")
                XCTAssertLessThanOrEqual(s.mainRadius, nh / 2 + 0.001, "\(mode) at \(nh)")
            }
            let duo = t.resting(.duo)
            for r in [duo.dropRadius, duo.e1R, duo.e2R] {
                XCTAssertLessThanOrEqual(2 * r, nh + 0.001, "a ball at \(nh)")
            }
            XCTAssertLessThanOrEqual(duo.dropY + duo.dropRadius, nh + 0.001)
            XCTAssertGreaterThanOrEqual(duo.dropY - duo.dropRadius, -0.001)
        }
    }

    func testARealNotchsShapesAreUnchanged() {
        let tuning = Tuning()
        var t = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tuning)
        t.context.bubbleModes = [.duo]
        let duo = t.resting(.duo)
        XCTAssertEqual(duo.dropRadius, tuning.dropRadius)
        XCTAssertEqual(t.resting(.compact).mainRadius, tuning.earRadius)
    }
}
