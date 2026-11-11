import Foundation

/// What the renderer needs for one frame: the sprung state plus the values the
/// animator derives from motion (the neck and the droplet's stretch).
struct ShapeFrame: Sendable {
    var state: ShapeState
    var neckRadius: Double
    var dropRadii: SIMD2<Double>
    /// The card's bridge to the notch.
    var cardNeck: Double = 0
}

/// Settings for the parts of the motion that are derived rather than sprung.
struct DropletDynamics: Equatable, Codable, Sendable {
    /// Neck thickness at contact, as a fraction of the droplet radius.
    var neckRatio: Double = 0.42
    /// Gap between blob and droplet (pt) at which the bridge snaps.
    var breakGap: Double = 7
    /// Elongation along the direction of travel per pt/s of droplet speed.
    var stretchGain: Double = 0.0011
    var maxStretch: Double = 0.38
    /// Once the bridge has broken, the thread vanishes when it gets this thin (pt).
    var pinchRadius: Double = 0.75
    /// The neck follows its geometric target on a stiff spring so it thins out
    /// smoothly instead of tracking the gap frame by frame.
    var neckSpring = SpringConfig(stiffness: 900, damping: 54)
}

/// Springs every parameter of `ShapeState` toward a target, each on its own spring.
/// Knows nothing about activities or content.
@MainActor
final class ShapeAnimator {
    enum Group { case shape, droplet, glow, color, card }

    private struct Channel {
        let keyPath: WritableKeyPath<ShapeState, Double>
        let group: Group
        var spring: Spring
    }

    private var channels: [Channel] = []
    private var neck: Spring
    private var neckAttached = false
    private var cardNeck: Spring
    private var cardNeckAttached = false
    /// Staged retargets, in animator time (so slow motion slows the choreography too).
    private var pending: [(at: Double, state: ShapeState)] = []
    private var time = 0.0
    /// Until this time the shape, droplet and glow springs are slow and critically damped (sim `ctxSoftUntil`): the
    /// island drains into the notch for a menu or fullscreen instead of snapping.
    private var softUntil = -1.0

    /// Drains softly for `seconds` (a menu opened, a fullscreen window arrived).
    func soften(for seconds: Double) { softUntil = time + seconds }
    private(set) var current: ShapeState
    private(set) var target: ShapeState

    var configs: [Group: SpringConfig]
    var dynamics: DropletDynamics
    /// Reduce Motion: shape changes become quick, non-overshooting transitions.
    var reduceMotion = false
    /// The card's bridge: at most this thick (pt), and gone past this gap (pt).
    var cardBridge = (maxRadius: 26.0, breakGap: 7.0)
    /// The card is being dragged: it and the notch liquid follow the pointer tightly.
    var dragging = false
    /// The hardware notch's bottom edge. The liquid can't rise past it while the ears are
    /// out, so a height coming back down to it lands critically damped instead of
    /// bouncing up through the notch (where the notch's square corners would show).
    var floor: (halfWidth: Double, height: Double)?

    init(initial: ShapeState, configs: [Group: SpringConfig], dynamics: DropletDynamics) {
        current = initial
        target = initial
        self.configs = configs
        self.dynamics = dynamics
        neck = Spring(0, config: dynamics.neckSpring, epsilon: 0.01)
        cardNeck = Spring(0, config: dynamics.neckSpring, epsilon: 0.01)

        let layout: [(WritableKeyPath<ShapeState, Double>, Group, Double)] = [
            (\.mainHalfWidth, .shape, 0.01),
            (\.mainHeight, .shape, 0.01),
            (\.mainRadius, .shape, 0.01),
            (\.kBezel, .shape, 0.01),
            (\.dropX, .droplet, 0.01),
            (\.dropY, .droplet, 0.01),
            (\.dropRadius, .droplet, 0.01),
            (\.e1X, .droplet, 0.01), (\.e1R, .droplet, 0.01), (\.e2X, .droplet, 0.01), (\.e2R, .droplet, 0.01),
            (\.glowIntensity, .glow, 0.0005),
            (\.glowFalloff, .glow, 0.01),
            (\.auraL, .color, 0.0005),
            (\.auraA, .color, 0.0005),
            (\.auraB, .color, 0.0005),
            (\.cardHalfWidth, .card, 0.01),
            (\.cardTop, .card, 0.01),
            (\.cardHeight, .card, 0.01),
            (\.cardRadius, .card, 0.01),
            (\.cardX, .card, 0.01),
            (\.mainX, .shape, 0.01),
        ]
        channels = layout.map { kp, group, eps in
            Channel(keyPath: kp, group: group,
                    spring: Spring(initial[keyPath: kp], config: configs[group] ?? .liquid, epsilon: eps))
        }
    }

    var isResting: Bool {
        pending.isEmpty && channels.allSatisfy(\.spring.isResting) && neck.isResting && cardNeck.isResting
    }

    /// Retargets now and cancels any staged retargets.
    func setTarget(_ newTarget: ShapeState) {
        pending.removeAll()
        retarget(newTarget)
    }

    /// Changes where the current move ends without cancelling its staged poses (a hover
    /// or press during a pour must not cut the pour short).
    func setFinal(_ newTarget: ShapeState) {
        if pending.isEmpty { retarget(newTarget) } else { pending[pending.count - 1].state = newTarget }
    }

    /// Retargets now, then again at each `(delay, state)` (delays from now, in seconds).
    /// Used for choreography such as the droplet bulging before it falls.
    func setTargets(_ first: ShapeState, then stages: [(delay: Double, state: ShapeState)]) {
        setTarget(first)
        pending = stages.map { (time + $0.delay, $0.state) }
    }

    private func retarget(_ newTarget: ShapeState) {
        target = newTarget
        for i in channels.indices {
            channels[i].spring.target = newTarget[keyPath: channels[i].keyPath]
        }
    }

    /// Jump straight to `state` with no motion (first layout, screen change).
    func snap(to state: ShapeState) {
        pending.removeAll()
        target = state
        current = state
        for i in channels.indices {
            channels[i].spring.snap(to: state[keyPath: channels[i].keyPath])
        }
        neckAttached = false
        neck.snap(to: neckTarget(for: state))
        neckAttached = neck.value > 0
        cardNeckAttached = false
        cardNeck.snap(to: cardNeckTarget(for: state))
        cardNeckAttached = cardNeck.value > 0
    }

    /// Jumps some channels with no motion (the card seeded at the notch's bottom edge).
    func snapChannels(_ keyPaths: [WritableKeyPath<ShapeState, Double>], from state: ShapeState) {
        for i in channels.indices where keyPaths.contains(channels[i].keyPath) {
            let v = state[keyPath: channels[i].keyPath]
            channels[i].spring.snap(to: v)
            current[keyPath: channels[i].keyPath] = v
        }
    }

    /// Adds velocity to one channel: a jolt (power arriving, a basket, a button).
    func kick(_ keyPath: WritableKeyPath<ShapeState, Double>, _ velocity: Double) {
        guard let i = channels.firstIndex(where: { $0.keyPath == keyPath }) else { return }
        channels[i].spring.kick(velocity)
    }

    /// Advances by `dt` seconds. Returns true while anything is still moving.
    @discardableResult
    func advance(_ dt: Double) -> Bool {
        time += dt
        while let next = pending.first, next.at <= time {
            pending.removeFirst()
            retarget(next.state)
        }
        for i in channels.indices {
            var cfg = config(for: channels[i].group)
            if dragging && !reduceMotion && (channels[i].group == .card || channels[i].keyPath == \ShapeState.mainX) {
                cfg = SpringConfig(stiffness: 700, damping: 40)
            }
            if channels[i].keyPath == \ShapeState.mainHeight, let floor,
               channels[i].spring.target <= floor.height + 0.5, current.mainHalfWidth > floor.halfWidth + 1 {
                cfg = SpringConfig(stiffness: cfg.stiffness, damping: 2 * cfg.stiffness.squareRoot())
            }
            channels[i].spring.config = cfg
            channels[i].spring.step(dt)
            current[keyPath: channels[i].keyPath] = channels[i].spring.value
        }
        neck.config = dynamics.neckSpring
        neck.target = neckTarget(for: current)
        neck.step(dt)
        // A detached thread thinner than this snaps instead of lingering as a hairline.
        if !neckAttached && neck.value < dynamics.pinchRadius { neck.snap(to: 0) }
        cardNeck.config = dynamics.neckSpring
        cardNeck.target = cardNeckTarget(for: current)
        cardNeck.step(dt)
        if !cardNeckAttached && cardNeck.value < dynamics.pinchRadius { cardNeck.snap(to: 0) }
        return !isResting
    }

    var frame: ShapeFrame {
        ShapeFrame(state: current, neckRadius: max(neck.value, 0), dropRadii: dropRadii,
                   cardNeck: max(cardNeck.value, 0))
    }

    // MARK: - Derived motion

    private func config(for group: Group) -> SpringConfig {
        let base = configs[group] ?? .liquid
        if !reduceMotion, time < softUntil, group == .shape || group == .droplet || group == .glow {
            return SpringConfig(stiffness: 70, damping: 2 * 70.0.squareRoot())
        }
        guard reduceMotion, group == .shape || group == .droplet || group == .card else { return base }
        // Critically damped and fast: no overshoot, no wobble, ~0.2 s.
        return SpringConfig(stiffness: 600, damping: 2 * 600.0.squareRoot())
    }

    /// Gap between the end of the right ear and the near side of the droplet.
    private func gap(for s: ShapeState) -> Double {
        (s.dropX - s.dropRadius) - s.mainHalfWidth
    }

    /// The bridge: full thickness while the droplet overlaps the blob, thinning as
    /// the gap opens (√ profile, like a stretched liquid thread), gone past
    /// `breakGap`. Once it snaps it stays gone until the droplet touches again, so
    /// an overshooting droplet does not re-grow a thread on the way back.
    private func neckTarget(for s: ShapeState) -> Double {
        guard s.dropRadius > 0.5 else {
            neckAttached = false
            return 0
        }
        let g = gap(for: s)
        let full = s.dropRadius * dynamics.neckRatio
        if g <= 0 { neckAttached = true }
        if g > dynamics.breakGap { neckAttached = false }
        guard neckAttached else { return 0 }
        return full * max(0, 1 - max(g, 0) / dynamics.breakGap).squareRoot()
    }

    /// The card's bridge: the droplet's neck rules turned vertical. Full while the card touches
    /// the ears, thinning as the gap opens, gone past `cardBreakGap` until it touches again.
    private func cardNeckTarget(for s: ShapeState) -> Double {
        guard s.cardHalfWidth > 0.5, s.cardHeight > 0.5 else {
            cardNeckAttached = false
            return 0
        }
        let g = s.cardTop - s.mainHeight
        let full = min(min(s.cardHalfWidth, s.cardHeight / 2) * dynamics.neckRatio, cardBridge.maxRadius)
        if g <= 0 { cardNeckAttached = true }
        if g > cardBridge.breakGap { cardNeckAttached = false }
        guard cardNeckAttached else { return 0 }
        return full * max(0, 1 - max(g, 0) / cardBridge.breakGap).squareRoot()
    }

    /// Area-preserving stretch along the horizontal axis (the drop travels sideways),
    /// driven by droplet speed.
    private var dropRadii: SIMD2<Double> {
        let r = current.dropRadius
        guard r > 0 else { return .zero }
        let speed = channels.first { $0.keyPath == \ShapeState.dropX }?.spring.velocity ?? 0
        let s = min(abs(speed) * dynamics.stretchGain, dynamics.maxStretch)
        return SIMD2(r * (1 + s).squareRoot(), r / (1 + s).squareRoot())
    }
}
