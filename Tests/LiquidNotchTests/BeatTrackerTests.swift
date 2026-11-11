import XCTest
@testable import LiquidNotch

/// The menu bar strip's beat (owner, 11-07: "its just not recognizing beats properly … try being smart about it"): the
/// tracker finds the beat grid from onsets and predicts it; it stays quiet when there's no beat. Tuned on Photos'
/// beat-annotated soundtracks (17 pieces, songs and loops): 90% of its glows within 70 ms of a beat, 94–100% on
/// drum-driven ones.
final class BeatTrackerTests: XCTestCase {
    private let rate = 30.0

    /// A seeded generator, so every run sees the same noise.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Onsets at `rate` frames a second for `seconds` from `start`: 1 in the frame of each beat of `bpm`, a little noise
    /// elsewhere, and quieter off-beats when `offBeats`; `onPulse` gets the time and the next predicted glow while locked.
    private func run(_ t: inout BeatTracker, bpm: Double, seconds: Double, from start: Double = 0, offBeats: Bool = false,
                     onPulse: (Double, Double) -> Void = { _, _ in }) {
        var rng = Seeded(state: 7)
        let period = 60 / bpm
        var frame = Int(start * rate)
        while Double(frame) / rate < start + seconds {
            let time = Double(frame) / rate
            let phase = (time / period).truncatingRemainder(dividingBy: 1)
            var onset = Double.random(in: 0...0.08, using: &rng)
            if phase * period < 1 / rate { onset += 1 }
            if offBeats, abs(phase - 0.5) * period < 0.5 / rate { onset += 0.35 }
            t.feed(onset, at: time)
            if t.locked, let p = t.nextPulse(after: time) { onPulse(time, p) }
            frame += 1
        }
    }

    // BT1: a steady 120 BPM with off-beat hi-hats locks within 5 s at 120, its predicted glows on the beats (within 40
    // ms, the frames being 33 ms apart).
    func testBT1LocksOnASteadyBeat() {
        var t = BeatTracker(rate: rate)
        var lockedBy: Double?
        var worst = 0.0
        run(&t, bpm: 120, seconds: 20, offBeats: true) { now, pulse in
            if lockedBy == nil { lockedBy = now }
            guard now > 8 else { return }
            let off = (pulse / 0.5 - (pulse / 0.5).rounded()) * 0.5
            worst = max(worst, abs(off))
        }
        XCTAssertNotNil(lockedBy)
        XCTAssertLessThanOrEqual(lockedBy ?? 99, 5)
        XCTAssertEqual(t.bpm ?? 0, 120, accuracy: 2)
        XCTAssertLessThanOrEqual(worst, 0.04, "on the beat, not the off-beat")
    }

    // BT2: a fast beat (170 BPM) lights every other one, never more than ~2.4 glows a second.
    func testBT2FastBeatsLightEveryOther() {
        var t = BeatTracker(rate: rate)
        run(&t, bpm: 170, seconds: 15)
        XCTAssertTrue(t.locked)
        XCTAssertEqual(t.pulsePeriod ?? 0, 2 * 60 / 170, accuracy: 0.02)
    }

    // BT3: onsets with no beat (random hits, ~2 a second) rarely lock: no glow rather than a wrong one (under 10% of the
    // time across seeds; 10–22% before the hit-rate rule).
    func testBT3NoBeatNoGlow() {
        var t = BeatTracker(rate: rate)
        var rng = Seeded(state: 11)
        var lockedFrames = 0
        for frame in 0..<Int(30 * rate) {
            t.feed(Double.random(in: 0...1, using: &rng) < 0.06 ? 1 : Double.random(in: 0...0.08, using: &rng), at: Double(frame) / rate)
            if t.locked { lockedFrames += 1 }
        }
        XCTAssertLessThan(Double(lockedFrames) / (30 * rate), 0.1)
    }

    // BT5 (11-07: the main thread hung at 100% once a beat locked: the scheduler asked for a beat after `-infinity`
    // and got `-infinity` back forever): from a cold start the glows due now are finite, ahead of now, within the
    // next 0.15 s, at most three, and asking again from the last one lit never repeats it.
    func testBT5SchedulingAlwaysMovesOn() {
        var t = BeatTracker(rate: rate)
        var now = 0.0
        run(&t, bpm: 120, seconds: 12) { time, _ in now = time }
        XCTAssertTrue(t.locked)
        let latency = 0.17
        var after = -Double.infinity
        var lit: [Double] = []
        for step in 0..<30 {
            let at = now + Double(step) / rate
            let due = DesktopColors.dueBeats(t, after: after, now: at, latency: latency)
            XCTAssertLessThanOrEqual(due.count, 3)
            for beat in due {
                XCTAssertTrue(beat.isFinite)
                XCTAssertGreaterThan(beat + latency, at - 0.021, "never one already heard")
                XCTAssertLessThan(beat + latency - at, 0.15)
                XCTAssertFalse(lit.contains { abs($0 - beat) < 0.01 }, "never twice")
            }
            lit += due
            if let last = due.last { after = last }
        }
        XCTAssertGreaterThanOrEqual(lit.count, 1, "a second at 120 BPM lights about two beats")
    }

    // BT4: the tempo changes (100 → 130 BPM): the tracker follows within 8 s and doesn't flip on a single estimate.
    func testBT4FollowsATempoChange() {
        var t = BeatTracker(rate: rate)
        run(&t, bpm: 100, seconds: 20)
        XCTAssertEqual(t.bpm ?? 0, 100, accuracy: 2)
        run(&t, bpm: 130, seconds: 8, from: 20)
        XCTAssertEqual(t.bpm ?? 0, 130, accuracy: 3)
        XCTAssertTrue(t.locked)
    }
}
