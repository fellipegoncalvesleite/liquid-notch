import Foundation
import IslandCore

/// The debug panel's and the stills' notifications (sim `ARRIVALS`, `NOTES_SAMPLE`): every shape and level, in turn.
/// The people are invented; the apps are the Mac's own where it has them (their real names and icons).
enum NoticeSamples {
    private static func n(_ id: String, _ app: String, _ name: String, title: String? = nil, subtitle: String? = nil, body: String? = nil,
                          thread: String? = nil, ago: Double = 0, level: NoticeLevel = .active, now: Date) -> Notice {
        Notice(id: "sample-" + id, app: app, appName: name, title: title, subtitle: subtitle, body: body, thread: thread,
               date: now.addingTimeInterval(-ago), level: level)
    }

    /// Sent in turn by the debug panel's Notification button.
    static func arrivals(now: Date) -> [Notice] {
        [
            n("mail", "com.apple.mail", "Mail", title: "Beatriz Lima", subtitle: "Re: Saturday",
              body: "Sounds good! See you at the market at ten, I'll bring the bags.", now: now),
            n("cal", "com.apple.iCal", "Calendar", title: "Design review", body: "In 10 minutes · Studio 3", level: .timeSensitive, now: now),
            n("wa", "net.whatsapp.WhatsApp", "WhatsApp", title: "Família", body: "Ana: Photos from today 📸 the kids loved the beach",
              thread: "fam", now: now),
            n("upd", "com.apple.systempreferences", "System Settings", title: "macOS 27.1 is ready to install", now: now),   // a title alone
            n("find", "com.apple.findmy", "Find My", body: "Your AirPods were left behind at Home", now: now),               // a body alone
            n("store", "com.apple.AppStore", "App Store", title: "3 apps were updated", level: .passive, now: now),           // the center only
            n("rem", "com.apple.reminders", "Reminders", title: "Call the dentist", body: "Today, 16:00", now: now),
        ]
    }

    /// What the stills' center holds: a thread's stack, a person's mail, a title alone.
    static func center(now: Date) -> [Notice] {
        [
            n("w1", "net.whatsapp.WhatsApp", "WhatsApp", title: "Família", body: "Pedro: I can pick it up on the way", thread: "fam", ago: 12 * 60, now: now),
            n("w2", "net.whatsapp.WhatsApp", "WhatsApp", title: "Família", body: "Ana: Who's bringing the cake on Sunday? 🎂", thread: "fam", ago: 14 * 60, now: now),
            n("m1", "com.apple.mail", "Mail", title: "Lucas Ferreira", subtitle: "October invoice",
              body: "Hi! The invoice for October is attached. Let me know if anything looks off.", ago: 38 * 60, now: now),
            n("s1", "com.apple.systempreferences", "System Settings", title: "macOS 27.1 is ready to install", ago: 125 * 60, now: now),
        ]
    }
}
