import AppKit
import ApplicationServices
import OSLog
import CoreBluetooth
import EventKit
import Intents
import NowPlaying
import SwiftUI

/// The first-run setup: every system permission is asked here, up front, with what it's for
/// (owner rule: never on first use of a feature). P2 asks for Automation (Music, Spotify);
/// later milestones add their rows (Full Disk Access, Accessibility, Calendar, Bluetooth).
@MainActor
final class SetupWindowController {
    /// v2 (11-06): the Screen recording row, shown up front once more.
    private static let doneKey = "setup.v3.done"   // v3: Watch Claude and Codex
    private var window: NSWindow?
    /// The form scrolls (11-11: it outgrew a 1112 pt screen); the Done bar stays below it.
    static let formHeight = 640.0

    /// Opens on the first launch, until Done is pressed once.
    var needed: Bool { !UserDefaults.standard.bool(forKey: Self.doneKey) }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Setup"
            w.isReleasedWhenClosed = false
            // Takes the first click even while the app isn't active: macOS may refuse to bring an
            // accessory app forward, and then the first click only activated the window.
            let host = ContentHostingView(rootView: SetupView { [weak self] in self?.finish() })
            w.contentView = host
            w.setContentSize(host.fittingSize)
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                w.setFrameTopLeftPoint(NSPoint(x: v.midX - w.frame.width / 2, y: screen.frame.maxY - 460))
            } else {
                w.center()
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }
}

struct SetupView: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    AutomationRow(symbol: "music.note", title: "Music", bundleID: PlayerNotifications.musicBundle)
                    AutomationRow(symbol: "music.note.list", title: "Spotify", bundleID: PlayerNotifications.spotifyBundle)
                    FocusRow()
                    SystemRow(symbol: "message.fill", title: "Messages",
                              detail: "Full Disk Access (add Liquid Notch with + in Settings), to read new messages",
                              status: { MessageStore.readable ? .allowed : .notAsked },
                              allow: { openSettings("Privacy_AllFiles") }, allowLabel: "Open Settings…")
                    SystemRow(symbol: "phone.fill", title: "Calls and the volume HUD",
                              detail: "Accessibility, to answer call banners and replace the volume and brightness HUD",
                              status: { AXIsProcessTrusted() ? .allowed : .notAsked },
                              allow: {
                                  _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                              })
                    SystemRow(symbol: "calendar", title: "Calendar",
                              detail: "Your next meeting and its join link",
                              status: {
                                  switch EKEventStore.authorizationStatus(for: .event) {
                                  case .fullAccess: .allowed
                                  case .denied, .restricted: .denied
                                  default: .notAsked
                                  }
                              },
                              allow: { CalendarAsk.shared.ask() },
                              settings: "Privacy_Calendars")
                    SystemRow(symbol: "record.circle", title: "Screen recording",
                              detail: "Screen Recording, to record the screen from the notch (Record, ⌃⌥⌘R)",
                              status: { CGPreflightScreenCaptureAccess() ? .allowed : .notAsked },
                              allow: { _ = CGRequestScreenCaptureAccess() },
                              settings: "Privacy_ScreenCapture")
                    SystemRow(symbol: "airpods.gen4", title: "Bluetooth",
                              detail: "AirPods connecting and their battery",
                              status: {
                                  switch CBManager.authorization {
                                  case .allowedAlways: .allowed
                                  case .denied, .restricted: .denied
                                  default: .notAsked
                                  }
                              },
                              allow: { BluetoothAsk.shared.ask() },
                              settings: "Privacy_Bluetooth")
                    AirPaneLine()
                    SystemRow(symbol: "waveform", title: "Music bars",
                              detail: "System audio, so the bars move with what's playing; nothing is recorded. Play some music, then Allow",
                              status: { UserDefaults.standard.bool(forKey: AudioBars.heardKey) ? .allowed : .notAsked },
                              allow: { AudioBars.askPermission() },
                              settings: "Privacy_ScreenCapture")
                    LockArtRow()
                    DesktopColorsRow()
                    NoticesRow()
                    AgentsRow()
                } header: {
                    Text("Liquid Notch reads what's happening on your Mac to show it around the notch. Allow what you want it to use; you can change this later in System Settings › Privacy & Security.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                } footer: {
                    Text("Music and Spotify are only controlled when Now Playing can't be read directly: to play, pause and skip, and to read the song's position. Allow… opens the app in the background so macOS can ask. Focus status is only whether a Focus is on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 10)          // in line with the header
                }
                Section {
                    FootballSection()
                } header: {
                    Text("Sports").textCase(nil)
                } footer: {
                    Text("Football, NFL, NBA, MLB and NHL: a reminder before the game, the live score, scores as they happen and the final, from ESPN's public scores. Only the search and the teams' schedules are asked for.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 10)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: SetupWindowController.formHeight)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Opens a Privacy & Security pane.
@MainActor
private func openSettings(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

private let setupLog = Logger(subsystem: "com.fellipe.liquidnotch", category: "setup")

/// Calendar asks through a store that has to live until the answer comes (a store dropped at once
/// cancels the request, so no prompt ever showed).
@MainActor
private final class CalendarAsk {
    static let shared = CalendarAsk()
    private let store = EKEventStore()
    func ask() {
        // Through the events' own store when it's running, so the answer shows the events at once.
        if let watcher = MeetingWatcher.shared {
            watcher.requestAccess { granted in setupLog.notice("calendar answer: \(granted, privacy: .public)") }
            return
        }
        store.requestFullAccessToEvents { granted, error in
            setupLog.notice("calendar answer: \(granted, privacy: .public) \(error.map { "\($0)" } ?? "", privacy: .public)")
            DispatchQueue.main.async { NotificationCenter.default.post(name: MeetingWatcher.accessChanged, object: nil) }
        }
    }
}

/// Bluetooth asks when a manager is first created.
@MainActor
private final class BluetoothAsk {
    static let shared = BluetoothAsk()
    private var manager: CBCentralManager?
    func ask() { if manager == nil { manager = CBCentralManager() } }
}

/// A row's symbol in a column of its own, so every title starts at the same edge (as in System Settings).
private struct RowIcon: View {
    let symbol: String
    var body: some View { Image(systemName: symbol).frame(width: 20) }
}

/// A permission the system holds: allowed, or a button that asks (or opens its Settings pane).
private struct SystemRow: View {
    enum Status { case allowed, denied, notAsked }

    let symbol: String
    let title: String
    let detail: String
    let status: @MainActor () -> Status
    let allow: @MainActor () -> Void
    var allowLabel = "Allow…"
    var settings: String?
    @State private var current: Status = .notAsked

    var body: some View {
        LabeledContent {
            switch current {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Button("Open Settings…") { openSettings(settings ?? "") }
            case .notAsked:
                Button(allowLabel) {
                    setupLog.notice("clicked: \(title, privacy: .public)")
                    allow()
                    current = status()
                    // Some answers come later (the music bars listen for 4 s): look again a few times, so the row turns
                    // to Allowed without another click (fresh-install check, 11-11: it stayed on "Allow…").
                    Task { @MainActor in
                        for wait in [1.0, 2.5, 5.0] {
                            try? await Task.sleep(for: .seconds(wait))
                            current = status()
                            if current == .allowed { break }
                        }
                    }
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                RowIcon(symbol: symbol)
            }
        }
        .task { current = status() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            current = status()
        }
    }
}

/// The song's art as the lock screen's wallpaper while it's there (owner, 11-07: "make this my default"; on unless turned off).
private struct LockArtRow: View {
    @State private var on = LockWallpaper.autoEnabled

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { on = $0; UserDefaults.standard.set($0, forKey: LockWallpaper.autoKey) })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Album art on the lock screen")
                    Text("While a song is on the lock screen, its cover is the wallpaper; yours comes back when you unlock.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                RowIcon(symbol: "photo.on.rectangle")
            }
        }
        .toggleStyle(.switch)
    }
}

/// The song's colours drifting on the desktop (owner, 11-07).
private struct DesktopColorsRow: View {
    @State private var on = DesktopColors.enabled

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { on = $0; UserDefaults.standard.set($0, forKey: DesktopColors.key) })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Album colours on the desktop")
                    Text("While music plays, the menu bar and the desktop take the album's colours, with a soft light on the beat; your wallpaper comes back when the music stops.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                RowIcon(symbol: "circle.hexagongrid")
            }
        }
        .toggleStyle(.switch)
    }
}

/// Notifications in the notch (11-07; banners only, off by default since 11-11): macOS's own list, read with Full Disk Access. They show only here once each app's
/// banners are off (macOS has no switch an app can turn), so the row opens that pane of System Settings.
private struct NoticesRow: View {
    @State private var on = NotificationStore.enabled
    @State private var readable = false

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: {
            on = $0
            UserDefaults.standard.set($0, forKey: NotificationStore.enabledKey)
            NotificationCenter.default.post(name: NotificationStore.toggled, object: nil)
        })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications in the notch")
                    Text(readable
                         ? "Each one opens in the notch for a few seconds, then goes. Set an app's banners to None so it shows only here."
                         : "Needs Full Disk Access (the Messages row above) to read them.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Notification Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(.link).font(.callout)
                }
            } icon: {
                RowIcon(symbol: "bell.badge")
            }
        }
        .toggleStyle(.switch)
        .task { readable = NotificationStore.readable }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in readable = NotificationStore.readable }
    }
}

/// Claude Code's and Codex's hooks (11-06): added to their settings only when switched on, taken out when switched
/// off (`HookInstaller`).
private struct AgentsRow: View {
    @State private var on = HookInstaller.installed()
    @State private var failure: String?

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: set)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch Claude and Codex")
                    Text(failure ?? "Their sessions in the notch, with Allow and Deny. Adds a hook to their settings (backed up first); Codex asks you to trust it once.")
                        .font(.callout).foregroundStyle(failure == nil ? .secondary : Color.red)
                }
            } icon: {
                RowIcon(symbol: "apple.terminal")
            }
        }
        .toggleStyle(.switch)
    }

    private func set(_ value: Bool) {
        setupLog.notice("agents hooks: \(value, privacy: .public)")
        do {
            if value { try HookInstaller.install() } else { try HookInstaller.uninstall() }
            failure = nil
        } catch HookInstaller.Failure.unreadable(let file) {
            failure = "\(file.lastPathComponent) isn't valid JSON, so it was left as it is."
        } catch {
            setupLog.error("agents hooks: \(error, privacy: .public)")
            failure = "Couldn't change their settings: \(error.localizedDescription)"
        }
        on = HookInstaller.installed()
    }
}

/// Whether a Focus is on (not which one). Hidden where the system doesn't offer it to this app.
private struct FocusRow: View {
    @State private var status = INFocusStatusCenter.default.authorizationStatus

    var body: some View {
        if status != .restricted {
            LabeledContent {
                switch status {
                case .authorized:
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    Button("Open Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Focus") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                default:
                    Button("Allow…") {
                        setupLog.notice("clicked: Focus")
                        INFocusStatusCenter.default.requestAuthorization { s in
                            Task { @MainActor in status = s }
                        }
                    }
                }
            } label: {
                Label { Text("Focus status") } icon: { RowIcon(symbol: "moon.fill") }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                status = INFocusStatusCenter.default.authorizationStatus
            }
        }
    }
}

/// One app the island may script. Allow… opens the app in the background if it isn't running
/// (the system can only ask while it runs) and shows the system prompt; once turned off, only
/// System Settings can turn it back on, so the button goes there.
private struct AutomationRow: View {
    let symbol: String
    let title: String
    let bundleID: String
    @State private var state: Status = .unknown

    enum Status { case unknown, asking, allowed, denied, notAsked, notRunning }

    var body: some View {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            LabeledContent {
                switch state {
                case .allowed:
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .asking:
                    ProgressView().controlSize(.small)
                case .denied:
                    Button("Open Settings…", action: openSettings)
                default:
                    Button("Allow…", action: allow)
                }
            } label: {
                Label { Text("Control \(title)") } icon: { RowIcon(symbol: symbol) }
            }
            .task { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                if state != .asking { refresh() }
            }
        }
    }

    /// Reads the permission off the main thread: the check can wait on the target app (it froze the island on 11-07).
    private func refresh() {
        let id = bundleID
        Task {
            let answer = await Task.detached { NowPlayingMonitor.automation(id, ask: false) }.value
            guard state != .asking else { return }
            state = switch answer {
            case .allowed: .allowed
            case .denied: .denied
            case .notAsked: .notAsked
            case .notRunning: .notRunning
            }
        }
    }

    private func allow() {
        setupLog.notice("clicked: \(title, privacy: .public)")
        state = .asking
        let id = bundleID
        Task {
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                guard await launchHidden() else { state = .notRunning; return }
            }
            // The system prompt blocks until it's answered: ask off the main thread.
            let answer = await Task.detached { NowPlayingMonitor.automation(id, ask: true) }.value
            switch answer {
            case .allowed: state = .allowed
            case .denied:
                // Turned off earlier, so the system won't ask again: System Settings is the way.
                state = .denied
                openSettings()
            default: state = .notAsked
            }
        }
    }

    /// Opens the player without bringing it forward, and waits (up to 10 s) until it runs.
    private func launchHidden() async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<40 {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                try? await Task.sleep(for: .milliseconds(500))      // let it finish launching
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Sports (v1, 11-11): search ESPN's teams in five sports and follow any; none by default, so it's off until one is picked.
private struct FootballSection: View {
    @State private var followed = FootballTeams.load()
    @State private var query = ""
    @State private var results: [FootballTeam] = []
    @State private var searching = false

    var body: some View {
        ForEach(followed, id: \.key) { t in
            HStack(spacing: 10) {
                TeamCrest(team: t)
                Text(t.name)
                Text(t.kind.name).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { FootballTeams.unfollow(t.key); followed = FootballTeams.load() }
                    .buttonStyle(.borderless)
            }
        }
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 20)
            TextField("Search for a team", text: $query)
                .textFieldStyle(.plain)
            if searching { ProgressView().controlSize(.small) }
        }
        .task(id: query) {
            let q = query
            guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(350))   // typing: one search when it pauses
            guard !Task.isCancelled else { return }
            searching = true
            let found = await FootballSearch.teams(q)
            guard !Task.isCancelled else { return }
            searching = false
            results = found
        }
        ForEach(results.filter { r in !followed.contains { $0.key == r.key } }.prefix(6), id: \.key) { t in
            HStack(spacing: 10) {
                TeamCrest(team: t)
                Text(t.name)
                Text(t.kind.name).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Follow") {
                    FootballTeams.follow(t)
                    followed = FootballTeams.load()
                    query = ""
                }
                .buttonStyle(.borderless)
            }
        }
        if followed.isEmpty && query.isEmpty {
            Text("No teams yet: sports stay off.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// A team's crest from ESPN (cached), or a dot in its colour until it loads.
private struct TeamCrest: View {
    let team: FootballTeam
    var body: some View {
        if let image = CrestStore.shared.image(team) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: 20, height: 20)
        } else {
            Circle().fill(Color(hex: team.colorHex)).frame(width: 12, height: 12).frame(width: 20, height: 20)
        }
    }
}

/// One quiet line under the AirPods row (11-11): AirPane, the owner's AirPods app, and what it adds.
private struct AirPaneLine: View {
    var body: some View {
        HStack(spacing: 6) {
            RowIcon(symbol: "airpods.gen4").hidden()
            if AirPane.installed {
                Text("AirPane is installed: it shows the popup when you open the case.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("For an iPhone-style popup when you open the case:").font(.callout).foregroundStyle(.secondary)
                Link("AirPane", destination: AirPane.site).font(.callout)
            }
            Spacer(minLength: 0)
        }
    }
}

