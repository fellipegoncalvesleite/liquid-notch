import Foundation
import simd

/// OKLab <-> sRGB (Björn Ottosson, 2020). Aura colors are animated in OKLab so a
/// change from, say, red to blue passes through a believable purple instead of
/// the gray mud a straight RGB lerp produces.
enum OKLab {
    static func fromSRGB(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let r = toLinear(c.x), g = toLinear(c.y), b = toLinear(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func toSRGB(L: Double, a: Double, b: Double) -> SIMD3<Double> {
        let l = pow3(L + 0.3963377774 * a + 0.2158037573 * b)
        let m = pow3(L - 0.1055613458 * a - 0.0638541728 * b)
        let s = pow3(L - 0.0894841775 * a - 1.2914855480 * b)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return SIMD3(toGamma(r), toGamma(g), toGamma(bl))
    }

    private static func pow3(_ x: Double) -> Double { x * x * x }

    private static func toLinear(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private static func toGamma(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
