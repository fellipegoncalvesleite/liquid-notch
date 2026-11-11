import AppKit

/// AirPane (airpane.app) is the owner's AirPods app: an iPhone-style popup when the case opens, the buds in 3D, battery
/// and audio switching. The two pair (11-11): when AirPane is installed it shows the AirPods popup and the notch doesn't
/// show a second one; without it Liquid Notch works exactly as before. Found by its bundle ID through NSWorkspace only.
/// Tasteful by rule: no banners or badges, no "Pro" or "upgrade" wording, nothing on first launch, nothing in the way of
/// a feature, one card at most, and "Don't show again" is forever.
enum AirPane {
    static let bundleID = "dev.fellipe.earshot"
    static let site = URL(string: "https://airpane.app")!

    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// Opens AirPane if it's here, else its site.
    static func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(site)
        }
    }

    // MARK: The one-time card

    static let connectsKey = "airpane.podsConnects"
    static let launchesKey = "airpane.launches"
    /// Shown once, or "Learn more" / "Don't show again": never again.
    static let cardDoneKey = "airpane.cardDone"
    static let connectsBeforeCard = 3

    /// The card is due: AirPane isn't here, the AirPods have connected a few times, this isn't the first launch, it was
    /// never shown or turned off, and nothing else is on the island (no music, no other activity).
    static func cardDue(connects: Int, launches: Int, installed: Bool, done: Bool, busy: Bool) -> Bool {
        !installed && !done && launches >= 2 && connects >= connectsBeforeCard && !busy
    }

    static func countLaunch(_ d: UserDefaults = .standard) { d.set(d.integer(forKey: launchesKey) + 1, forKey: launchesKey) }
}
