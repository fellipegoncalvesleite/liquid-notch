import Accelerate

/// The music bars' analysis (owner, 11-06: "driven by the actual audio playing on the Mac"): a Hann-windowed FFT of the
/// latest 1024 samples, grouped into one log-spaced band per bar (60 Hz to 12 kHz), each band in dB against a gain that
/// slowly follows the music's loudness (a quiet song moves the bars as much as a loud one, and a loud one doesn't pin
/// them), then a fast attack and a slower decay. Every buffer is allocated once; `process` allocates only its result.
struct AudioSpectrum {
    let size = 1024
    let bars: Int
    /// The span below the followed loudness that a bar covers, and the headroom above it, in dB.
    var range: Float = 30
    var headroom: Float = 5
    /// Attack and decay time constants (s): bars jump up, ease down.
    var attack: Float = 0.03
    var decay: Float = 0.2
    /// How fast the followed loudness rises and falls (s), and where it stops falling (dB, so hiss isn't blown up).
    var followRise: Float = 0.25
    var followFall: Float = 3
    var floor: Float = -72

    /// The last frame was all exact zeros (what a denied permission delivers).
    private(set) var silent = true
    private(set) var levels: [Float]
    /// How much new sound the last frame brought (the strip's beat tracking, `BeatTracker`): spectral flux, each bin's
    /// rise in log-compressed magnitude since the frame before, averaged within eight log-spaced bands from 40 Hz to
    /// 11 kHz and the bands weighed alike, the two lowest (the kick, the bass) twice and the next one and a half. A drum
    /// hit, a strum or a new chord rises at once; a held note doesn't. Summed over bins instead, the hundreds of
    /// high bins let off-beat hi-hats outweigh the kick, and a third of the glows landed between the beats.
    private(set) var onset: Float = 0
    /// log(1 + γ·magnitude): γ sets how much quiet bins count against loud ones.
    var compress: Float = 100
    private var previousLog: [Float]
    private let onsetBands: [ClosedRange<Int>]
    private static let onsetWeights: [Float] = [2, 2, 1.5, 1, 1, 1, 1, 1]

    private let log2n: vDSP_Length
    private let fft: Setup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private let bands: [Range<Int>]
    private var follow: Float
    private var bandDB: [Float]

    init(sampleRate: Double, bars: Int = 4, low: Double = 60, high: Double = 12_000) {
        self.bars = bars
        log2n = vDSP_Length(log2(Double(1024)))
        fft = Setup(log2n)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: 1024)
        real = [Float](repeating: 0, count: 512)
        imag = [Float](repeating: 0, count: 512)
        power = [Float](repeating: 0, count: 512)
        // Log-spaced edges, each band at least one bin wide.
        let binHz = sampleRate / 1024
        var edges: [Int] = (0...bars).map { k in
            Int((low * pow(high / low, Double(k) / Double(bars)) / binHz).rounded())
        }
        for k in 1..<edges.count { edges[k] = min(max(edges[k], edges[k - 1] + 1), 511) }
        edges[0] = max(edges[0], 1)
        bands = (0..<bars).map { edges[$0]..<max(edges[$0 + 1], edges[$0] + 1) }
        levels = [Float](repeating: 0, count: bars)
        bandDB = [Float](repeating: -120, count: bars)
        follow = floor
        previousLog = [Float](repeating: 0, count: 512)
        var onsetEdges = (0...8).map { k in Int((40 * pow(11_000 / 40, Double(k) / 8) / binHz).rounded()) }
        onsetEdges[0] = max(onsetEdges[0], 1)
        for k in 1..<onsetEdges.count { onsetEdges[k] = min(max(onsetEdges[k], onsetEdges[k - 1] + 1), 511) }
        onsetBands = (0..<8).map { onsetEdges[$0]...max(onsetEdges[$0 + 1] - 1, onsetEdges[$0]) }
    }

    /// One frame: `samples` holds the latest `size` mono samples (fewer are zero-padded); `dt` is the time since the last.
    mutating func process(_ samples: UnsafeBufferPointer<Float>, dt: Float) -> [Float] {
        let n = min(samples.count, size)
        silent = !samples.prefix(n).contains { $0 != 0 }
        windowed.withUnsafeMutableBufferPointer { w in
            for i in 0..<size { w[i] = i < n ? samples[i] * window[i] : 0 }
        }
        // Real FFT: pack even and odd samples into a split complex, transform in place, take the power per bin.
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(fft.setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                im[0] = 0                                  // the packed Nyquist bin
                power.withUnsafeMutableBufferPointer { p in
                    vDSP_zvmags(&split, 1, p.baseAddress!, 1, vDSP_Length(size / 2))
                }
            }
        }
        // Each band's mean power in dB (full scale ≈ 0 dB for a sine of amplitude 1).
        let scale = 1 / Float(size * size / 4)
        var flux: Float = 0
        for (b, band) in onsetBands.enumerated() {
            var rise: Float = 0
            for k in band {
                let c = log1p(compress * (power[k] * scale).squareRoot())
                rise += max(c - previousLog[k], 0)
                previousLog[k] = c
            }
            flux += Self.onsetWeights[b] * rise / Float(band.count)
        }
        onset = flux / Self.onsetWeights.reduce(0, +)
        var loudest: Float = -120
        for (b, r) in bands.enumerated() {
            var sum: Float = 0
            for i in r { sum += power[i] }
            let db = 10 * log10(max(sum / Float(r.count) * scale, 1e-12))
            bandDB[b] = db
            loudest = max(loudest, db)
        }
        // The followed loudness: rises within a quarter second, falls over a few, never below the floor.
        let toward = max(loudest, floor)
        let tau = toward > follow ? followRise : followFall
        follow += (toward - follow) * (1 - exp(-dt / tau))
        for b in 0..<bars {
            let target = min(max((bandDB[b] - (follow - range)) / (range + headroom), 0), 1)
            let k = 1 - exp(-dt / (target > levels[b] ? attack : decay))
            levels[b] += (target - levels[b]) * k
        }
        return levels
    }
}

/// The FFT's tables, freed with the last spectrum that uses them.
private final class Setup {
    let setup: FFTSetup
    init(_ log2n: vDSP_Length) { setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))! }
    deinit { vDSP_destroy_fftsetup(setup) }
}
