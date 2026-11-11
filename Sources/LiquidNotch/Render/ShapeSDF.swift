import Foundation
import simd

/// What the pointer is over.
enum HitRegion: Equatable, Sendable {
    /// A ball by place: 0 right of the ears, 1 left, 2 the +N ball.
    case ears, card, bubble(Int)
}

/// CPU copy of the distance field in LiquidShape.metal, used for hit testing.
/// Same coordinates (points, top-left origin, y down). Keep the two in sync.
enum ShapeSDF {
    private static let topExtension = 64.0

    /// Signed distance from `p` to the liquid (negative inside), bezel merge included.
    static func distance(_ p: SIMD2<Double>, _ u: ShapeUniforms) -> Double {
        let cx = Double(u.view.x) / 2
        let nh = Double(u.notch.y)
        let dNotch = roundBox(p - SIMD2(cx, (nh - topExtension) / 2),
                              SIMD2(Double(u.notch.x), (nh + topExtension) / 2), Double(u.notch.z), 2)
        let mh = Double(u.main.y)
        let mainX = Double(u.card2.w)
        let dMain = roundBox(p - SIMD2(cx + mainX, (mh - topExtension) / 2),
                             SIMD2(Double(u.main.x), (mh + topExtension) / 2), Double(u.main.z), Double(u.main.w))
        var d = smin(dNotch, dMain, Double(u.merge.x))

        let dr = SIMD2(Double(u.drop.z), Double(u.drop.w))
        if min(dr.x, dr.y) > 0.05 {
            let dc = SIMD2(Double(u.drop.x), Double(u.drop.y))
            d = smin(d, ellipse(p - dc, dr), Double(u.merge.y))
            let neck = Double(u.merge.w)
            if neck > 0.05 {
                let dNeck = segment(p, SIMD2(cx + Double(u.main.x) - neck, dc.y), dc) - neck
                d = smin(d, dNeck, min(Double(u.merge.y), neck * 3))
            }
        }
        for e in [u.extra1, u.extra2] where e.z > 0.05 {
            d = smin(d, simd_length(p - SIMD2(Double(e.x), Double(e.y))) - Double(e.z), Double(e.w))
        }
        if let dCard = card(p, u) {
            let cn = Double(u.card2.x)
            let kc = min(Double(u.merge.y), cn * 3)
            var dc = dCard
            if cn > 0.05 {
                let cardX = Double(u.card2.z)
                let dBridge = segment(p, SIMD2(cx + mainX, mh - cn), SIMD2(cx + cardX, Double(u.card.y) + cn)) - cn
                dc = smin(dc, dBridge, kc)
            }
            d = smin(d, dc, kc)
        }
        return smin(d, p.y, Double(u.merge.z))
    }

    /// The simulator's pointer rule (`onLiquid`): a margin of `earPad` around the ears so they
    /// are easy to hit, a tight 2 pt edge on the card (a click in the gap above it counts as
    /// outside), and the bubble with the ears' margin.
    static func hit(_ p: SIMD2<Double>, _ u: ShapeUniforms, earPad: Double, cardPad: Double = 2) -> HitRegion? {
        guard p.y >= 0 else { return nil }
        if let d = card(p, u), d < cardPad { return .card }
        let dr = SIMD2(Double(u.drop.z), Double(u.drop.w))
        let dropR = min(dr.x, dr.y)
        if dropR > 1, simd_length(p - SIMD2(Double(u.drop.x), Double(u.drop.y))) < dropR + earPad { return .bubble(0) }
        for (i, e) in [u.extra1, u.extra2].enumerated() where e.z > 1 {
            if simd_length(p - SIMD2(Double(e.x), Double(e.y))) < Double(e.z) + earPad { return .bubble(i + 1) }
        }
        let cx = Double(u.view.x) / 2
        let mh = Double(u.main.y)
        let dMain = roundBox(p - SIMD2(cx + Double(u.card2.w), (mh - topExtension) / 2),
                             SIMD2(Double(u.main.x), (mh + topExtension) / 2), Double(u.main.z), Double(u.main.w))
        return dMain < earPad ? .ears : nil
    }

    private static func card(_ p: SIMD2<Double>, _ u: ShapeUniforms) -> Double? {
        let hw = Double(u.card.x), h = Double(u.card.z)
        guard hw > 0.5, h > 0.5 else { return nil }
        let cx = Double(u.view.x) / 2 + Double(u.card2.z)
        return roundBox(p - SIMD2(cx, Double(u.card.y) + h / 2), SIMD2(hw, h / 2), Double(u.card.w), Double(u.main.w))
    }

    static func smin(_ a: Double, _ b: Double, _ k: Double) -> Double {
        guard k > 1e-4 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    static func roundBox(_ p: SIMD2<Double>, _ b: SIMD2<Double>, _ r0: Double, _ n: Double) -> Double {
        let r = min(r0, min(b.x, b.y))
        let q = abs(p) - b + SIMD2(repeating: r)
        let m = simd_max(q, .zero)
        let outside = n == 2 ? simd_length(m) : pow(pow(m.x, n) + pow(m.y, n), 1 / n)
        return outside + min(max(q.x, q.y), 0) - r
    }

    static func ellipse(_ p: SIMD2<Double>, _ r: SIMD2<Double>) -> Double {
        let k0 = simd_length(p / r)
        let k1 = simd_length(p / (r * r))
        return k1 > 1e-5 ? k0 * (k0 - 1) / k1 : -min(r.x, r.y)
    }

    static func segment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let pa = p - a, ba = b - a
        let h = min(max(simd_dot(pa, ba) / max(simd_dot(ba, ba), 1e-5), 0), 1)
        return simd_length(pa - ba * h)
    }
}
