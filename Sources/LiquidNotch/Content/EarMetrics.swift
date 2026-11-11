/// The ears' content sizes, from the notch they hang in (11-11). Every ear was designed in the M-series notch, 37.5 pt
/// tall around a 22 pt cover (7.75 pt above and below); a shorter notch, such as a virtual one under a 24 pt menu bar,
/// scales all of it so the cover keeps `minInset` above and below: `cover = height - 2 * minInset`, never larger than
/// designed. The island never grows taller than the menu bar to make room.
enum EarMetrics {
    /// The cover in the ears, the content every other ear size was matched to.
    static let designCover = 22.0
    /// The least room above and below the ears' content.
    static let minInset = 3.0

    /// What every ear size is multiplied by: 1 in any notch tall enough for the design (all real ones), less below.
    static func scale(notchHeight: Double) -> Double {
        min(1, max(notchHeight - 2 * minInset, 0) / designCover)
    }

    /// A shape's corner or ball radius that fits the notch's height: a pill at most.
    static func radius(_ designed: Double, notchHeight: Double) -> Double {
        min(designed, notchHeight / 2)
    }
}
