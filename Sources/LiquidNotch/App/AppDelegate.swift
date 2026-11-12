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
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A public build opened outside Applications moves there first and opens again (11-11).
        if ApplicationInstaller.moveIfNeeded(arguments: args) { return }
        startApplication()
    }

    private func startApplication() {
        AirPane.countLaunch()   // AirPane's card never comes on the first launch
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
        // The one-time support card (11-11): each launch counts; it's looked for a few seconds after launch and after
        // waking, and shows only when due and the island is idle. `-forceSupportPrompt` shows it regardless (testing).
        Support.recordLaunch()
        let forceSupport = args.contains("-forceSupportPrompt")
        lookForSupportCard(after: 8, force: forceSupport)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForSupportCard(after: 5, force: forceSupport) }
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

    private func lookForSupportCard(after seconds: Double, force: Bool) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.surface?.director.maybeShowSupportCard(force: force)
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
        // Grouped (players asked "where do I click": the flat list read as random): what the island can open, how it
        // looks, the app.
        if menu.items.count > 0 { menu.addItem(.separator()) }
        menu.addItem(.sectionHeader(title: "Island"))
        menu.addItem(withTitle: "Tools", action: #selector(openTools), keyEquivalent: "").target = self
        if surface?.director.island.mediaOn == true {
            menu.addItem(withTitle: "Player & Lyrics", action: #selector(openPlayerFocus), keyEquivalent: "").target = self
        }
        let focusClick = menu.addItem(withTitle: "Click Opens Lyrics", action: #selector(toggleClickOpensFocus(_:)), keyEquivalent: "")
        focusClick.target = self
        focusClick.state = UserDefaults.standard.bool(forKey: "clickOpensFocus") ? .on : .off
        focusClick.toolTip = "A click on the music opens the big player with lyrics. Scroll down on the island for the small player and the tools."
        // Timers start here (11-01 design): the island itself doesn't change.
        let timer = NSMenu()
        for minutes in [1, 5, 10, 25] {
            let item = timer.addItem(withTitle: "\(minutes) min", action: #selector(startTimer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
        }
        menu.addItem(withTitle: "Start Timer", action: nil, keyEquivalent: "").submenu = timer

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Appearance"))
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
        // Which screen, and real or virtual notch (11-11).
        NotchMenu.shared.add(to: menu)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Liquid Notch"))
        menu.addItem(withTitle: "Setup & Permissions…", action: #selector(showSetup), keyEquivalent: ",").target = self
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        NotchMenu.shared.addUpdates(to: menu)
        // AirPane (11-11): opens its site, or AirPane itself once it's here.
        let paired = AirPane.installed
        let airPane = menu.addItem(withTitle: paired ? "Paired with AirPane" : "Pair with AirPane", action: #selector(openAirPane),
                                   keyEquivalent: "")
        airPane.target = self
        airPane.state = paired ? .on : .off
        menu.addItem(withTitle: "Support Liquid Notch", action: #selector(support), keyEquivalent: "").target = self
        // The debug panel (samples, chess, tuning) is for development: ⌥ held while the menu opens, or `--debug` (v1).
        if NSEvent.modifierFlags.contains(.option) || CommandLine.arguments.contains("--debug") {
            menu.addItem(withTitle: "Debug Panel", action: #selector(toggleDebug), keyEquivalent: "d").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall Liquid Notch…", action: #selector(uninstall), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Liquid Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func toggleClickOpensFocus(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.state != .on, forKey: "clickOpensFocus")
    }

    @objc private func openTools() { surface?.director.openTray() }
    @objc private func openPlayerFocus() { surface?.director.openFocus() }

    func applicationWillTerminate(_ notification: Notification) {
        LockWallpaper.shared.restoreOnQuit()   // never leave someone's wallpaper behind
        agentSocket.stop()
        surface?.stop()
    }

    @objc private func toggleDebug() { debugPanel?.toggle() }

    @objc private func showSetup() { setup.show() }

    @objc private func uninstall() { Uninstaller.confirmAndRun() }

    @objc private func openAirPane() { AirPane.open() }

    @objc private func support() { Support.open() }

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
