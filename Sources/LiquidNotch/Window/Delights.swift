import AppKit

/// Small delights (easter eggs, 11-06, ported from the sim's `src/agents.js`): ↑↑↓↓←→←→BA typed while the pointer rests
/// on the island runs it through the rainbow with a little dance; scrubbing the pointer back and forth over it makes it
/// giggle (three quick jiggles). Keys are only looked at while the pointer is over the island. Off with Reduce Motion.
@MainActor
final class Delights {
    var kickWidth: (Double) -> Void = { _ in }
    var kick: (Double) -> Void = { _ in }
    var pulse: (String) -> Void = { _ in }
    var aura: (String?) -> Void = { _ in }
    var reduceMotion: () -> Bool = { false }
    var now: () -> Double = { CACurrentMediaTime() }
    var after: (Double, @escaping @MainActor () -> Void) -> Void = { s, f in
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
    }

    /// Up, up, down, down, left, right, left, right, B, A (virtual key codes).
    static let konami: [UInt16] = [126, 126, 125, 125, 123, 124, 123, 124, 11, 0]
    static let rainbowColors = ["#FF453A", "#FF9F0A", "#FFD60A", "#30D158", "#64D2FF", "#0A84FF", "#BF5AF2"]
    private var konamiAt = 0
    private var tickleDir = 0.0, tickleX = 0.0, flips: [Double] = [], quietUntil = 0.0

    /// A key went down while the pointer was over the island. Returns true when it finished the code.
    @discardableResult
    func key(_ code: UInt16) -> Bool {
        konamiAt = code == Self.konami[konamiAt] ? konamiAt + 1 : (code == Self.konami[0] ? 1 : 0)
        guard konamiAt == Self.konami.count else { return false }
        konamiAt = 0
        rainbow()
        return true
    }

    func rainbow() {
        guard !reduceMotion() else { return }
        for (i, c) in Self.rainbowColors.enumerated() {
            after(Double(i) * 0.18) { [weak self] in
                self?.aura(c); self?.pulse(c); self?.kickWidth(i % 2 == 1 ? -45 : 45)
            }
        }
        after(1.4) { [weak self] in self?.aura(nil) }
    }

    /// The pointer moved; `x` in the panel, `over` the liquid. Four direction changes within 0.7 s giggle.
    func pointer(x: Double, over: Bool, pressed: Bool) {
        guard over, !pressed, !reduceMotion() else { tickleDir = 0; flips = []; return }
        let dx = x - tickleX
        guard abs(dx) >= 6 else { return }
        let dir = dx > 0 ? 1.0 : -1.0, t = now()
        if tickleDir != 0 && dir != tickleDir { flips = flips.filter { t - $0 < 0.7 } + [t] }
        tickleDir = dir; tickleX = x
        guard flips.count >= 4, t > quietUntil else { return }
        flips = []; quietUntil = t + 2
        for (i, d) in [0.0, 0.12, 0.24].enumerated() { after(d) { [weak self] in self?.kick(i % 2 == 1 ? -50 : 60) } }
    }
}
