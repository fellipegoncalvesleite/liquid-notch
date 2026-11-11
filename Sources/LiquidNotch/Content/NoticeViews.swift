import AppKit
import IslandCore
import SwiftUI

/// Notifications in the notch (11-07, sim `ACT.notice`, `noteCard`, `noteRow`): the app's icon and who it's from in the
/// ears, and the card it arrives as (laid out like Messages: × and Open in <App> where its reply sits). Every field may
/// be missing; the app's name stands in.

/// The app's own icon, or a bell on a plain tile for an app that isn't on this Mac.
struct NoticeIcon: View {
    let app: String
    let size: Double

    var body: some View {
        if let icon = AppIcons.icon(for: app) {
            // macOS icons carry a margin: drawn a little larger, the tile fills the size like iOS's.
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: size * 1.2, height: size * 1.2)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bell.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(.white.opacity(0.18)))
        }
    }
}

/// The line under the bold one: the subject in semibold, then the text; with neither, the app's name, dimmed.
struct NoticeText: View {
    let notice: Notice
    var font: Font = IslandType.body

    var body: some View {
        if notice.hasText {
            (Text(notice.subtitle.map { $0 + " " } ?? "").fontWeight(.semibold).foregroundStyle(.white.opacity(0.9))
             + Text(notice.body ?? "").foregroundStyle(.white.opacity(0.85)))
                .font(font)
        } else if notice.title != nil {
            Text(notice.appName).font(font).foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// When it came, or that it can't wait (iOS's "Time Sensitive" in the banner's place for the time).
struct NoticeWhen: View {
    let notice: Notice
    let now: Date
    var font: Font = IslandType.secondary

    var body: some View {
        switch notice.level {
        case .critical: Text("Critical").font(font.weight(.semibold)).foregroundStyle(IslandColor.red)
        case .timeSensitive: Text("Time Sensitive").font(font).foregroundStyle(IslandColor.orange)
        default: Text(Self.ago(notice.date, now: now)).font(font).foregroundStyle(IslandColor.dim)
        }
    }

    static func ago(_ d: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        return m < 1 ? "now" : m < 60 ? "\(m)m ago" : m < 24 * 60 ? "\(m / 60)h ago" : "Yesterday"
    }
}

/// The ears: the app's icon left, the bold line right (a name, a group, an event).
struct NoticeEar: View {
    let notice: Notice
    let side: EarSide
    @Environment(\.presenting) private var presenting

    var body: some View {
        if side == .left {
            NoticeIcon(app: notice.app, size: 22).entrance(side, 0)
        } else {
            // The whole title if it fits, else its first word (a person's first name, like the sim), else cut short.
            let full = presenting ? notice.appName : notice.head
            let first = full.split(separator: " ").first.map(String.init) ?? full
            ViewThatFits(in: .horizontal) {
                Text(full).fixedSize()
                Text(first).fixedSize()
                Text(full)
            }
            .font(IslandType.ear)
            .frame(maxWidth: 66, alignment: .trailing).entrance(side, 0)
        }
    }
}

/// The card it opens as (by itself on arrival, or on hover): the icon, who and when, two lines; × dismisses it, the pill
/// opens it in its app.
struct NoticeCard: View {
    let notice: Notice
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        VStack(spacing: 10) {
            Button { director.openNotice(notice) } label: {
                HStack(alignment: .top, spacing: 12) {
                    NoticeIcon(app: notice.app, size: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(presenting ? notice.appName : notice.head).font(IslandType.title).lineLimit(1)
                            Spacer(minLength: 4)
                            NoticeWhen(notice: notice, now: director.date())
                        }
                        // Never show what it says while presenting.
                        Group {
                            if presenting { Text("Hidden while presenting").font(IslandType.body).foregroundStyle(.white.opacity(0.5)) }
                            else { NoticeText(notice: notice) }
                        }
                        .lineLimit(2).lineSpacing(1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(notice.head)")
            .rise(0)
            HStack(spacing: 10) {
                RoundButton(symbol: "xmark", style: .gray, size: 32, label: "Clear") { director.dismissNotice(notice) }
                Button { director.openNotice(notice) } label: {
                    Text("Open in \(notice.appName)").font(IslandType.body.weight(.medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle(pressed: 0.97, hover: 1))
            }
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}
