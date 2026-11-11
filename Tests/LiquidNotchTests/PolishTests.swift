import AppKit
import IslandCore
@preconcurrency import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import LiquidNotch

/// The native polish pass of 11-06: what brings the app closer to the simulator.
@MainActor
final class PolishTests: XCTestCase {
    // SYNC1: the liquid's frame is shown in the same Core Animation transaction as the content above it (the sim draws
    // its canvas and its HTML in one frame), so the text and the clip never trail the shape during a fast move.
    func testSYNC1TheLiquidPresentsWithTheContent() throws {
        let view = LiquidView(renderer: try LiquidRenderer())
        XCTAssertTrue(view.metalLayer.presentsWithTransaction)
    }

    // BAL2: the +N list is exactly as tall as its card, with something hidden (its heading counted): it used to run
    // 4 pt past the card's bottom.
    func testBAL2TheMoreListFitsItsCard() {
        let d = IslandDirector()
        d.schedule = ManualScheduler().schedule
        d.startMusic(); d.show(.recording); d.show(.call, opened: false); d.show(.timer); d.show(.camera)
        d.show(.download); d.hide(.media)
        XCTAssertFalse(d.island.arrangement.hidden.isEmpty)
        let card = d.island.moreCard
        let view = MoreList(director: d)
            .frame(width: card.width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
        XCTAssertEqual(Double(NSHostingView(rootView: view).fittingSize.height), card.height, accuracy: 0.5)
    }

    // PEEK3: a ball's peek borrows the card's channels, but the song's art and bars stay in the ears: once the player
    // had been open, hovering a ball used to pull the cover half out under the ears.
    func testPEEK3ABallsPeekLeavesTheArtHome() {
        var player = ContentGroups()
        player.player = true
        XCTAssertTrue(NotchContentModel.artRidesCard(mode: .card, groups: player, was: false))
        // Closing the player: the art rides the shrinking card back.
        XCTAssertTrue(NotchContentModel.artRidesCard(mode: .compact, groups: ContentGroups(), was: true))
        var peek = ContentGroups()
        peek.peekPlace = 0
        XCTAssertFalse(NotchContentModel.artRidesCard(mode: .duo, groups: peek, was: true))
        // ...and stays home while that peek shrinks away.
        XCTAssertFalse(NotchContentModel.artRidesCard(mode: .duo, groups: ContentGroups(), was: false))
    }

    // NEAR1: anticipation (sim `near`): within 70 pt of the ears they widen up to 4 pt and glow up to 30% brighter, in
    // quarter steps, only while they're out (compact, duo); the balls keep their gap; a card never moves.
    func testNEAR1TheIslandNoticesThePointerComing() {
        XCTAssertEqual(ShapeTargets.near(distance: 0), 1)
        XCTAssertEqual(ShapeTargets.near(distance: 20), 0.75)
        XCTAssertEqual(ShapeTargets.near(distance: 35), 0.5)
        XCTAssertEqual(ShapeTargets.near(distance: 70), 0)
        XCTAssertEqual(ShapeTargets.near(distance: 300), 0)
        var tune = Tuning()
        tune.dimGlow = false
        var c = TargetContext()
        c.bubbleModes = [.duo]
        let base = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tune, context: c)
        c.near = 0.75
        let near = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tune, context: c)
        for mode in [PresentationMode.compact, .duo] {
            let a = base.resting(mode), b = near.resting(mode)
            XCTAssertEqual(b.mainHalfWidth, a.mainHalfWidth + 3, accuracy: 1e-9, "\(mode)")
            XCTAssertEqual(b.glowIntensity, a.glowIntensity * 1.225, accuracy: 1e-9, "\(mode)")
            if mode == .duo {   // the ball is out there (tucked away in compact)
                XCTAssertEqual(b.dropX - b.mainHalfWidth, a.dropX - a.mainHalfWidth, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(near.resting(.card).mainHalfWidth, base.resting(.card).mainHalfWidth)
        XCTAssertEqual(near.resting(.peek).mainHalfWidth, base.resting(.peek).mainHalfWidth)
    }

    // REC2: recording captures in the encoder's own format with a short queue, at full size and 60 fps.
    func testREC2RecordingCapturesLight() {
        let c = ScreenRecorder.configuration(width: 3420, height: 2224)
        XCTAssertEqual(c.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(c.queueDepth, 4)
        XCTAssertEqual(c.width, 3420)
        XCTAssertEqual(c.height, 2224)
        XCTAssertEqual(c.minimumFrameInterval, CMTime(value: 1, timescale: 60))
        XCTAssertFalse(c.capturesAudio)
    }

    // MOM1: the moments pass through the sim's keyframe stops (`zap`, `boltFlash`): hidden while the content's reveal
    // waits, the peak at its stop, and they end at rest so nothing jumps when the animator lets go.
    func testMOM1MomentsFollowTheSimsKeyframes() {
        let wait = 0.27, zapT = 0.9
        let zap = KeyframeTimeline(initialValue: MomentPose()) { Zap.keys(wait: wait, t: zapT) }
        let start = zap.value(time: 0), mid = zap.value(time: wait / 2)
        for p in [start, mid] {
            XCTAssertEqual(p.opacity, Zap.hidden.opacity, accuracy: 1e-6)
            XCTAssertEqual(p.scale, Zap.hidden.scale, accuracy: 1e-6)
            XCTAssertEqual(p.angle, Zap.hidden.angle, accuracy: 1e-6)
        }
        let peak = zap.value(time: wait + 0.35 * zapT)
        XCTAssertEqual(peak.scale, 1.5, accuracy: 1e-6)
        XCTAssertEqual(peak.angle, 8, accuracy: 1e-6)
        XCTAssertEqual(peak.opacity, 1, accuracy: 1e-6)
        XCTAssertEqual(zap.value(time: wait + 0.6 * zapT).scale, 0.9, accuracy: 1e-6)
        let end = zap.value(time: zap.duration)
        XCTAssertEqual(zap.duration, wait + zapT, accuracy: 1e-6)
        XCTAssertEqual(end.scale, 1, accuracy: 1e-6)
        XCTAssertEqual(end.angle, 0, accuracy: 1e-6)
        XCTAssertEqual(end.opacity, 1, accuracy: 1e-6)

        let flashT = 1.2
        let flash = KeyframeTimeline(initialValue: MomentPose()) { BoltFlash.keys(wait: wait, t: flashT) }
        XCTAssertEqual(flash.value(time: 0).opacity, 0, accuracy: 1e-6)
        XCTAssertEqual(flash.value(time: wait + 0.4 * flashT).scale, 1.35, accuracy: 1e-6)
        XCTAssertEqual(flash.value(time: flash.duration).scale, 1, accuracy: 1e-6)
        XCTAssertEqual(flash.value(time: flash.duration).opacity, 1, accuracy: 1e-6)
    }
}
