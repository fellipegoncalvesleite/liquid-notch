import Foundation

/// The song's beat, from its onsets (`AudioSpectrum.onset`, one per analysis frame), for the menu bar strip's glow
/// (owner, 11-07: "its just not recognizing beats properly … try being smart about it"). Reacting to loud moments lit
/// the glow on vocals and swells and missed soft songs' beats; this finds the beat grid and predicts it, so the glow lands
/// on every beat, even a quiet one, and can be timed to when you hear it (`DesktopColors.audioFrame`).
///
/// Every half second, over the last 10 s of onsets (high-passed, so only what stands out counts):
/// - Candidates: the three best peaks of the autocorrelation between 60 and 180 BPM (each lag helped by its double and
///   triple: a real beat repeats), with twice and half of each.
/// - Each candidate's best grid: the onsets summed at every beat back from now, over periods ±2% and offsets a quarter
///   of a frame apart, recent beats counting most. The grid whose beats stand out most from the average moment
///   (`salience`) wins, a gentle preference for ~110 BPM breaking near-ties.
/// - Steadiness: a different tempo must win three estimates in a row to replace the one held (a fill or a break doesn't
///   throw it).
/// - Lock (the glow follows only then): the beats stand out (`lockSalience`), the tempo clearly beats any unrelated one
///   (`lockDistinct`), most beats land on a clear onset (`lockHits`), and it has won four estimates in a row.
///
/// Measured on Photos' beat-annotated soundtracks (17 songs and loops, `BeatTrackerTests`): 90% of the glows within
/// 70 ms of a beat (94–100% on drum-driven pieces); beatless strings and lo-fi rarely lock, so they stay dark. ~0.3 ms
/// an estimate. Pure: times are the caller's clock, in seconds.
struct BeatTracker {
    /// Frames a second.
    let rate: Double
    /// Seconds of onsets kept.
    static let window = 10.0
    /// Faster beats than this (s) light every other one (a glow at more than ~2.4 a second would flicker).
    static let fastest = 0.42

    private var env: [Double] = []
    private var mean = 0.0
    private var last = 0.0
    private var frames = 0
    private var candidate: (period: Double, count: Int)?
    /// Estimates in a row whose winning tempo agreed (within 3%) with the one before.
    private var steady = 0
    /// The winner's value over the best unrelated tempo's (`lockDistinct`).
    private(set) var distinct = 0.0
    /// The share of the grid's beats (over the window) with an onset at least twice the average at them (`lockHits`).
    private(set) var hits = 0.0

    /// The beat's period (s), a beat's time, how clearly it stands out (0…1, from `salience`), and whether it's trusted.
    private(set) var period: Double?
    private(set) var anchor: Double?
    private(set) var confidence = 0.0
    private(set) var locked = false
    /// How much the chosen grid's beats stand out from the average moment (`lockSalience`).
    private(set) var salience = 0.0
    /// The glow's own grid: every beat, or every other one (the stronger half) when they come faster than `fastest`.
    private(set) var pulsePeriod: Double?
    private(set) var pulseAnchor: Double?

    init(rate: Double = 30) { self.rate = rate }

    var bpm: Double? { period.map { 60 / $0 } }

    /// One frame's onset strength at `t`.
    mutating func feed(_ onset: Double, at t: Double) {
        // High-pass: what stands above the last ~0.6 s.
        mean += (onset - mean) * (1 - exp(-1 / (rate * 0.6)))
        env.append(max(onset - mean, 0))
        let keep = Int(Self.window * rate)
        if env.count > keep { env.removeFirst(env.count - keep) }
        last = t
        frames += 1
        if frames % max(Int(rate / 2), 1) == 0, env.count >= Int(3 * rate) { estimate() }
    }

    /// The next beat to light after `t`, in the caller's clock.
    func nextPulse(after t: Double) -> Double? {
        guard locked, let p = pulsePeriod, let a = pulseAnchor else { return nil }
        return a + (((t - a) / p).rounded(.down) + 1) * p
    }

    // MARK: - Estimating

    private mutating func estimate() {
        // Candidates: the autocorrelation's best peaks, and twice and half of each; each one's best grid is laid over
        // the onsets, and the grid whose beats stand out most from the average moment wins, a gentle preference for
        // ~110 BPM breaking near-ties. (3/2 and 2/3 too pulled songs to a dotted tempo.)
        let peaks = tempoPeaks()
        guard !peaks.isEmpty else { return lose() }
        var candidates: [Double] = []
        for p in peaks { for k in [1.0, 2.0, 0.5] { candidates.append(p * k) } }
        if let p = period { candidates.append(p) }
        candidates = candidates.filter { (0.333...1.0).contains($0) }
        let mean = max(env.reduce(0, +) / Double(env.count), 1e-9)
        var best: (p: Double, offset: Double, salience: Double, value: Double)?
        var all: [(p: Double, value: Double)] = []
        for c in candidates {
            guard let (p, offset, score, _) = grid(around: c, spread: 0.02) else { continue }
            let salience = score / beatWeights(period: p) / mean
            // A held tempo gets a little help (steadiness), the ~110 BPM prior breaks near-ties.
            let held = period.map { abs(p / $0 - 1) < 0.04 ? 1.08 : 1 } ?? 1
            let value = salience * prior(p) * held
            all.append((p, value))
            if best == nil || value > best!.value { best = (p, offset, salience, value) }
        }
        guard let best else { return lose() }
        // How clearly it wins against the best tempo that isn't it, its double or its half: a real beat stands alone;
        // random hits make many tempos about as good.
        func related(_ a: Double, _ b: Double) -> Bool { [1.0, 2.0, 0.5].contains { abs(a / (b * $0) - 1) < 0.05 } }
        let rival = all.filter { !related($0.p, best.p) }.map(\.value).max() ?? 0
        distinct = rival > 0 ? best.value / rival : 2
        let agrees = period.map { related(best.p, $0) && abs(best.p / $0 - 1) < 0.03 } ?? false
        steady = agrees ? steady + 1 : 0
        // Steady: a near tempo blends in; a different one must win three estimates in a row.
        var p = best.p, offset = best.offset
        if let old = period, abs(p / old - 1) >= 0.04 {
            let count = candidate.map { abs($0.period / p - 1) < 0.04 ? $0.count + 1 : 1 } ?? 1
            candidate = (p, count)
            if count < 3, let kept = grid(around: old, spread: 0.01) { (p, offset) = (kept.0, kept.1) } else { candidate = nil }
        } else {
            candidate = nil
        }
        period = p
        anchor = last - offset - Self.lag
        hits = hitRate(period: p, offset: offset, mean: mean)
        salience = best.salience
        confidence = min(max((salience - 3) / 3, 0), 1)
        locked = salience >= (locked ? Self.unlockSalience : Self.lockSalience) && distinct >= Self.lockDistinct
            && hits >= Self.lockHits && candidate == nil && steady >= Self.steadyToLock
        if p < Self.fastest, let a = anchor {
            // Every other beat: the half with more onsets.
            let even = score(period: 2 * p, offset: offset), odd = score(period: 2 * p, offset: offset + p)
            pulsePeriod = 2 * p
            pulseAnchor = even >= odd ? a : a - p
        } else {
            pulsePeriod = p
            pulseAnchor = anchor
        }
    }

    /// An onset shows in the frame after it on average (frames 33 ms apart, a window ending at the frame): the grid is
    /// set this much earlier (measured on Photos' soundtracks: +25 ms late without it).
    static let lag = 0.025

    /// The share of beats that must land on a clear onset (a real beat: most; random hits: a third at best).
    static let lockHits = 0.5

    /// How clearly the winning tempo must beat the best unrelated one to lock.
    static let lockDistinct = 1.15

    /// Estimates in a row (half a second apart) the winning tempo must agree before the glow follows it.
    static let steadyToLock = 4

    /// How far the grid's beats must stand above the average moment to lock, and to stay locked. On Photos' soundtracks
    /// (17 pieces, songs and loops, beat-annotated), glows with salience over 3.8 were 83% on a beat, over 4.9 89%; the
    /// beats against the off-beats told nothing (a high ratio is often a sparse, wrong grid).
    static let lockSalience = 4.3, unlockSalience = 3.7

    private mutating func lose() {
        locked = false
        confidence = 0
    }

    /// The share of the beats at `period`, `offset` back over the window whose frame (or a neighbour) has an onset at
    /// least twice `mean`.
    private func hitRate(period: Double, offset: Double, mean: Double) -> Double {
        let n = env.count
        var beats = 0.0, hit = 0.0, back = offset
        while back < Double(n - 2) / rate {
            let i = Int((Double(n - 1) - back * rate).rounded())
            let near = env[max(i - 1, 0)...min(i + 1, n - 1)].max() ?? 0
            beats += 1
            if near >= 2 * mean { hit += 1 }
            back += period
        }
        return beats > 0 ? hit / beats : 0
    }

    /// The sum of the weights `score` gives the beats at `period` (to compare periods fairly).
    private func beatWeights(period: Double) -> Double {
        var w = 0.0, weight = 1.0, back = 0.0
        while back < Double(env.count - 1) / rate { w += weight; weight *= 0.9; back += period }
        return w
    }

    /// A gentle preference for ~110 BPM (log-normal, 1.2 octaves wide).
    private func prior(_ period: Double) -> Double {
        let octaves = log2(period / 0.55) / 1.2
        return exp(-0.5 * octaves * octaves)
    }

    /// The periods (s) of the comb-helped autocorrelation's three best peaks, each refined between lags.
    private func tempoPeaks() -> [Double] {
        let n = env.count
        let m = env.reduce(0, +) / Double(n)
        let x = env.map { $0 - m }
        let minLag = max(Int((0.333 * rate).rounded(.down)), 2), maxLag = min(Int((1.0 * rate).rounded(.up)), n / 3)
        guard maxLag > minLag + 2 else { return [] }
        var acf = [Double](repeating: 0, count: 3 * maxLag + 2)
        for lag in 0...min(3 * maxLag + 1, n - 1) {
            var s = 0.0
            for i in lag..<n { s += x[i] * x[i - lag] }
            acf[lag] = s / Double(n - lag)
        }
        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in max(minLag - 1, 1)...(maxLag + 1) where 3 * lag < acf.count {
            scores[lag] = max(acf[lag] + 0.5 * acf[2 * lag] + 0.33 * acf[3 * lag], 0)
        }
        let peaks = (minLag...maxLag).filter { scores[$0] > 0 && scores[$0] >= scores[$0 - 1] && scores[$0] >= scores[$0 + 1] }
            .sorted { scores[$0] > scores[$1] }.prefix(3)
        return peaks.map { lag in
            let a = scores[lag - 1], b = scores[lag], c = scores[lag + 1]
            let d = a - 2 * b + c
            return (Double(lag) + (d < 0 ? min(max(0.5 * (a - c) / d, -0.5), 0.5) : 0)) / rate
        }
    }

    /// The best grid near `period`: its period, how long ago its last beat was (s), its score and the average score of
    /// every offset at that period.
    private func grid(around period: Double, spread: Double) -> (Double, Double, Double, Double)? {
        var best: (p: Double, offset: Double, score: Double)?
        var averageAtBest = 0.0
        let step = 1 / (rate * 4)
        for i in -4...4 {
            let p = period * (1 + spread * Double(i) / 4)
            var total = 0.0, count = 0.0
            var top: (offset: Double, score: Double) = (0, -1)
            var offset = 0.0
            while offset < p {
                let s = score(period: p, offset: offset)
                total += s; count += 1
                if s > top.score { top = (offset, s) }
                offset += step
            }
            if best == nil || top.score > best!.score {
                best = (p, top.offset, top.score)
                averageAtBest = total / max(count, 1)
            }
        }
        guard let best, best.score > 0 else { return nil }
        return (best.p, best.offset, best.score, averageAtBest)
    }

    /// The onsets summed at beats `offset`, `offset + period`, … seconds before the newest frame, each beat back
    /// counting 0.9 of the one after it, read between frames.
    private func score(period: Double, offset: Double) -> Double {
        let n = env.count
        var s = 0.0, weight = 1.0, back = offset
        while back < Double(n - 1) / rate {
            let x = Double(n - 1) - back * rate
            let i = Int(x), f = x - Double(i)
            s += weight * (env[i] * (1 - f) + (i + 1 < n ? env[i + 1] : env[i]) * f)
            weight *= 0.9
            back += period
        }
        return s
    }
}
