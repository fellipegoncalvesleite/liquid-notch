import AppKit
import IslandCore
import NowPlaying
import SwiftUI
import XCTest
@testable import LiquidNotch

/// Runs scheduled choreography by hand.
@MainActor
final class ManualScheduler {
    private var now = 0.0
    private var items: [(at: Double, id: Int, body: @MainActor () -> Void)] = []
    private var next = 0

    var schedule: Schedule {
        { seconds, body in
            let id = self.next
            self.next += 1
            self.items.append((self.now + seconds, id, body))
            return Scheduled { self.items.removeAll { $0.id == id } }
        }
    }

    func advance(_ seconds: Double) {
        let end = now + seconds
        while let i = items.indices.filter({ items[$0].at <= end }).min(by: { items[$0].at < items[$1].at }) {
            let item = items.remove(at: i)
            now = item.at
            item.body()
        }
        now = end
    }
}

/// The simulator's probes, ported: card pose and bridges (T2), pointer rules (PT2–PT11), glow
/// cut-off (G1), card balance (BAL1), clocks (CLK1), Reduce Motion and the Messages reply.
@MainActor
final class ProbeTests: XCTestCase {
    let nhw = 104.0, nh = 37.5
    let tuning = Tuning()

    private func targets(_ c: TargetContext = TargetContext()) -> ShapeTargets {
        ShapeTargets(notchHalfWidth: nhw, notchHeight: nh, tuning: tuning, context: c)
    }

    private func animator(_ t: ShapeTargets, at mode: IslandCore.PresentationMode) -> ShapeAnimator {
        let a = ShapeAnimator(initial: t.resting(mode), configs: tuning.springs, dynamics: tuning.dynamics)
        a.floor = (nhw, nh)
        a.cardBridge = (tuning.cardNeckMax, tuning.cardBreakGap)
        a.snap(to: t.resting(mode))
        return a
    }

    private func open(_ a: ShapeAnimator, _ t: ShapeTargets, from: IslandCore.PresentationMode) {
        a.snapChannels(ShapeTargets.cardChannels, from: t.cardSeed)
        let (first, stages) = t.transition(from: from, to: .card)
        a.setTargets(first, then: stages)
    }

    // T2: compact -> card lands at the spec's pose; the bridge lived and snapped; the ears never rose above the notch.
    func testT2CardPose() {
        let t = targets()
        let a = animator(t, at: .compact)
        open(a, t, from: .compact)
        var neckMs = 0.0, minEarH = 1e9
        for _ in 0..<360 {
            a.advance(1.0 / 240)
            if a.frame.cardNeck > 0.05 { neckMs += 1000.0 / 240 }
            minEarH = min(minEarH, t.drawnHeight(a.current))
        }
        let c = a.current
        XCTAssertEqual(c.cardTop, 45.5, accuracy: 0.05)
        XCTAssertEqual(c.cardHalfWidth.rounded(), 186)
        XCTAssertEqual(c.mainHalfWidth.rounded(), (nhw + tuning.idleGrow).rounded())   // the rounded resting notch (11-06)
        XCTAssertTrue(neckMs > 40 && neckMs < 400, "bridge lived \(neckMs) ms")
        XCTAssertEqual(a.frame.cardNeck, 0)
        XCTAssertGreaterThanOrEqual(minEarH, 36.5)
    }

    // T2 (review): closing while still opening reverses cleanly.
    func testT2ClosingWhileOpeningReverses() {
        let t = targets()
        let a = animator(t, at: .compact)
        open(a, t, from: .compact)
        var maxW = 0.0
        for _ in 0..<24 { a.advance(1.0 / 240); maxW = max(maxW, a.current.cardHalfWidth) }
        let (first, stages) = t.transition(from: .card, to: .compact)
        a.setTargets(first, then: stages)
        for _ in 0..<360 { a.advance(1.0 / 240); maxW = max(maxW, a.current.cardHalfWidth) }
        XCTAssertLessThan(a.current.cardHalfWidth, 0.5)
        XCTAssertEqual(a.frame.cardNeck, 0)
        XCTAssertLessThanOrEqual(maxW, 200)
    }

    // T2 (review): the bubble and the card out together; their bridges stay apart.
    func testT2BubbleAndCardStayApart() {
        var c = TargetContext()
        c.bubbleModes = [.duo, .card]
        let t = targets(c)
        let a = animator(t, at: .duo)
        open(a, t, from: .duo)
        for _ in 0..<360 { a.advance(1.0 / 240) }
        let s = a.current
        XCTAssertEqual(s.dropRadius, tuning.dropRadius)
        XCTAssertEqual(s.cardTop, 45.5, accuracy: 0.05)
        XCTAssertEqual(a.frame.neckRadius, 0)
        XCTAssertGreaterThanOrEqual(s.dropX - s.dropRadius, 60)
    }

    // PT10: dragged up, the card rises into the notch and sticks (its bridge attaches); back down, it rests open.
    func testPT10DraggedUpSticksToTheNotch() {
        var c = TargetContext()
        let a = animator(targets(c), at: .card)
        c.pressed = true
        a.dragging = true
        var minTop = 1e9, stuck = false
        func walk(_ ys: StrideThrough<Double>) {
            for y in ys {
                c.drag = SIMD2(0, y - 120)
                a.setFinal(targets(c).resting(.card))
                for _ in 0..<24 {
                    a.advance(1.0 / 240)
                    minTop = min(minTop, a.current.cardTop)
                    stuck = stuck || a.frame.cardNeck > 0.05
                }
            }
        }
        walk(stride(from: 110, through: -150, by: -20))
        walk(stride(from: -130, through: 120, by: 20))
        c.pressed = false
        c.drag = nil
        a.dragging = false
        a.setFinal(targets(c).resting(.card))
        for _ in 0..<480 { a.advance(1.0 / 240) }
        XCTAssertLessThanOrEqual(minTop, nh)
        XCTAssertTrue(stuck)
        XCTAssertEqual(a.current.cardTop, 45.5, accuracy: 0.05)
    }

    // PT2 + PT4: a drag follows on a rubber band and swells the card; a press squashes it.
    func testPT2PT4PressAndRubberBand() {
        var c = TargetContext()
        c.pressed = true
        c.drag = SIMD2(80, 0)
        let s = targets(c).resting(.card)
        XCTAssertTrue(s.cardX > 10 && s.cardX < 40, "cardX \(s.cardX)")
        XCTAssertGreaterThan(s.cardHalfWidth, tuning.cardHalfWidth)
        // The notch liquid under the card swells with the drag (against the card's own resting notch; the idle notch
        // is wider since 11-06).
        XCTAssertGreaterThan(s.mainHalfWidth, targets().resting(.card).mainHalfWidth + 1)
        c.drag = .zero
        let squashed = targets(c).resting(.card)
        XCTAssertGreaterThan(squashed.cardHalfWidth, tuning.cardHalfWidth)
        XCTAssertLessThan(squashed.cardHeight, tuning.cardHeight)
    }

    // G1: the glow fades out before the edge of the drawing area, even with the card dragged all the way down.
    func testG1GlowFadesBeforeThePanelEdge() throws {
        let renderer = try LiquidRenderer()
        var c = TargetContext()
        c.pressed = true
        c.drag = SIMD2(0, 400)
        for dim in [true, false] {
            var tune = tuning
            tune.dimGlow = dim
            let t = ShapeTargets(notchHalfWidth: nhw, notchHeight: nh, tuning: tune, context: c)
            let f = t.restingFrame(.card)
            let size = NotchSurfaceController.panelSize
            let constants = SurfaceConstants(viewSize: SIMD2(Double(size.width), Double(size.height)), scale: 1,
                                             notchHalfWidth: nhw - 1, notchHeight: nh - 1, notchRadius: 9,
                                             cornerExponent: tune.cornerExponent, kNotch: tune.kNotch, kDrop: tune.kDrop,
                                             edgeFeather: tune.edgeFeather)
            let u = ShapeUniforms(state: f.state, neckRadius: f.neckRadius, dropRadii: f.dropRadii, constants: constants,
                                  extras: FrameExtras(cardNeck: f.cardNeck, earGlowOffset: 8))
            let w = Int(size.width), h = Int(size.height)
            let px = renderer.renderOffscreen(width: w, height: h, uniforms: u)
            let bottom = f.state.cardTop + f.state.cardHeight
            XCTAssertLessThan(bottom, Double(h) - 20, "the card stays inside the panel")
            let alpha = Int(px[((h - 2) * w + w / 2) * 4 + 3])
            XCTAssertLessThanOrEqual(alpha, 1, "glow at the panel's bottom edge (dim \(dim))")
        }
    }

    // MARK: - Director (pointer rules)

    private func director() -> (IslandDirector, ManualScheduler) {
        let d = IslandDirector()
        let s = ManualScheduler()
        d.schedule = s.schedule
        var t = 0.0
        d.clock = { t += 0; return t }
        var real = 0.0
        d.realTime = { real += 1; return real }   // presses a second apart: never a double click
        return (d, s)
    }

    private func openCard(_ d: IslandDirector) {
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        d.pointerDown(at: SIMD2(380, 18), hit: .ears)
        d.pointerUp(at: SIMD2(380, 18), hit: .card, corridor: false)
    }

    // PT11: the click that ends an opening press never closes the card it just opened.
    func testPT11OpeningPressKeepsTheCard() {
        let (d, _) = director()
        d.show(.messages)
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        d.pointerDown(at: SIMD2(186, 19), hit: .ears)
        d.pointerUp(at: SIMD2(186, 19), hit: nil, corridor: false)   // the ears retracted under the pointer
        XCTAssertTrue(d.island.opened)
        XCTAssertEqual(d.mode, .card)
    }

    // One click for the music, two for the music and the tools (owner, 11-01).
    func testSecondPressSoonAfterAddsTheTools() {
        let (d, _) = director()
        d.realTime = { 0 }
        d.startMusic()
        openCard(d)
        XCTAssertTrue(d.groups.player)
        XCTAssertFalse(d.groups.tray)
        d.pointerDown(at: SIMD2(380, 18), hit: .ears)
        d.pointerUp(at: SIMD2(380, 18), hit: .ears, corridor: false)
        XCTAssertTrue(d.island.opened)
        XCTAssertTrue(d.groups.tray && d.groups.player)
    }

    // PT3: a swipe up on the card closes it.
    func testPT3SwipeUpCloses() {
        let (d, _) = director()
        d.startMusic()
        openCard(d)
        d.pointerDown(at: SIMD2(380, 120), hit: .card)
        d.pointerDragged(to: SIMD2(380, 66))
        d.pointerUp(at: SIMD2(380, 66), hit: .card, corridor: false)
        XCTAssertFalse(d.island.opened)
        XCTAssertNotEqual(d.mode, .card)
    }

    // PT5: clicking the notch while the card is open closes it, and no preview pops up under the pointer.
    func testPT5NotchClickClosesWithoutPreview() {
        let (d, _) = director()
        d.startMusic()
        openCard(d)
        d.pointerDown(at: SIMD2(380, 20), hit: .ears)
        d.pointerUp(at: SIMD2(380, 20), hit: .ears, corridor: false)
        XCTAssertFalse(d.island.opened)
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .compact)
    }

    // PT6: holding the card is using it: a drag off the card never closes it; the linger starts on release.
    func testPT6HoldingNeverCloses() {
        let (d, s) = director()
        d.startMusic()
        openCard(d)
        d.pointerDown(at: SIMD2(380, 120), hit: .card)
        for y in stride(from: 130.0, through: 420, by: 30) {
            d.pointerDragged(to: SIMD2(380, y))
            d.pointerMoved(hit: nil, corridor: false, buttonDown: true)
        }
        s.advance(tuning.closeDelay + 0.3)
        XCTAssertTrue(d.island.opened, "held")
        d.pointerUp(at: SIMD2(380, 420), hit: nil, corridor: false)
        XCTAssertTrue(d.island.opened, "not closed the instant it's released")
        s.advance(tuning.closeDelay + 0.3)
        XCTAssertFalse(d.island.opened, "lingers, then closes")
    }

    // PT7: a self-opened alert stays open while the mouse moves away.
    func testPT7AlertStaysOpen() {
        let (d, s) = director()
        d.show(.incoming)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        s.advance(tuning.closeDelay + 0.3)
        XCTAssertEqual(d.mode, .card)
        XCTAssertEqual(d.island.activity?.id, .incoming)
    }

    // PT8: a click beside the open player closes it straight to the ears, with no preview on the way.
    func testPT8ClickOutsideClosesToTheEars() {
        let (d, _) = director()
        d.startMusic()
        openCard(d)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        d.clickOutside()
        XCTAssertFalse(d.island.opened)
        XCTAssertFalse(d.island.hovered)
        XCTAssertEqual(d.mode, .compact)
    }

    // PT9: a click on the volume or brightness HUD opens nothing.
    func testPT9HUDOpensNothing() {
        let (d, _) = director()
        d.startMusic()
        d.volumeUp()
        d.pointerDown(at: SIMD2(530, 18), hit: .ears)
        d.pointerUp(at: SIMD2(530, 18), hit: .ears, corridor: false)
        XCTAssertFalse(d.island.opened)
        XCTAssertEqual(d.mode, .hud)
    }

    // The corridor over the gap keeps the open card while the pointer travels down to it.
    func testCorridorKeepsTheCardOpen() {
        let (d, s) = director()
        d.startMusic()
        openCard(d)
        d.pointerMoved(hit: nil, corridor: true, buttonDown: false)
        s.advance(tuning.closeDelay + 0.3)
        XCTAssertTrue(d.island.opened)
    }

    // The preview lingers 0.3 s, the open card 1 s.
    func testLingerTimes() {
        let (d, s) = director()
        d.startMusic()
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .peek)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        s.advance(0.25)
        XCTAssertEqual(d.mode, .peek)
        s.advance(0.1)
        XCTAssertEqual(d.mode, .compact)
        openCard(d)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        s.advance(0.9)
        XCTAssertEqual(d.mode, .card)
        s.advance(0.2)
        XCTAssertEqual(d.mode, .compact)
    }

    // MEDIA1 (director side): clicking the bubble opens its owner's card.
    func testMEDIA1BubbleClickOpensItsCard() {
        let (d, _) = director()
        d.startMusic()
        d.show(.call, opened: false)
        XCTAssertEqual(d.mode, .duo)
        d.pointerMoved(hit: .bubble(0), corridor: false, buttonDown: false)
        d.pointerDown(at: SIMD2(600, 19), hit: .bubble(0))
        d.pointerUp(at: SIMD2(600, 19), hit: .bubble(0), corridor: false)
        XCTAssertEqual(d.mode, .card)
        XCTAssertEqual(d.island.cardOwner, .media)
        XCTAssertTrue(d.groups.player)
        XCTAssertFalse(d.groups.activityCard)
    }

    // REST1 (11-06): at rest the liquid covers the hardware notch (its corner too) with a point or two to spare, its
    // shoulders flare into the top edge, nothing hangs below, and the hover swell grows from it.
    func testREST1RestingNotch() throws {
        let renderer = try LiquidRenderer()
        let rest = targets().resting(.idle)
        XCTAssertEqual(rest.mainHalfWidth, nhw + tuning.idleGrow)
        XCTAssertEqual(rest.mainHeight, nh + tuning.idleDrop)
        // Still about the hardware notch's size (owner, 11-06: "the small before should still be the small now"), but
        // rounder (11-07: "too squary", then "still didn't smooth"): the ears' 18 pt corners, 2 pt wider each side and
        // lower so they still cover the notch's own.
        XCTAssertLessThanOrEqual(2 * rest.mainHalfWidth, 2 * nhw + 4)
        XCTAssertLessThanOrEqual(rest.mainHeight, nh + 2)
        XCTAssertEqual(rest.mainRadius, tuning.earRadius, "as round as the music's ears")
        XCTAssertEqual(rest.kBezel, tuning.idleBezel)
        XCTAssertGreaterThan(rest.mainRadius, tuning.notchRadius)
        var hover = TargetContext()
        hover.idleHover = true
        let h = targets(hover).resting(.idle)
        XCTAssertGreaterThan(h.mainHalfWidth, rest.mainHalfWidth)
        XCTAssertGreaterThan(h.mainHeight, rest.mainHeight)
        XCTAssertEqual(h.kBezel, rest.kBezel)

        let f = targets().restingFrame(.idle)
        let size = NotchSurfaceController.panelSize, w = Int(size.width), hgt = Int(size.height)
        let constants = SurfaceConstants(viewSize: SIMD2(Double(size.width), Double(size.height)), scale: 1,
                                         notchHalfWidth: nhw - 1, notchHeight: nh - 1, notchRadius: 9,
                                         cornerExponent: tuning.cornerExponent, kNotch: tuning.kNotch, kDrop: tuning.kDrop,
                                         edgeFeather: tuning.edgeFeather)
        let u = ShapeUniforms(state: f.state, neckRadius: f.neckRadius, dropRadii: f.dropRadii, constants: constants)
        let px = renderer.renderOffscreen(width: w, height: hgt, uniforms: u)
        let alpha = { (x: Double, y: Double) -> Int in Int(px[(Int(y) * w + Int(Double(w) / 2 + x)) * 4 + 3]) }
        let corner = nhw - tuning.notchRadius * (1 - 0.5.squareRoot()), cornerY = nh - tuning.notchRadius * (1 - 0.5.squareRoot())
        XCTAssertGreaterThan(alpha(-corner, cornerY), 230, "the hardware notch's corner stays inside")
        XCTAssertGreaterThan(alpha(corner, cornerY), 230)
        XCTAssertGreaterThan(alpha(nhw + tuning.idleGrow + 1.5, 0.5), 128, "the shoulder flares into the top edge")
        XCTAssertLessThan(alpha(0, nh + tuning.idleDrop + 2.5), 26, "nothing hangs below")
    }

    // CARD2 (11-06, owner): with a card open the notch behind it keeps the rounded resting shape, and a ball beside it
    // keeps hanging from the top edge (its shoulders stay flared; it came apart before).
    func testCARD2NotchBehindTheCard() {
        let rest = targets().resting(.idle), card = targets().resting(.card)
        XCTAssertEqual(card.mainHalfWidth, rest.mainHalfWidth)
        XCTAssertEqual(card.mainHeight, rest.mainHeight)
        XCTAssertEqual(card.mainRadius, rest.mainRadius)
        XCTAssertEqual(card.kBezel, tuning.idleBezel)
        var c = TargetContext()
        c.bubbleModes = [.card]
        let ball = targets(c).resting(.card)
        XCTAssertGreaterThan(ball.dropRadius, 0)
        XCTAssertGreaterThan(ball.kBezel, 0, "it hangs from the top edge")
        XCTAssertEqual(ball.mainHalfWidth, rest.mainHalfWidth, "beside the small notch, not the ears")
        XCTAssertEqual(ball.dropX, ball.mainHalfWidth + tuning.dropGap + tuning.dropRadius)
    }

    // REC1 (11-06): Record counts 3-2-1, then records; pressed again it stops, the file lands on the Shelf and the Saved
    // moment shows; pressed during the countdown it cancels; without the permission it opens Setup instead.
    func testREC1RecordFromTheNotch() async {
        let (d, s) = director()
        let fake = FakeRecorder()
        d.recorder = fake
        d.recordToggle()
        XCTAssertEqual(d.island.activity?.id, .recordCountdown)
        XCTAssertNil(fake.url)
        d.recordToggle()                                  // cancel
        XCTAssertTrue(d.island.running.isEmpty)
        s.advance(4)
        XCTAssertNil(fake.url)
        d.recordToggle()
        s.advance(3)
        XCTAssertEqual(d.island.activity?.id, .recording)
        for _ in 0..<20 where fake.url == nil { await Task.yield() }
        XCTAssertEqual(fake.url?.lastPathComponent.hasPrefix("Screen Recording "), true)
        XCTAssertEqual(d.recordState?.counting, false)
        d.recordToggle()                                  // stop
        for _ in 0..<40 where d.island.activity?.id != .recordingSaved { await Task.yield() }
        XCTAssertEqual(d.island.activity?.id, .recordingSaved)
        XCTAssertEqual(d.tray.files.first, fake.url)
        XCTAssertEqual(d.lastRecording.url, fake.url)
        XCTAssertNil(d.recordState)

        let (d2, _) = director()
        let locked = FakeRecorder()
        locked.canRecord = false
        d2.recorder = locked
        var setup = false
        d2.onNeedsSetup = { setup = true }
        d2.recordToggle()
        XCTAssertTrue(setup)
        XCTAssertTrue(d2.island.running.isEmpty)
    }

    func testRecordingFileName() {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 11, 6, 17, 42, 31)
        let date = Calendar.current.date(from: c)!
        XCTAssertEqual(IslandDirector.recordingURL(at: date).lastPathComponent, "Screen Recording 2026-11-06 at 17.42.31.mov")
    }

    // MENU1 (11-06): the island's part of the right-click menu: Hide what's under the pointer, then what's off the
    // island, then what's hidden with Show.
    func testMENU1RightClickModel() {
        let (d, _) = director()
        d.startMusic()
        d.show(.timer)
        XCTAssertEqual(d.menuEntries(at: .bubble(0)), [.hide(.activity, "Hide Timer"), .separator])
        d.hide(.activity)
        let entries = d.menuEntries(at: .ears)
        XCTAssertEqual(entries.first, .hide(.media, "Hide \(d.media.title)"))
        XCTAssertTrue(entries.contains(.header("Hidden")))
        XCTAssertTrue(entries.contains(.show(.activity, "Show Timer")))
        d.show(.download)
        XCTAssertTrue(d.menuEntries(at: .ears).contains { if case .open(_, "Download", _) = $0 { true } else { false } })
        d.stopMusic()
        for a in d.island.running { d.end(serial: a.serial) }
        XCTAssertEqual(d.menuEntries(at: nil), [], "the empty notch: only the app's items")
    }

    // BUB1 (11-06): a call while recording keeps the recording; two balls and the +N ball are drawn where the island
    // puts them, the hit test finds each, and the +N ball opens its list.
    func testBUB1BallsAndTheirCards() {
        let (d, _) = director()
        d.startMusic()
        d.show(.recording)
        d.show(.incoming, opened: false)
        d.perform(.accept)
        XCTAssertEqual(d.island.activity?.id, .call)
        XCTAssertEqual(d.island.background.map(\.id), [.recording])
        d.show(.timer)
        d.show(.camera)
        XCTAssertEqual(d.mode, .duo)
        let places = d.island.balls(.duo)
        XCTAssertEqual(places.compactMap { $0 }.count, 3)
        XCTAssertEqual(places[2], .more)
        var c = TargetContext()
        c.bubbleModes = Set(IslandCore.PresentationMode.allCases.filter { d.island.hasBubble($0) })
        c.leftBallModes = Set(IslandCore.PresentationMode.allCases.filter { d.island.balls($0)[1] != nil })
        c.moreModes = Set(IslandCore.PresentationMode.allCases.filter { d.island.balls($0)[2] != nil })
        c.activityHoldsEars = true
        let s = targets(c).resting(.duo)
        XCTAssertEqual(s.e1R, tuning.dropRadius)
        XCTAssertEqual(s.e2R, 13)
        XCTAssertLessThan(s.e1X, -nhw)
        XCTAssertGreaterThan(s.e2X, s.dropX + s.dropRadius + 12)
        let size = NotchSurfaceController.panelSize
        let constants = SurfaceConstants(viewSize: SIMD2(Double(size.width), Double(size.height)), scale: 1,
                                         notchHalfWidth: nhw - 1, notchHeight: nh - 1, notchRadius: 9,
                                         cornerExponent: tuning.cornerExponent, kNotch: tuning.kNotch, kDrop: tuning.kDrop,
                                         edgeFeather: tuning.edgeFeather)
        let u = ShapeUniforms(state: s, neckRadius: 0, dropRadii: SIMD2(s.dropRadius, s.dropRadius), constants: constants)
        let cx = Double(size.width) / 2
        XCTAssertEqual(ShapeSDF.hit(SIMD2(cx + s.dropX, s.dropY), u, earPad: 4), .bubble(0))
        XCTAssertEqual(ShapeSDF.hit(SIMD2(cx + s.e1X, s.dropY), u, earPad: 4), .bubble(1))
        XCTAssertEqual(ShapeSDF.hit(SIMD2(cx + s.e2X, s.dropY), u, earPad: 4), .bubble(2))
        XCTAssertLessThan(ShapeSDF.distance(SIMD2(cx + s.e1X, s.dropY), u), 0)
        d.pointerMoved(hit: .bubble(2), corridor: false, buttonDown: false)
        d.pointerDown(at: SIMD2(cx + s.e2X, s.dropY), hit: .bubble(2))
        d.pointerUp(at: SIMD2(cx + s.e2X, s.dropY), hit: .bubble(2), corridor: false)
        XCTAssertEqual(d.island.cardOwner, .more)
        XCTAssertTrue(d.groups.moreList)
        // A row opens that party's card in place; its buttons act on it, not on the call in the ears.
        let timer = d.island.background.first { $0.id == .timer }!
        d.openCard(.background(timer.serial))
        XCTAssertEqual(d.island.cardActivity?.id, .timer)
        d.perform(.cancelTimer)
        XCTAssertEqual(d.island.activity?.id, .call)
        XCTAssertFalse(d.island.running.contains { $0.id == .timer })
    }

    // A transient leaves on its own, but never while its card is open; closing gives it two more seconds.
    func testTransientTiming() {
        let (d, s) = director()
        d.show(.airpods)
        s.advance(4.9)
        XCTAssertEqual(d.island.activity?.id, .airpods)
        s.advance(0.2)
        XCTAssertNil(d.island.activity)

        d.show(.charging)
        openCard(d)
        s.advance(10)
        XCTAssertEqual(d.island.activity?.id, .charging)
        d.clickOutside()
        s.advance(1.9)
        XCTAssertEqual(d.island.activity?.id, .charging)
        s.advance(0.2)
        XCTAssertNil(d.island.activity)
    }

    // HUD hands back after 1.4 s.
    func testHUDHandsBack() {
        let (d, s) = director()
        d.startMusic()
        d.show(.timer)
        d.brightnessUp()
        XCTAssertEqual(d.mode, .hud)
        s.advance(1.5)
        XCTAssertEqual(d.mode, .duo)
    }

    // CLK1: clocks follow elapsed time, not the number of ticks.
    func testCLK1ClocksFollowTime() {
        let d = IslandDirector()
        d.schedule = ManualScheduler().schedule
        var t = 100.0
        d.clock = { t }
        d.show(.call, opened: false)
        d.tick()
        let t0 = d.samples.callSeconds
        for _ in 0..<4 { d.tick() }
        XCTAssertEqual(d.samples.callSeconds, t0)
        t += 2
        d.tick()
        XCTAssertEqual(d.samples.callSeconds, t0 + 2, accuracy: 1e-9)
    }

    // A track skip swaps in place: the player stays up, nothing pulses.
    func testTrackSkipSwapsInPlace() {
        let (d, _) = director()
        var pulses = 0
        d.onPulse = { _ in pulses += 1 }
        d.startMusic()
        openCard(d)
        pulses = 0
        let before = d.trackIndex
        d.nextTrack()
        XCTAssertNotEqual(d.trackIndex, before)
        XCTAssertTrue(d.groups.player && d.groups.musicEars)
        XCTAssertEqual(pulses, 0)
    }

    // MARK: - Real Now Playing (P2)

    private func song(_ title: String = "Night Ferry", playing: Bool = true, bundle: String = "com.spotify.client") -> NowPlaying {
        NowPlaying(title: title, artist: "The Low Tides", bundleID: bundle, playing: playing, duration: 200,
                   elapsed: 30, timestamp: Date(timeIntervalSince1970: 1000))
    }

    // Like iPhone, a paused song stays until its player quits (owner, 11-01), even paused at launch.
    func testPausedMediaStaysUntilThePlayerQuits() {
        let (d, s) = director()
        d.nowPlayingChanged(song())
        XCTAssertEqual(d.mode, .compact)
        XCTAssertEqual(d.media.title, "Night Ferry")
        XCTAssertEqual(d.island.mediaApp, "com.spotify.client")
        d.nowPlayingChanged(song(playing: false))
        s.advance(3600)
        XCTAssertEqual(d.mode, .compact)
        XCTAssertFalse(d.playing)
        d.nowPlayingChanged(nil)
        s.advance(IslandDirector.settle + 0.2)
        XCTAssertEqual(d.mode, .idle)
    }

    // A web player's skip: title, artist and cover arrive in pieces, with a "nothing" blip between. The island
    // never closes, the text changes once, and the old cover stays until the new one arrives.
    func testSkipArrivesInPieces() {
        let (d, s) = director()
        func png(_ size: Int) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }
        var a = song("First"); a.artwork = png(1)
        d.nowPlayingChanged(a)
        let firstArt = d.media.artKey
        d.nowPlayingChanged(nil)
        s.advance(0.3)
        XCTAssertEqual(d.mode, .compact, "a nothing blip doesn't close the island")
        var b = song("Second"); b.artist = ""
        d.nowPlayingChanged(b)
        let textKey = d.media.id
        XCTAssertEqual(d.media.artKey, firstArt, "the old cover stays while the new one is on its way")
        b.artist = "The Low Tides"
        d.nowPlayingChanged(b)
        XCTAssertEqual(d.media.id, textKey, "the artist arriving doesn't restart the text crossfade")
        s.advance(0.5)
        b.artwork = png(2)
        d.nowPlayingChanged(b)
        XCTAssertNotEqual(d.media.artKey, firstArt)
        s.advance(5)
        XCTAssertEqual(d.mode, .compact)
    }

    func testPausedAtLaunchShows() {
        let (d, _) = director()
        d.nowPlayingChanged(song(playing: false))
        XCTAssertEqual(d.mode, .compact)
    }

    // The player quitting takes media off at once (content first, then the liquid).
    func testNothingPlayingHides() {
        let (d, s) = director()
        d.nowPlayingChanged(song())
        d.nowPlayingChanged(nil)
        s.advance(IslandDirector.settle + 0.2)
        XCTAssertEqual(d.mode, .idle)
    }

    // Controls go to the player; play/pause answers at once.
    func testCommandsGoToThePlayer() {
        let (d, _) = director()
        var sent: [MediaCommand] = []
        d.sendCommand = { sent.append($0) }
        d.nowPlayingChanged(song())
        d.togglePlaying()
        XCTAssertFalse(d.playing)
        d.nextTrack(1)
        d.nextTrack(-1)
        XCTAssertEqual(sent, [.togglePlayPause, .next, .previous])
    }

    // Elapsed time comes from (elapsed, timestamp, rate).
    func testRealElapsed() {
        let (d, _) = director()
        d.date = { Date(timeIntervalSince1970: 1012) }
        d.nowPlayingChanged(song())
        XCTAssertEqual(d.elapsed, 42, accuracy: 1e-9)
    }

    // The player's own app in front takes media off the island.
    func testPlayerInFrontHidesMedia() {
        let (d, _) = director()
        d.nowPlayingChanged(song())
        d.setContext(DesktopContext(frontmostApp: "com.spotify.client"))
        XCTAssertEqual(d.mode, .idle)
    }

    // The sample music takes over from the real feed and hands it back when stopped.
    func testSamplesTakeOverAndHandBack() {
        let (d, _) = director()
        d.nowPlayingChanged(song())
        d.startMusic()
        XCTAssertNotNil(d.media.sample)
        d.stopMusic()
        XCTAssertEqual(d.media.title, "Night Ferry")
        XCTAssertEqual(d.mode, .compact)
    }

    // REPLY1: Messages replies in place; sending clears the notification, an empty reply doesn't.
    func testREPLY1ReplyInPlace() {
        let (d, _) = director()
        d.show(.messages, opened: true)
        d.perform(.send("  "))
        XCTAssertEqual(d.island.activity?.id, .messages)
        d.perform(.send("On my way!"))
        XCTAssertNil(d.island.activity)
    }

    // Typing a reply holds the card open.
    func testReplyFocusHoldsTheCard() {
        let (d, s) = director()
        d.show(.messages)
        openCard(d)
        d.replyFocused = true
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        s.advance(5)
        XCTAssertTrue(d.island.opened)
    }

    // RM: Reduce Motion: no jolts and no choreography, one quick move.
    func testReduceMotion() {
        let (d, _) = director()
        var kicks = 0
        d.onKick = { _ in kicks += 1 }
        d.reduceMotion = { true }
        d.show(.charging)
        d.perform(.mute)
        XCTAssertEqual(kicks, 0)
        let (first, stages) = targets().transition(from: .idle, to: .compact, reduceMotion: true)
        XCTAssertTrue(stages.isEmpty)
        XCTAssertEqual(first, targets().resting(.compact))
    }

    // MNT1: an activity's entrance runs once: Charging jolts on plug-in, not again when its card opens.
    func testMNT1ChargingJoltsOnce() {
        let (d, s) = director()
        var kicks = 0
        d.onKick = { _ in kicks += 1 }
        d.show(.charging)
        s.advance(0.3)
        openCard(d)
        s.advance(0.5)
        XCTAssertEqual(kicks, 1)
    }

    // MARK: - Layout

    // BAL1: every card fits its content with even space above and below: height = content + 28.
    func testBAL1CardsAreBalanced() {
        let d = IslandDirector()
        d.schedule = ManualScheduler().schedule
        var report: [String] = []
        for id in ActivityID.allCases where !id.earsOnly {   // the lock moments have no card
            // Since 11-06 a new activity no longer replaces the last one (they all keep going): end them first.
            for a in d.island.running { d.end(serial: a.serial) }
            d.show(id, opened: true)
            let spec = ActivitySpec[id]
            let inset = spec.padding
            let side = id == .incoming ? 20.0 : 18.0
            let view = ActivityCard(instance: d.island.activity!, director: d)
                .frame(width: spec.card.width - 2 * side)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.islandMotion, IslandMotion(reduce: true, stills: true))
            let host = NSHostingView(rootView: view)
            let content = Double(host.fittingSize.height)
            let want = spec.card.height - 2 * inset
            report.append("\(id.rawValue): content \(content), room \(want)")
            XCTAssertLessThanOrEqual(content, want + 0.5, "\(id) overflows its card")
            XCTAssertGreaterThanOrEqual(content, want - 6, "\(id) leaves more than 3 pt extra above and below")
        }
        print("BAL1\n" + report.joined(separator: "\n"))
    }

    // HID1: with an activity's card open, nothing of the player shows (its controls can't take clicks).
    func testHID1OnlyTheOpenCardTakesHits() {
        for id in ActivityID.allCases {
            var i = Island()
            i.apply(.startMedia)
            i.apply(.show(id, opened: true))
            let g = i.groups(.card)
            XCTAssertTrue(g.activityCard, "\(id)")
            XCTAssertFalse(g.player || g.peek || g.activityEars || g.hud, "\(id)")
        }
    }
}

/// Records nothing; says where it would have.
@MainActor
final class FakeRecorder: ScreenRecording {
    var canRecord = true
    var url: URL?
    func start(to url: URL) async throws { self.url = url }
    func stop() async throws -> URL { url ?? URL(fileURLWithPath: "/tmp/none.mov") }
}
