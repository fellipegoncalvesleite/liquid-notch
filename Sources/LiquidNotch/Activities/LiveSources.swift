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
    private(set) var current: MeetingInfo?
    private let store = EKEventStore()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    static let lead: TimeInterval = 600

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        check()
    }

    func check() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { publish(nil); return }
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                                     end: now.addingTimeInterval(24 * 3600), calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
        let next = events.first
        let showing = next.flatMap { e in e.startDate.timeIntervalSince(now) <= Self.lead ? e : nil }
        publish(showing.map(Self.info))
        // Wake at the next boundary: when the next event comes within the lead, or when this one ends.
        let wake = showing?.endDate ?? next.map { $0.startDate.addingTimeInterval(-Self.lead) }
        timer?.invalidate()
        if let wake {
            let t = Timer(fire: max(wake, now.addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
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

    private func publish(_ m: MeetingInfo?) {
        guard m != current else { return }
        current = m
        onChange?(m)
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
