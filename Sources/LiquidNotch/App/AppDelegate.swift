import AppKit
import Carbon.HIToolbox
import IslandCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var surface: NotchSurfaceController?
    private var debugPanel: DebugPanelController?
    private let setup = SetupWindowController()
    private let tuning = TuningStore()

    private let args = CommandLine.arguments
    private var recordKey: HotKey?
    private var askKey: HotKey?
    private let agentSocket = AgentSocket()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AirPane.countLaunch()   // AirPane's card never comes on the first launch
        NSApp.setActivationPolicy(.accessory)
        do {
            let renderer = try LiquidRenderer()
            let surface = NotchSurfaceController(renderer: renderer, tuning: tuning)
            self.surface = surface
            debugPanel = DebugPanelController(store: tuning, surface: surface)
        } catch {
            NSLog("Liquid Notch: \(error)")
            NSApp.terminate(nil)
            return
        }
        // No menu bar icon (owner, 11-06): the menu opens on a right-click on the island.
        surface?.contextMenu = { [unowned self] hit in makeMenu(hit) }
        // Recording from the notch (11-06): ScreenCaptureKit, ⌃⌥⌘R anywhere (⌘⇧5 is macOS's own); a missing
        // permission opens Setup at its row instead of prompting on first use.
        if let d = surface?.director {
            d.recorder = ScreenRecorder()
            d.onNeedsSetup = { [unowned self] in setup.show() }
            recordKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | cmdKey) { d.recordToggle() }
            // Quick ask (phase 3): ⌥Space (the key tap, `MediaKeyTap.onAskKey`), and ⌃⌥⌘A as a backup that needs no permission.
            askKey = HotKey(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey | cmdKey) { d.toggleAsk() }
            // Claude and Codex (phase 2): their hooks write here once Setup's "Watch Claude and Codex" adds them.
            agentSocket.onLine = { d.agentHook($0, reply: $1) }
            HookInstaller.refreshScript()   // an installed hook's script keeps up with updates (our own file only)
            LockWallpaper.shared.recoverIfNeeded()   // the album art left as the wallpaper by a quit mid-swap goes back
            // An update changed our entries' timeouts (a question now waits up to 10 minutes for your pick): rewrite only
            // ours, each file backed up first (11-07, owner: "I should be able to click on the answer here").
            if HookInstaller.needsUpgrade() { try? HookInstaller.install() }
            agentSocket.start()
        }
        if args.contains("--debug") { debugPanel?.toggle() }
        if (setup.needed && !args.contains("--no-setup")) || args.contains("--setup") { setup.show() }
        if args.contains("--spike") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                Spikes.run()
            }
        }
    }

    /// Opening the app again (Finder, Spotlight) while it runs shows Setup, the way back in
    /// without a menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setup.show()
        return false
    }

    /// One right-click model (11-06, `2026-11-06-many-bubbles-design.md`): the island's own items first (hide what's under
    /// the pointer, what's running off the island, what's hidden), then the app's.
    private func makeMenu(_ hit: HitRegion?) -> NSMenu {
        let menu = NSMenu()
        for entry in surface?.director.menuEntries(at: hit) ?? [] {
            switch entry {
            case .hide(let p, let title): partyItem(menu, title, p, #selector(hideParty(_:)))
            case .show(let p, let title): partyItem(menu, title, p, #selector(showParty(_:)))
            case .open(let p, let title, let status):
                let item = partyItem(menu, title, p, #selector(openParty(_:)))
                if !status.isEmpty { item.subtitle = status }
            case .header(let title): menu.addItem(.sectionHeader(title: title))
            case .separator: menu.addItem(.separator())
            }
        }
        // Timers start here (11-01 design): the island itself doesn't change.
        let timer = NSMenu()
        for minutes in [1, 5, 10, 25] {
            let item = timer.addItem(withTitle: "\(minutes) min", action: #selector(startTimer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
        }
        menu.addItem(withTitle: "Timer", action: nil, keyEquivalent: "").submenu = timer
        // The music bars follow what's playing, or animate (owner, 11-06).
        let bars = NSMenu()
        for mode in AudioBars.Mode.allCases {
            let item = bars.addItem(withTitle: mode == .realAudio ? "Real Audio" : "Animated", action: #selector(setBars(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = surface?.bars.mode == mode ? .on : .off
        }
        menu.addItem(withTitle: "Music Bars", action: nil, keyEquivalent: "").submenu = bars
        menu.addItem(.separator())
        menu.addItem(withTitle: "Setup…", action: #selector(showSetup), keyEquivalent: "").target = self
        // AirPane (11-11): opens its site, or AirPane itself once it's here.
        let paired = AirPane.installed
        let airPane = menu.addItem(withTitle: paired ? "Paired with AirPane" : "Pair with AirPane", action: #selector(openAirPane),
                                   keyEquivalent: "")
        airPane.target = self
        airPane.state = paired ? .on : .off
        // The debug panel (samples, chess, tuning) is for development: ⌥ held while the menu opens, or `--debug` (v1).
        if NSEvent.modifierFlags.contains(.option) || CommandLine.arguments.contains("--debug") {
            menu.addItem(withTitle: "Debug Panel", action: #selector(toggleDebug), keyEquivalent: "d").target = self
        }
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Liquid Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        LockWallpaper.shared.restoreOnQuit()   // never leave someone's wallpaper behind
        agentSocket.stop()
        surface?.stop()
    }

    @objc private func toggleDebug() { debugPanel?.toggle() }

    @objc private func showSetup() { setup.show() }

    @objc private func openAirPane() { AirPane.open() }

    @objc private func setBars(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = AudioBars.Mode(rawValue: raw) { surface?.bars.mode = mode }
    }

    @objc private func startTimer(_ sender: NSMenuItem) { surface?.director.startTimer(minutes: sender.tag) }

    @discardableResult
    private func partyItem(_ menu: NSMenu, _ title: String, _ p: Party, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = p
        return item
    }

    @objc private func hideParty(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? Party { surface?.director.hide(p) }
    }

    @objc private func showParty(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? Party { surface?.director.unhide(p) }
    }

    @objc private func openParty(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? Party { surface?.director.openCard(p) }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Liquid Notch: launch at login: \(error)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
