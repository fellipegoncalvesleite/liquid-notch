import Foundation
import IslandCore
import simd

/// What besides the mode decides the shape.
struct TargetContext: Equatable, Sendable {
    /// The pointer is pressing the liquid.
    var pressed = false
    /// The card is being dragged this far from where the press started (pt, before the rubber band).
    var drag: SIMD2<Double>?
    /// Aura colour while something sets one (the album's colour, an activity's accent), else the tuned one.
    var auraHex: String?
    /// The dim bloom's tint from the desktop picture (`WallpaperTint`), else the tuned `bloomHex`.
    var bloomHex: String?
    /// The modes in which the bubble is out, from the island's arrangement.
    var bubbleModes: Set<PresentationMode> = [.split]
    /// The modes in which the left ball and the +N ball are out (11-06).
    var leftBallModes: Set<PresentationMode> = []
    var moreModes: Set<PresentationMode> = []
    /// An activity holds the ears, at this ear extent (nil: the tuned one).
    var activityHoldsEars = false
    var activityEar: Double?
    /// The card that opens (nil: the player's, from the tuning).
    var card: CardSize?
    /// The pointer is over the empty notch: it swells a little to say a press opens the tray.
    var idleHover = false
    /// A ball's own hover (owner, 11-06): the ball at this place swells and its peek card hangs under it.
    var peekPlace: Int?
    var peekCard: CardSize?
    /// A peek that just ended shrinks away where it was (x, top), under its ball, instead of travelling back into the
    /// notch (where it would touch the ears and pull a bridge down from them).
    var peekLeave: SIMD2<Double>?
    /// How near the pointer is to the ears, 0–1 in quarter steps (anticipation, sim `near`).
    var near = 0.0
    /// You're typing (sim CTX2): the ears make a little room, 6 pt narrower and dimmer, and come back when you stop.
    var typing = false
}

/// Turns a presentation mode into target shapes, including the staged poses the
/// liquid passes through between them. Mirror of `resting` / `transition` in the simulator.
struct ShapeTargets {
    var notchHalfWidth: Double
    var notchHeight: Double
    var tuning: Tuning
    var context = TargetContext()

    /// Hardware the shader always includes, inset so it can never show past the real notch.
    var notchConstants: (halfWidth: Double, height: Double, radius: Double) {
        (notchHalfWidth - tuning.idleInset, notchHeight - tuning.idleInset, tuning.notchRadius)
    }

    func hasDroplet(_ mode: PresentationMode) -> Bool { context.bubbleModes.contains(mode) }

    /// The open card's size: an activity's own, or the player's.
    var card: CardSize {
        context.card ?? CardSize(width: tuning.cardHalfWidth * 2, height: tuning.cardHeight, radius: tuning.cardRadius)
    }

    /// How near a pointer `distance` pt from the ears is: 1 at their edge, 0 from 70 pt, in quarter steps (sim `setNear`).
    static func near(distance: Double) -> Double { (max(0, 1 - distance / 70) * 4).rounded() / 4 }

    /// Follows, but less the further you pull.
    static func rubber(_ d: Double) -> Double { d * 0.4 / (1 + abs(d) / 100) }

    /// Where the card starts as it pours out of the notch's own bottom edge, and where it
    /// shrinks back to while closing.
    var cardSeed: ShapeState {
        var s = resting(.idle)
        s.cardHalfWidth = notchHalfWidth - 20
        s.cardHeight = 20
        s.cardRadius = 10
        s.cardTop = notchHeight - 22
        return s
    }

    /// Where a ball's peek grows from (owner, 11-06: hovering a ball pulled the notch down too): small, just under its
    /// ball and clear of the ears, so no bridge forms to them; it then grows and leans in to its resting place.
    func peekSeed(_ mode: PresentationMode) -> ShapeState {
        var s = resting(mode)
        guard let place = context.peekPlace else { return s }
        s.cardX = place == 0 ? s.dropX : place == 1 ? s.e1X : s.e2X
        s.cardHalfWidth = 12
        s.cardHeight = 12
        s.cardRadius = 6
        s.cardTop = notchHeight + tuning.cardGap
        return s
    }

    static var cardChannels: [WritableKeyPath<ShapeState, Double>] {
        [\.cardHalfWidth, \.cardHeight, \.cardRadius, \.cardTop]
    }

    func resting(_ mode: PresentationMode) -> ShapeState {
        let t = tuning
        let aura = OKLab.fromSRGB(SRGB.parse(context.auraHex ?? t.auraHex) ?? SIMD3(1, 0.3, 0.6))
        let ears = { (extent: Double) in
            ShapeState(mainHalfWidth: notchHalfWidth + extent, mainHeight: notchHeight, mainRadius: t.earRadius,
                       kBezel: t.kBezelCompact, glowIntensity: t.glowCompact, glowFalloff: t.falloffCompact)
        }
        // The notch at rest: its own size, rounder, its shoulders flaring into the top edge (owner, 11-06).
        let rest = ShapeState(mainHalfWidth: notchHalfWidth + t.idleGrow, mainHeight: notchHeight + t.idleDrop,
                              mainRadius: t.idleRadius, kBezel: t.idleBezel)
        var s: ShapeState
        switch mode {
        case .idle:
            // At rest the notch wears the island's softness (11-06): the hardware notch's size within a point, rounder
            // corners, the ears' shoulders flaring into the top edge. Hovered, it swells from there (6 pt wider, 4 pt
            // lower, sim `idleHover`).
            s = rest
            if context.idleHover {
                s.mainHalfWidth = notchHalfWidth + 6
                s.mainHeight = notchHeight + 4
                s.mainRadius = t.idleRadius + 2
            }
        case .compact, .split:
            s = ears(context.activityHoldsEars ? (context.activityEar ?? t.earExtent) : t.earExtent)
        case .duo:
            // The ears shorten to the primary's minimal view; an activity in the ears keeps its width.
            s = ears(context.activityHoldsEars ? (context.activityEar ?? t.earExtent) : t.minimalExtent)
        case .hud:
            s = ears(t.hudExtent)
            s.glowIntensity = 0
        case .peek:
            // From the ears' own width: a song's, or Claude's and Codex's 96 pt (sim `AG.ear`), so they never shrink.
            let ear = context.activityHoldsEars ? (context.activityEar ?? t.earExtent) : t.earExtent
            s = ShapeState(mainHalfWidth: notchHalfWidth + ear + t.peekExtra, mainHeight: t.peekHeight,
                           mainRadius: t.peekRadius, kBezel: t.kBezelExpanded,
                           glowIntensity: (t.glowCompact + t.glowExpanded) / 2,
                           glowFalloff: (t.falloffCompact + t.falloffExpanded) / 2)
        case .card:
            // The card hangs below as its own island; the ears go back into the notch, which keeps its small rounded
            // resting shape (owner, 11-06: "when it expands we should have the small notch but a bit rounded"). A ball
            // sits beside it, hanging from the top edge on its own (the shoulders stay flared, below).
            s = rest
            s.glowIntensity = t.glowExpanded
            s.glowFalloff = t.falloffExpanded
        case .expanded:
            s = ShapeState(mainHalfWidth: max(t.expandedHalfWidth, notchHalfWidth + 8),
                           mainHeight: t.expandedHeight, mainRadius: t.expandedRadius,
                           kBezel: t.kBezelExpanded,
                           glowIntensity: t.glowExpanded, glowFalloff: t.falloffExpanded)
        }
        // Anticipation (owner, 11-06: "very organic, follows you around"; sim `near`): the pointer coming within 70 pt
        // widens the ears up to 4 pt and brightens them a little. No lean (the hover lean of 10-31 read as wobbly).
        if context.typing && (mode == .compact || mode == .duo) { s.mainHalfWidth -= 6 }
        if context.near > 0 && (mode == .compact || mode == .duo) {
            s.mainHalfWidth += context.near * 4
            s.glowIntensity *= 1 + context.near * 0.3
        }
        s.auraL = aura.x
        s.auraA = aura.y
        s.auraB = aura.z
        if hasDroplet(mode) {
            // Beside the right ear, inside the menu bar strip: never on the screen below.
            s.dropRadius = t.dropRadius
            s.dropY = notchHeight - t.dropRadius
            s.dropX = s.mainHalfWidth + t.dropGap + t.dropRadius
        } else {
            // Tucked inside the blob, size zero.
            s.dropY = min(s.mainHeight, notchHeight) * 0.5
            s.dropX = min(s.mainHalfWidth, notchHalfWidth) * 0.5
            s.dropRadius = 0
        }
        // More balls (11-06): the left one mirrors the right; the small +N ball sits 12 pt past the right one. One that
        // isn't out sits inside its neighbour with no size, so it buds out of it and shrinks back in.
        let r0 = t.dropRadius, rm = 13.0
        let left = -(s.mainHalfWidth + t.dropGap + r0), right = s.mainHalfWidth + t.dropGap + r0
        let leftOn = context.leftBallModes.contains(mode), moreOn = context.moreModes.contains(mode)
        s.e1X = leftOn ? left : -min(s.mainHalfWidth, notchHalfWidth) * 0.5
        s.e1R = leftOn ? r0 : 0
        s.e2X = moreOn ? right + r0 + 12 + rm : right
        s.e2R = moreOn ? rm : 0
        if mode == .card {
            // The card answers the pointer like the island answers a finger: it squashes on a
            // press and follows a drag on a rubber band. Dragged up, it rises into the notch and
            // sticks there (owner likes it; not clamped).
            let dx = context.drag.map { Self.rubber($0.x) } ?? 0
            let dy = context.drag.map { Self.rubber($0.y) } ?? 0
            let sq = context.pressed ? t.pressSquish : 0
            let cd = card
            s.cardHalfWidth = cd.halfWidth + sq + abs(dx) * 0.08
            s.cardHeight = cd.height - sq * 0.8 + abs(dy) * 0.12
            s.cardRadius = cd.radius
            s.cardTop = notchHeight + t.cardGap + dy + sq * 0.4
            s.cardX = dx
            // The liquid at the notch follows: it leans the same way and swells with the card.
            s.mainX = dx * 0.5
            s.mainHalfWidth += (s.cardHalfWidth - cd.halfWidth) * 0.6
            // The shoulders stay flared into the top edge, so a ball keeps hanging from it (owner, 11-06: it came apart
            // from the notch when the card opened); a drag leans them like the ears'.
            if abs(dx) > 0.5 { s.kBezel = t.kBezelCompact }
        } else {
            s.cardTop = notchHeight - 30        // tucked in the notch
        }
        if let place = context.peekPlace, let pc = context.peekCard, mode == .duo || mode == .peek {
            // A ball's hover: it swells a little and its peek hangs under it, leaning in toward the notch so it stays
            // on the panel; the ears don't move.
            let swell = 3.0, ballX: Double
            switch place {
            case 0: s.dropRadius += swell; ballX = s.dropX
            case 1: s.e1R += swell; ballX = s.e1X
            default: s.e2R += swell; ballX = s.e2X
            }
            s.cardHalfWidth = pc.halfWidth
            s.cardHeight = pc.height
            s.cardRadius = pc.radius
            s.cardTop = notchHeight + t.cardGap
            s.cardX = ballX - (ballX < 0 ? -1 : 1) * min(pc.halfWidth - 36, abs(ballX))
        } else if let leave = context.peekLeave, mode != .card {
            s.cardX = leave.x
            s.cardTop = leave.y
        }
        if t.dimGlow {
            // The bloom is dim (the ears' soft level is the most it ever gets), wide and soft, and
            // cool: tinted from the wallpaper, never from the album.
            let open = mode == .card || mode == .expanded || mode == .peek
            s.glowIntensity = min(s.glowIntensity, t.bloomIntensity) * (open ? 1 : 0.75)
            s.glowFalloff = open ? t.bloomFalloffOpen : t.bloomFalloff
            let bloom = OKLab.fromSRGB(SRGB.parse(context.bloomHex ?? t.bloomHex) ?? SIMD3(0.56, 0.58, 0.94))
            s.auraL = bloom.x
            s.auraA = bloom.y
            s.auraB = bloom.z
        }
        // Typing dims it too, after the dim bloom's cap so it still shows (sim CTX2).
        if context.typing && (mode == .compact || mode == .duo) { s.glowIntensity *= 0.6 }
        if context.pressed && mode != .idle && mode != .card {
            // Pressing squishes the island; the release springs it back with a bounce.
            s.mainHalfWidth -= t.pressSquish
            s.mainHeight -= t.pressSquish * 0.5
        }
        return s
    }

    /// Target plus staged follow-ups for a move from `from` to `to`.
    func transition(from: PresentationMode, to: PresentationMode,
                    reduceMotion: Bool = false) -> (ShapeState, [(delay: Double, state: ShapeState)]) {
        let final = resting(to)
        let t = tuning
        if reduceMotion { return (final, []) }

        // Opening the card is one continuous pour: it starts as the notch's own bottom edge
        // (seeded by the caller) and falls and swells on the spring in a single move.
        if to == .card && from != .card { return (final, []) }
        if from == .card && to != .card {
            // Closing: the card shrinks and rises back into the notch (the bridge re-forms as
            // it touches), then is swallowed.
            var rise = final
            let seed = cardSeed
            for k in Self.cardChannels { rise[keyPath: k] = seed[keyPath: k] }
            return (rise, [(t.budDelay * 2, final)])
        }
        if from == .idle && (to == .compact || to == .hud) {
            // Liquid opening: the notch first sags and spreads like a poured drop, then the
            // ears run out to their length and the sag springs back up.
            var pour = final
            pour.mainHalfWidth = notchHalfWidth + (final.mainHalfWidth - notchHalfWidth) * t.pourSpread
            pour.mainHeight = final.mainHeight + t.pourDepth
            pour.mainRadius = final.mainRadius + t.pourDepth * 0.5
            pour.kBezel = final.kBezel + t.pourDepth
            return (pour, [(t.pourDelay, final)])
        }
        if hasDroplet(to) && !hasDroplet(from) {
            // Drip: the drop swells out of the ear's end first, then slides off sideways.
            var bulge = final
            bulge.dropX = final.mainHalfWidth - t.dropRadius * 0.15
            return (bulge, [(t.bulgeDelay, final)])
        }
        if hasDroplet(from) && !hasDroplet(to) {
            // Reverse: drawn back into the old ear's end where it is (never dragged across
            // the new shape), then swallowed.
            let old = resting(from)
            var rejoin = final
            rejoin.dropX = old.mainHalfWidth - t.dropRadius * 0.35
            rejoin.dropY = old.dropY
            rejoin.dropRadius = t.dropRadius * 0.85
            return (rejoin, [(t.absorbDelay, final)])
        }
        // Squash and stretch: the two axes move out of step. Growing, the island widens
        // first and then drops; collapsing, it pulls up first and then narrows.
        let old = resting(from)
        if final.mainHeight > old.mainHeight + 2 {
            var first = final
            first.mainHeight = old.mainHeight
            return (first, [(t.axisLag, final)])
        }
        if final.mainHeight < old.mainHeight - 2 {
            var first = final
            first.mainHalfWidth = old.mainHalfWidth
            return (first, [(t.axisLag, final)])
        }
        return (final, [])
    }

    /// The frame as drawn: while the ears are out the liquid is never shorter than the
    /// notch (a floor under interrupted motion and the press squish; the animator's
    /// landing handles the normal case).
    func drawn(_ frame: ShapeFrame) -> ShapeFrame {
        var f = frame
        f.state.mainHeight = drawnHeight(f.state)
        return f
    }

    func drawnHeight(_ s: ShapeState) -> Double {
        let w = min(max((s.mainHalfWidth - notchHalfWidth) / 6, 0), 1)
        return max(s.mainHeight, notchHeight - tuning.idleInset * (1 - w))
    }
}

enum SRGB {
    /// "#RRGGBB" -> 0...1 components.
    static func parse(_ hex: String) -> SIMD3<Double>? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return SIMD3(Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF)) / 255
    }

    static func hex(_ c: SIMD3<Double>) -> String {
        let q = (simd_clamp(c, SIMD3<Double>(repeating: 0), SIMD3<Double>(repeating: 1)) * 255).rounded(.toNearestOrEven)
        return String(format: "#%02X%02X%02X", Int(q.x), Int(q.y), Int(q.z))
    }
}
