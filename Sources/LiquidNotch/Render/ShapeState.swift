import simd

/// Every parameter of the liquid surface at one instant, in points.
/// The motion layer springs one of these toward a target; the renderer draws it.
struct ShapeState: Equatable, Sendable {
    // Main blob (ears / expanded / idle)
    var mainHalfWidth: Double
    var mainHeight: Double
    var mainRadius: Double

    // Droplet. `dropY` is the center, measured from the top of the screen.
    var dropX: Double = 0          // offset from the notch center
    var dropY: Double = 0
    var dropRadius: Double = 0
    // More balls (11-06): 1 left of the ears, 2 the small +N ball past the right one. Same row as the droplet.
    var e1X: Double = 0
    var e1R: Double = 0
    var e2X: Double = 0
    var e2R: Double = 0

    // Island card below the notch. `cardTop` is its top edge, from the top of the screen;
    // `cardX` and `mainX` lean the card and the notch liquid sideways while it's dragged.
    var cardHalfWidth: Double = 0
    var cardTop: Double = 0
    var cardHeight: Double = 0
    var cardRadius: Double = 0
    var cardX: Double = 0
    var mainX: Double = 0

    // Merges
    var kBezel: Double = 0         // how much the blob flares into the bezel

    // Aura, color in OKLab so that color changes travel through perceptual space
    var glowIntensity: Double = 0
    var glowFalloff: Double = 12
    var auraL: Double = 0.7
    var auraA: Double = 0.1
    var auraB: Double = -0.1
}

/// Byte-for-byte mirror of `Uniforms` in LiquidShape.metal.
struct ShapeUniforms {
    var view: SIMD4<Float> = .zero
    var notch: SIMD4<Float> = .zero
    var main: SIMD4<Float> = .zero
    var drop: SIMD4<Float> = .zero
    var merge: SIMD4<Float> = .zero
    var glow: SIMD4<Float> = .zero
    var aura: SIMD4<Float> = .zero
    var fill: SIMD4<Float> = .zero
    var card: SIMD4<Float> = .zero
    var card2: SIMD4<Float> = .zero
    var pulse: SIMD4<Float> = .zero
    var hair: SIMD4<Float> = .zero
    var extra1: SIMD4<Float> = .zero
    var extra2: SIMD4<Float> = .zero
}

/// Per-frame values the renderer needs besides the state: the derived bridges and the
/// look's momentary extras.
struct FrameExtras: Sendable {
    var cardNeck = 0.0
    /// The ears glow less while the card is open (the light comes from the card).
    var earGlowOffset = 0.0
    /// Event pulse: colour (sRGB) and amount (0.4 fading to 0).
    var pulseColor = SIMD3<Double>(1, 1, 1)
    var pulse = 0.0
    /// Hairline on the edge: white opacity.
    var hairline = 0.0
}

/// Values that are not animated: geometry of the hardware and the look settings
/// the debug panel tunes.
struct SurfaceConstants: Sendable {
    var viewSize: SIMD2<Double>
    var scale: Double
    var notchHalfWidth: Double
    var notchHeight: Double
    var notchRadius: Double
    var cornerExponent: Double
    var kNotch: Double
    var kDrop: Double
    var edgeFeather: Double
    var dither: Double = 1.0 / 255.0
    var fill: SIMD3<Double> = .zero
}

extension ShapeUniforms {
    init(state s: ShapeState, neckRadius: Double, dropRadii: SIMD2<Double>, constants c: SurfaceConstants,
         extras e: FrameExtras = FrameExtras()) {
        let aura = OKLab.toSRGB(L: s.auraL, a: s.auraA, b: s.auraB)
        view = SIMD4(Float(c.viewSize.x), Float(c.viewSize.y), Float(c.scale), Float(c.edgeFeather))
        notch = SIMD4(Float(c.notchHalfWidth), Float(c.notchHeight), Float(c.notchRadius), 0)
        main = SIMD4(Float(max(s.mainHalfWidth, 0)), Float(max(s.mainHeight, 0)),
                     Float(max(s.mainRadius, 0)), Float(c.cornerExponent))
        drop = SIMD4(Float(c.viewSize.x / 2 + s.dropX), Float(s.dropY),
                     Float(max(dropRadii.x, 0)), Float(max(dropRadii.y, 0)))
        merge = SIMD4(Float(c.kNotch), Float(c.kDrop), Float(max(s.kBezel, 0)), Float(max(neckRadius, 0)))
        glow = SIMD4(Float(max(s.glowIntensity, 0)), Float(max(s.glowFalloff, 0.1)), Float(c.dither), 0)
        self.aura = SIMD4(Float(aura.x), Float(aura.y), Float(aura.z), 0)
        fill = SIMD4(Float(c.fill.x), Float(c.fill.y), Float(c.fill.z), 0)
        card = SIMD4(Float(max(s.cardHalfWidth, 0)), Float(s.cardTop), Float(max(s.cardHeight, 0)),
                     Float(max(s.cardRadius, 0)))
        card2 = SIMD4(Float(max(e.cardNeck, 0)), Float(e.earGlowOffset), Float(s.cardX), Float(s.mainX))
        pulse = SIMD4(Float(e.pulseColor.x), Float(e.pulseColor.y), Float(e.pulseColor.z), Float(max(e.pulse, 0)))
        hair = SIMD4(Float(e.hairline), Float(0.5 * c.scale), 0, 0)
        // Each ball blends with its neighbour (the ears, or the ball inside it) while they touch, the blend fading
        // over 10 pt of gap: they bud out as one liquid and pinch apart (sim `extraUniforms`).
        let ball = { (x: Double, r: Double, nx: Double, nr: Double) -> SIMD4<Float> in
            let gap = abs(x - nx) - max(r, 0) - nr
            let k = r > 0.05 ? c.kDrop * min(max(1 - gap / 10, 0), 1) : 0
            return SIMD4(Float(c.viewSize.x / 2 + x), Float(s.dropY), Float(max(r, 0)), Float(k))
        }
        extra1 = ball(s.e1X, s.e1R, -s.mainHalfWidth, 0)
        extra2 = ball(s.e2X, s.e2R, s.dropX, s.dropRadius)
    }
}
