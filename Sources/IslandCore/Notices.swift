import Foundation

/// Notifications in the notch (11-07; banners only since 11-11, owner: no inbox, they pass and go): a notification
/// opens as a card for a few seconds, waits in the ears, then leaves. Pure: the store reads them, the director decides
/// what shows, the views draw them. The Notification Center version lives on branch `notifications`.

/// macOS's interruption levels (`UNNotificationInterruptionLevel`, the record's `intl`).
public enum NoticeLevel: Int, Sendable, Equatable {
    case passive = 0, active = 1, timeSensitive = 2, critical = 3

    /// Comes through a Focus, like iPhone's.
    public var urgent: Bool { self == .timeSensitive || self == .critical }
}

/// One notification, as macOS keeps it. Any of title, subtitle and body may be missing.
public struct Notice: Equatable, Sendable, Identifiable {
    /// The record's UUID (hex), stable for as long as macOS keeps it.
    public let id: String
    /// The sending app's bundle ID, and its name.
    public var app: String
    public var appName: String
    public var title: String?
    public var subtitle: String?
    public var body: String?
    /// The app's thread (a conversation, a mailbox), if it gives one.
    public var thread: String?
    public var date: Date
    public var level: NoticeLevel

    public init(id: String, app: String, appName: String, title: String? = nil, subtitle: String? = nil, body: String? = nil,
                thread: String? = nil, date: Date, level: NoticeLevel = .active) {
        self.id = id
        self.app = app
        self.appName = appName
        self.title = title.nonBlank
        self.subtitle = subtitle.nonBlank
        self.body = body.nonBlank
        self.thread = thread.nonBlank
        self.date = date
        self.level = level
    }

    /// The bold line: who or what it's about, else the app.
    public var head: String { title ?? appName }
    /// The line under it is the subject and the text; with neither, the app's name (when the title took the bold line).
    public var hasText: Bool { subtitle != nil || body != nil }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// Where a notification goes when it arrives.
public enum NoticeArrival: Equatable, Sendable {
    /// Into the ears for a few seconds (hover reads it, a click opens it).
    case ears
    /// Nothing shows (macOS keeps it in its own Notification Center).
    case skip

    /// Skipped when it's passive, from the app you're at (that app shows it; on the other display it comes here), presenting, in fullscreen, locked, while the
    /// tray is open, or during a Focus unless it's time-sensitive or critical.
    public static func of(_ n: Notice, context c: DesktopContext, trayOpen: Bool) -> NoticeArrival {
        if n.level == .passive || c.presenting || c.fullscreen || c.locked || trayOpen || c.at(n.app) { return .skip }
        if c.focusOn == true && !n.level.urgent { return .skip }
        return .ears
    }
}
