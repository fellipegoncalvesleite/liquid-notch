import AppKit

/// Supporting Liquid Notch (11-11): a permanent "Support Liquid Notch" item in the island's menu, and one card, once,
/// for people who use it: a week after the first launch and after five launches. Whatever happens to that card it
/// never comes back (`hasShownSupportPrompt`). The same link as the README's coffee button.
enum Support {
    static let url = URL(string: "https://www.paypal.com/ncp/payment/8ZCX7UBTXTXXN")!

    static let firstLaunchKey = "support.firstLaunch"
    static let launchesKey = "support.launches"
    static let shownKey = "hasShownSupportPrompt"
    static let daysBefore = 7.0
    static let launchesBefore = 5

    /// The card is due: a week since the first launch, five launches, never shown. No first-launch date yet: not due.
    static func due(firstLaunch: Date?, launches: Int, shown: Bool, now: Date) -> Bool {
        guard !shown, let first = firstLaunch else { return false }
        return launches >= launchesBefore && now.timeIntervalSince(first) >= daysBefore * 86_400
    }

    /// Counts a launch, and dates the first one if no launch was dated yet (existing users start their week today).
    static func recordLaunch(_ d: UserDefaults = .standard, now: Date = Date()) {
        if d.object(forKey: firstLaunchKey) == nil { d.set(now, forKey: firstLaunchKey) }
        d.set(d.integer(forKey: launchesKey) + 1, forKey: launchesKey)
    }

    static func isDue(_ d: UserDefaults = .standard, now: Date = Date()) -> Bool {
        due(firstLaunch: d.object(forKey: firstLaunchKey) as? Date, launches: d.integer(forKey: launchesKey),
            shown: d.bool(forKey: shownKey), now: now)
    }

    static func open() { NSWorkspace.shared.open(url) }
}
