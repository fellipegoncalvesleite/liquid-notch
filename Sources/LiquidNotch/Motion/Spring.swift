import Foundation

/// A damped harmonic oscillator with unit mass: x'' = -stiffness * (x - target) - damping * x'.
struct SpringConfig: Equatable, Codable, Sendable {
    var stiffness: Double
    var damping: Double

    var dampingRatio: Double { damping / (2 * stiffness.squareRoot()) }

    /// Rough time to come within 0.1 % of the target (envelope e^-ζωt).
    var settleTime: Double {
        let w = stiffness.squareRoot()
        let decay = min(dampingRatio, 1) * w
        return decay > 0 ? log(1000) / decay : .infinity
    }

    /// The reference prototype's spring: ζ ≈ 0.54.
    static let liquid = SpringConfig(stiffness: 190, damping: 15)
}

/// One animated scalar.
///
/// Steps use the closed-form solution of the oscillator, not numerical
/// integration, so the result is exact for any frame time (a dropped frame or a
/// slow-motion time scale never changes the path) and there is nothing to blow up.
/// Retargeting only moves `target`: position and velocity carry over, so an
/// interrupted animation bends smoothly into the new one.
struct Spring: Sendable {
    var value: Double
    var velocity: Double = 0
    var target: Double
    var config: SpringConfig
    /// Below this distance and `epsilon * 10` per second of speed the spring snaps and rests.
    var epsilon: Double

    init(_ value: Double, config: SpringConfig, epsilon: Double = 0.01) {
        self.value = value
        self.target = value
        self.config = config
        self.epsilon = epsilon
    }

    var isResting: Bool { value == target && velocity == 0 }

    mutating func step(_ dt: Double) {
        guard !isResting, dt > 0 else { return }
        let x0 = value - target
        let v0 = velocity
        let w = config.stiffness.squareRoot()
        let zeta = config.dampingRatio
        let x: Double
        let v: Double

        if w == 0 {
            x = x0 + v0 * dt
            v = v0
        } else if abs(zeta - 1) < 1e-4 {
            // Critically damped
            let e = exp(-w * dt)
            let c = v0 + w * x0
            x = e * (x0 + c * dt)
            v = e * (v0 - w * c * dt)
        } else if zeta < 1 {
            // Underdamped
            let a = zeta * w
            let wd = w * (1 - zeta * zeta).squareRoot()
            let e = exp(-a * dt)
            let cosT = cos(wd * dt), sinT = sin(wd * dt)
            x = e * (x0 * cosT + (v0 + a * x0) / wd * sinT)
            v = e * (v0 * cosT - (a * v0 + w * w * x0) / wd * sinT)
        } else {
            // Overdamped
            let s = (zeta * zeta - 1).squareRoot()
            let r1 = -w * (zeta - s), r2 = -w * (zeta + s)
            let c2 = (v0 - r1 * x0) / (r2 - r1)
            let c1 = x0 - c2
            let e1 = exp(r1 * dt), e2 = exp(r2 * dt)
            x = c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        }

        if abs(x) < epsilon && abs(v) < epsilon * 10 {
            value = target
            velocity = 0
        } else {
            value = target + x
            velocity = v
        }
    }

    /// Adds velocity: a jolt that springs back to the same target.
    mutating func kick(_ v: Double) { velocity += v }

    mutating func snap(to newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }
}
