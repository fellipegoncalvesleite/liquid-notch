import XCTest
@testable import LiquidNotch

/// The music bars' analysis (11-06): a tone lights its own bar, quiet and loud songs move the bars alike, levels rise
/// fast and fall slower, and silence stays at the floor.
final class AudioSpectrumTests: XCTestCase {
    private let rate = 48_000.0

    /// `seconds` of a sine at `hz` and `amplitude`, fed in 1024-sample frames at 30 frames a second.
    private func feed(_ s: inout AudioSpectrum, hz: Double, amplitude: Float, seconds: Double, phase: inout Double) -> [Float] {
        var frame = [Float](repeating: 0, count: s.size)
        var levels: [Float] = []
        for _ in 0..<Int(seconds * 30) {
            for i in 0..<s.size {
                frame[i] = amplitude * Float(sin(phase))
                phase += 2 * .pi * hz / rate
            }
            levels = frame.withUnsafeBufferPointer { s.process($0, dt: 1.0 / 30) }
        }
        return levels
    }

    /// A seeded generator, so every run sees the same noise.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // ONSET1 (the strip's beat, 11-07): a drum hit (a burst of low noise) in silence gives a clear onset in its frame
    // and much less in the frames after it, while it rings (seen: 0.78, then 0.17 and under 0.05).
    func testONSET1AHitStandsOut() {
        var s = AudioSpectrum(sampleRate: rate)
        var rng = Seeded(state: 5)
        var onsets: [Float] = []
        var frame = [Float](repeating: 0, count: s.size)
        for i in 0..<30 {
            for j in 0..<s.size {
                // A decaying burst from frame 10: noise through a one-pole low-pass (a kick-like thump).
                let since = i - 10
                frame[j] = since >= 0 ? Float.random(in: -1...1, using: &rng) * 0.6 * exp(-Float(since) / 2) : 0
                if j > 0 { frame[j] = 0.7 * frame[j - 1] + 0.3 * frame[j] }
            }
            _ = frame.withUnsafeBufferPointer { s.process($0, dt: 1.0 / 30) }
            onsets.append(s.onset)
        }
        XCTAssertGreaterThan(onsets[10], 3 * (onsets[11...].max() ?? 0), "\(onsets)")
        XCTAssertEqual(onsets[5], 0, "silence")
    }

    func testEachToneLightsItsOwnBar() {
        for (hz, bar) in [(100.0, 0), (500.0, 1), (2_000.0, 2), (6_000.0, 3)] {
            var s = AudioSpectrum(sampleRate: rate)
            var phase = 0.0
            let levels = feed(&s, hz: hz, amplitude: 0.5, seconds: 1, phase: &phase)
            XCTAssertEqual(levels.indices.max { levels[$0] < levels[$1] }, bar, "\(hz) Hz: \(levels)")
        }
    }

    // The gain follows the loudness: a song 30 dB quieter moves the bars about as much, and a loud one doesn't pin them.
    func testQuietAndLoudMoveAlike() {
        var phase = 0.0
        var loud = AudioSpectrum(sampleRate: rate), quiet = AudioSpectrum(sampleRate: rate)
        let l = feed(&loud, hz: 500, amplitude: 0.9, seconds: 6, phase: &phase)
        let q = feed(&quiet, hz: 500, amplitude: 0.9 / 31.6, seconds: 6, phase: &phase)
        XCTAssertEqual(l[1], q[1], accuracy: 0.12)
        XCTAssertLessThan(l[1], 0.97, "a steady loud song isn't pinned at the top")
        XCTAssertGreaterThan(q[1], 0.5, "a quiet song still moves")
    }

    func testRisesFastFallsSlower() {
        var s = AudioSpectrum(sampleRate: rate)
        var phase = 0.0
        _ = feed(&s, hz: 500, amplitude: 0.5, seconds: 2, phase: &phase)
        let up = feed(&s, hz: 500, amplitude: 0, seconds: 0.1, phase: &phase)   // 3 frames of silence
        XCTAssertGreaterThan(up[1], 0.3, "it falls slowly")
        var t = AudioSpectrum(sampleRate: rate)
        _ = feed(&t, hz: 500, amplitude: 0.5, seconds: 2, phase: &phase)
        _ = feed(&t, hz: 500, amplitude: 0, seconds: 1.5, phase: &phase)
        let rise = feed(&t, hz: 500, amplitude: 0.5, seconds: 0.1, phase: &phase)
        XCTAssertGreaterThan(rise[1], 0.6, "it rises within 0.1 s")
    }

    func testSilenceStaysAtTheFloor() {
        var s = AudioSpectrum(sampleRate: rate)
        var phase = 0.0
        let levels = feed(&s, hz: 500, amplitude: 0, seconds: 4, phase: &phase)
        XCTAssertTrue(levels.allSatisfy { $0 >= 0 && $0 < 0.02 && !$0.isNaN }, "\(levels)")
        XCTAssertTrue(s.silent)
        let hiss = feed(&s, hz: 9_000, amplitude: 0.00002, seconds: 3, phase: &phase)
        XCTAssertTrue(hiss.allSatisfy { $0 < 0.1 }, "noise far below music isn't blown up: \(hiss)")
        XCTAssertFalse(s.silent, "not digital silence")
    }
}
