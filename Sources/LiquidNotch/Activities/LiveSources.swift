import AppKit
import EventKit
import IOBluetooth
import IOKit.ps
import OSLog

private let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "activities")

/// The battery and the power adapter (IOKit power sources; no permission). Reports every change, and
/// `onPlugIn` when an adapter is connected.
@MainActor
final class PowerMonitor {
    private(set) var info: PowerInfo?
    var onChange: ((PowerInfo) -> Void)?
    var onPlugIn: ((PowerInfo) -> Void)?
    /// The battery dropped past 20% or past 10% while unplugged.
    var onLow: ((PowerInfo) -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.read() }
        }, me)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        read()
    }

    /// The battery went from above 20% to 20% or below, or likewise past 10%.
    nonisolated static func crossedLow(from before: Int, to after: Int) -> Bool {
        [20, 10].contains { before > $0 && after <= $0 }
    }

    static func current() -> PowerInfo? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let toFull = d[kIOPSTimeToFullChargeKey] as? Int
            let toEmpty = d[kIOPSTimeToEmptyKey] as? Int
            let watts = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?[kIOPSPowerAdapterWattsKey] as? Int
            return PowerInfo(level: d[kIOPSCurrentCapacityKey] as? Int ?? 0,
                             charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                             onAdapter: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                             watts: watts, minutesToFull: toFull.flatMap { $0 > 0 ? $0 : nil },
                             minutesToEmpty: toEmpty.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }

    private func read() {
        guard let now = Self.current() else { return }
        let was = info
        info = now
        guard now != was else { return }
        onChange?(now)
        if let was, !was.onAdapter, now.onAdapter {
            log.notice("power: adapter connected (\(now.level, privacy: .public)%)")
            onPlugIn?(now)
        }
        if let was, !now.onAdapter, Self.crossedLow(from: was.level, to: now.level) {
            log.notice("power: low battery (\(now.level, privacy: .public)%)")
            onLow?(now)
        }
    }
}

/// The next event from Calendar, from 10 minutes before it starts until it ends. Rechecks when the
/// calendar changes, at the next boundary, and on wake.
@MainActor
final class MeetingWatcher {
    var onChange: ((MeetingInfo?) -> Void)?
    /// Today's events, all-day first, then by start (the day view).
    var onAgenda: (([AgendaItem]) -> Void)?
    private(set) var current: MeetingInfo?
    private(set) var agenda: [AgendaItem] = []
    private let store = EKEventStore()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    static let lead: TimeInterval = 600

    /// Posted when Calendar access may have changed (Setup's Allow, or coming back from System Settings).
    static let accessChanged = Notification.Name("MeetingWatcher.accessChanged")
    /// The one store the app reads events through; Setup asks through it too, so the answer reaches the events at once
    /// (a separate store got the grant while this one, created before it, kept showing nothing).
    static weak var shared: MeetingWatcher?

    func start() {
        Self.shared = self
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Self.accessChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        // Back from System Settings (Privacy › Calendars toggled there): read the access again.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        check()
    }

    /// Asks for full Calendar access through this store; on an answer the store is reset and the events read.
    func requestAccess(_ done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            reload()
            done?(granted)
        }
    }

    /// Access may have changed: a store made before the grant answers nothing until it's reset.
    private func reload() {
        store.reset()
        check()
    }

    func check() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { publish(nil); publishAgenda([]); return }
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? now.addingTimeInterval(86400)
        let calendars = shownCalendars()
        // Every calendar turned off: nothing shows (an empty list would mean "all" to EventKit).
        let all = calendars?.isEmpty == true ? [] : store.events(matching: store.predicateForEvents(
            withStart: min(dayStart, now.addingTimeInterval(-12 * 3600)),
            end: max(dayEnd, now.addingTimeInterval(24 * 3600)), calendars: calendars))
            .filter { $0.status != .canceled && !Self.declined($0) }
        publishAgenda(all.filter { $0.startDate < dayEnd && $0.endDate > dayStart }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map(Self.agendaItem))

        // With several on at once (a class and lunch overlapping), the one that started last or is about to start: lunch
        // at 12:30 shows from 12:20 even though the 9:30 class runs till 13:30.
        let timed = all.filter { !$0.isAllDay && $0.endDate > now }
        let showing = timed.filter { $0.startDate.timeIntervalSince(now) <= Self.lead }.max { $0.startDate < $1.startDate }
        publish(showing.map(Self.info))

        // Wake at the next boundary: an event coming within the lead, starting, or ending.
        let wake = timed.flatMap { [$0.startDate.addingTimeInterval(-Self.lead), $0.startDate, $0.endDate] }
            .filter { $0 > now }.min()
        timer?.invalidate()
        if let wake {
            let t = Timer(fire: max(wake, now.addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    // MARK: Which calendars show

    /// Calendars turned off in the right-click menu's Calendars submenu (by identifier; new calendars show by default).
    static let hiddenKey = "hiddenCalendars"
    static var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenKey) }
    }

    struct CalendarChoice {
        let id: String
        let title: String
        let account: String
        let color: NSColor
        let shown: Bool
    }

    /// Every event calendar, by account then title, with whether it shows.
    func calendarChoices() -> [CalendarChoice] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let hidden = Self.hidden
        return store.calendars(for: .event)
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title.trimmingCharacters(in: .whitespaces),
                                  account: $0.source?.title ?? "Other", color: NSColor(cgColor: $0.cgColor) ?? .gray,
                                  shown: !hidden.contains($0.calendarIdentifier)) }
            .sorted { ($0.account, $0.title.lowercased()) < ($1.account, $1.title.lowercased()) }
    }

    func setCalendar(_ id: String, shown: Bool) {
        var h = Self.hidden
        if shown { h.remove(id) } else { h.insert(id) }
        Self.hidden = h
        check()
    }

    func showAllCalendars() {
        Self.hidden = []
        check()
    }

    /// The calendars to read: all but the hidden ones (nil: all).
    private func shownCalendars() -> [EKCalendar]? {
        let hidden = Self.hidden
        guard !hidden.isEmpty else { return nil }
        return store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private static func info(_ e: EKEvent) -> MeetingInfo {
        let people = (e.attendees ?? []).filter { !$0.isCurrentUser }
        let names = people.map { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
        return MeetingInfo(title: e.title ?? "Event", start: e.startDate, end: e.endDate,
                           joinURL: MeetingInfo.joinLink(in: [e.url?.absoluteString, e.location, e.notes]),
                           initials: names.prefix(3).map(MeetingInfo.initials), more: max(names.count - 3, 0))
    }

    /// The calendar's colour as `#RRGGBB` (grey when it has none).
    private static func hex(of e: EKEvent) -> String {
        guard let c = e.calendar?.cgColor.flatMap({ NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) else { return "#8E8E93" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private static func agendaItem(_ e: EKEvent) -> AgendaItem {
        AgendaItem(id: "\(e.eventIdentifier ?? UUID().uuidString)@\(e.startDate.timeIntervalSince1970)",
                   title: e.title ?? "Event", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                   calendar: e.calendar?.title.trimmingCharacters(in: .whitespaces) ?? "", colorHex: hex(of: e))
    }

    private func publish(_ m: MeetingInfo?) {
        guard m != current else { return }
        current = m
        onChange?(m)
    }

    private func publishAgenda(_ a: [AgendaItem]) {
        guard a != agenda else { return }
        agenda = a
        onAgenda?(a)
    }
}

/// AirPods connecting, with their battery. IOBluetooth posts its notifications on a background queue,
/// so every handler hops to main (handling them in place crashed AirPane's first live run).
@MainActor
final class PodsWatcher: NSObject {
    var onConnect: ((PodsInfo) -> Void)?
    var onUpdate: ((PodsInfo) -> Void)?
    private var connectNote: IOBluetoothUserNotification?

    func start() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc nonisolated private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handleConnect(address) } }
    }

    private func handleConnect(_ address: String?) {
        guard let address, let device = IOBluetoothDevice(addressString: address),
              (device.name ?? "").localizedCaseInsensitiveContains("AirPods") else { return }
        let info = Self.read(device)
        log.notice("airpods: connected; battery known \(info.buds != nil, privacy: .public)")
        onConnect?(info)
        // The battery often arrives a moment after the connection.
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let d = IOBluetoothDevice(addressString: address), d.isConnected() else { return }
                    self?.onUpdate?(Self.read(d))
                }
            }
        }
    }

    /// The private battery getters, read only if the device answers them.
    static func read(_ d: IOBluetoothDevice) -> PodsInfo {
        func level(_ key: String) -> Int? {
            guard d.responds(to: NSSelectorFromString(key)), let v = d.value(forKey: key) as? NSNumber, v.intValue > 0
            else { return nil }
            return min(v.intValue, 100)
        }
        return PodsInfo(name: d.name ?? "AirPods", left: level("batteryPercentLeft"), right: level("batteryPercentRight"),
                        caseLevel: level("batteryPercentCase"), single: level("batteryPercentSingle"))
    }
}
