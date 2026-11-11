import Foundation
import Observation

/// Every look-and-feel number the debug panel can change. Persisted, so a feel
/// session survives relaunches, and copyable as JSON to bake into the defaults.
struct Tuning: Codable, Equatable, Sendable {
    // Springs
    var shapeSpring = SpringConfig.liquid
    var dropletSpring = SpringConfig(stiffness: 170, damping: 14)
    var glowSpring = SpringConfig(stiffness: 45, damping: 12.5)
    var colorSpring = SpringConfig(stiffness: 30, damping: 11)
    var dynamics = DropletDynamics()
    var timeScale = 1.0

    // Shapes (pt)
    var earExtent = 60.0            // how far each ear reaches past the notch (70 felt a tad big live, 11-01)
    var earRadius = 18.0            // ~half the menu bar height: pill ends
    var hudExtent = 84.0            // 96 felt a tad big live (11-01)
    var expandedHalfWidth = 196.0
    var expandedHeight = 172.0
    var expandedRadius = 44.0
    var cornerExponent = 2.6        // 2 = circular corners, higher = more continuous
    var notchRadius = 9.0           // physical notch's bottom corners (best guess)
    var idleInset = 1.0             // keeps the idle blob inside the hardware notch (under an open card)
    // The notch at rest (owner, 11-06: the bare notch's shape bothered them): the hardware notch's size, only rounder
    // ("the small before should still be the small now"). Half a point wider and one lower lets the 11 pt corners cover
    // the notch's own; the ears' flared shoulders meet the top edge (sim `idleGrow`…).
    // Rounder (owner, 11-07: "the default notch is too squary … rounded like the notch when it has music, but small"):
    // 14 pt corners need the liquid 1.5 pt wider and lower than the hardware notch to cover its own corners.
    // Still squary (owner, 11-07: "you still didn't smooth the idle notch"): the corners are superellipses (n 2.6), so a
    // 14 pt one cuts only 0.7 pt deeper than the notch's own 9 pt circle. The music ears' 18 pt corners, at 2 pt wider
    // and lower (the least that keeps a 9 pt notch corner solidly inside them, past the edge's antialiasing).
    var idleGrow = 2.0
    var idleDrop = 2.0
    var idleRadius = 18.0
    var idleBezel = 9.0
    var edgeFeather = 1.0           // AA width in pixels

    // Merges (smooth-min k, pt)
    var kNotch = 0.0
    var kDrop = 12.0
    var kBezelCompact = 9.0
    var kBezelExpanded = 16.0

    // Droplet
    var dropRadius = 18.0           // same height as the ears
    var dropGap = 11.0
    var bulgeDelay = 0.07           // droplet swells at the edge, then falls
    var absorbDelay = 0.10

    // Opening, hover, press
    var pourDepth = 6.0             // the notch sags this far before the ears run out
    var pourSpread = 0.55           // fraction of the ear length reached during the sag
    var pourDelay = 0.08
    var contentDelay = 0.17         // content follows the shape by this much
    var peekExtra = 14.0            // hover preview: extra width per side
    var peekHeight = 76.0           // room for the cover beside the title (11-01)
    var peekRadius = 24.0
    var axisLag = 0.05              // width and height move out of step by this much
    var pressSquish = 5.0
    var minimalExtent = 40.0        // ear length while a second activity is out

    // Card (the open player; activities take their own sizes)
    var cardHalfWidth = 186.0
    var cardHeight = 168.0          // the player, back to its iPhone-like size (owner, 11-01)
    var cardRadius = 34.0
    var cardGap = 8.0               // below the menu bar
    var cardNeckMax = 26.0          // the bridge's thickest
    var cardBreakGap = 7.0          // the bridge snaps past this gap
    var budDelay = 0.08             // closing: the card rises into the notch, held 2× this

    // Pointer
    var hitPad = 4.0                // hover/click margin around the ears (pt)
    var closeDelay = 1.0            // the open card stays this long after the pointer leaves (s)
    var leaveDelay = 0.3            // the preview, likewise

    // Aura
    var glowCompact = 0.16
    var falloffCompact = 9.0
    var glowExpanded = 0.45
    var falloffExpanded = 28.0
    var auraHex = "#FF4FA3"
    // Dim bloom (the default, feel B): never brighter than the ears' soft level, wide and cool,
    // tinted from the wallpaper (a fixed tint until the wallpaper is read). Off: feel A, the
    // album-coloured glow.
    var dimGlow = true
    var bloomHex = "#8F94F0"
    // Live on the real screen it read as too much at the sim's values (0.16, falloff 20 / 46), and
    // still too much at half that (0.08, 14 / 30): now a quarter as bright and about half as wide
    // (owner, 11-01).
    var bloomIntensity = 0.04       // the brightest the bloom gets (open); the ears get 3/4 of it
    var bloomFalloff = 10.0         // ears (pt)
    var bloomFalloffOpen = 22.0     // card and preview (pt)
    var glowPulse = true            // a colour pulse on opening a card (fades out in 600 ms)
    var pulseIntensity = 0.12       // the pulse's peak (the sim's 0.4 read as a giant bloom)
    var hairline = false            // a 0.5 pt white hairline on the edge

    var springs: [ShapeAnimator.Group: SpringConfig] {
        [.shape: shapeSpring, .droplet: dropletSpring, .glow: glowSpring, .color: colorSpring, .card: shapeSpring]
    }
}

@MainActor @Observable
final class TuningStore {
    private static let key = "tuning.v1"

    var tuning: Tuning {
        didSet {
            guard tuning != oldValue else { return }
            save()
            onChange?(tuning)
        }
    }

    @ObservationIgnored var onChange: ((Tuning) -> Void)?

    init() {
        tuning = Self.load() ?? Tuning()
    }

    func reset() { tuning = Tuning() }

    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(tuning)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func save() {
        var t = tuning
        t.timeScale = 1                     // slow motion is a moment, never a saved setting
        if let data = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Stored values laid over the current defaults, so adding a field later does
    /// not throw away a tuned set.
    private static func load() -> Tuning? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Tuning())) as? [String: Any]
        else { return nil }
        let merged = defaults.merging(stored) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              var t = try? JSONDecoder().decode(Tuning.self, from: mergedData) else { return nil }
        if t.dropRadius == 16 { t.dropRadius = 18 }   // the old below-the-notch default
        if t.cardHeight == 148 { t.cardHeight = 168 } // the short player, undone
        if t.earExtent == 70 { t.earExtent = 60 }     // slimmer ears (11-01)
        if t.hudExtent == 96 { t.hudExtent = 84 }
        if t.peekHeight == 68 { t.peekHeight = 76 }   // the preview holds the cover now
        if t.idleGrow == 2 { t.idleGrow = 0.5 }       // the notch at rest keeps the hardware notch's size (11-06)
        if t.idleGrow == 0.5 && t.idleDrop == 1 && t.idleRadius == 11 { t.idleGrow = 1.5; t.idleDrop = 1.5; t.idleRadius = 14 }   // rounder (11-07)
        if t.idleGrow == 1.5 && t.idleDrop == 1.5 && t.idleRadius == 14 { t.idleGrow = 2; t.idleDrop = 2; t.idleRadius = 18 }   // the ears' corners (11-07)
        t.timeScale = 1
        return t
    }
}
