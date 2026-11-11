import AppKit
import XCTest
@testable import LiquidNotch

/// The 3D AirPods (`BudsStage`): one model for every place, swaying at the front.
@MainActor
final class BudsTests: XCTestCase {
    // POD1: the ears and the card ask in the same tick; the model loads once and the scene holds one pair (two loads
    // used to show two pairs, one of them standing still).
    func testPOD1OnePairLoadedOnce() async {
        let stage = BudsStage.shared
        async let a: Void = stage.load()
        async let b: Void = stage.load()
        _ = await (a, b)
        stage.loadNow()
        XCTAssertTrue(stage.isReady)
        XCTAssertEqual(stage.models, 1)
        XCTAssertEqual(stage.budsShown, 2)
    }

    // POD2: the pair faces you at t = 0 and turns about 30° either way, never more (never a full turn).
    func testPOD2TheSwayStaysAtTheFront() {
        XCTAssertEqual(BudsStage.pose(at: 0).yaw, 0)
        let yaws = stride(from: 0.0, through: 20, by: 1.0 / 60).map { BudsStage.pose(at: $0).yaw }
        XCTAssertLessThanOrEqual(yaws.map(abs).max()!, 0.53)
        XCTAssertGreaterThan(yaws.max()!, 0.5)
        XCTAssertLessThan(yaws.min()!, -0.5)
        // A full swing either way inside the ~5 s the moment shows.
        XCTAssertGreaterThan(yaws.prefix(5 * 60).max()!, 0.5)
        XCTAssertLessThan(yaws.prefix(5 * 60).min()!, -0.5)
    }

    // POD3: places asking for the same frame share it; the sway starts over at the front after the buds were unseen.
    func testPOD3FramesAreSharedAndTheSwayStartsAtTheFront() throws {
        let stage = BudsStage.shared
        stage.loadNow()
        try XCTSkipUnless(stage.isReady, "no Metal device")
        let d0 = Date()
        let first = try XCTUnwrap(stage.image(at: d0, height: 22, scale: 2))
        XCTAssertEqual(stage.swayTime, 0)
        XCTAssertTrue(stage.image(at: d0, height: 22, scale: 2) === first)
        _ = stage.image(at: d0 + 0.25, height: 22, scale: 2)
        XCTAssertEqual(stage.swayTime ?? -1, 0.25, accuracy: 1e-9)
        _ = stage.image(at: d0 + 3, height: 22, scale: 2)
        XCTAssertEqual(stage.swayTime, 0)
        // The still is the front, and the buds fill the height asked for.
        let still = try XCTUnwrap(stage.image(at: nil, height: 48, scale: 2))
        let rect = try XCTUnwrap(BudsStage.opaqueRect(still))
        XCTAssertEqual(rect.height * Double(still.height), 96, accuracy: 3)
        XCTAssertEqual(rect.midX, stage.budsRect.midX, accuracy: 0.02)
    }

    // POD4: the stage lets go when unseen (~100 MB) and loads again, still one pair; the cutout standing in meanwhile
    // is the stage's own front view (same proportions, so nothing jumps when the 3D takes over).
    func testPOD4LetsGoAndLoadsAgain() async throws {
        let stage = BudsStage.shared
        await stage.load()
        try XCTSkipUnless(stage.isReady, "no Metal device")
        stage.unload()
        XCTAssertFalse(stage.isReady)
        XCTAssertNil(stage.image(sway: 0, height: 22, scale: 2))
        await stage.load()
        XCTAssertTrue(stage.isReady)
        XCTAssertEqual(stage.models, 1)
        XCTAssertEqual(stage.budsShown, 2)
        let cutout = try XCTUnwrap(BudsImage.image)
        let r = stage.budsRect
        XCTAssertEqual(cutout.size.width / cutout.size.height, r.width * BudsStage.aspect / r.height, accuracy: 0.02)
    }
}
