import AppKit
import CoreAudio
import CoreMediaIO
import Intents
import IslandCore
import OSLog

/// Publishes where you are on the Mac (`DesktopContext`) from the system's own signals, with no
/// permission beyond Focus: the frontmost app (debounced), Space changes, fullscreen and open menus
/// (from the window list), lock and sleep, and whether the microphone or a camera is in use.
/// Typing is read at the moment it matters (`typingNow`), so nothing polls for it.
@MainActor
final class ContextMonitor {
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "context")
    private(set) var context = DesktopContext()
    var onChange: ((DesktopContext) -> Void)?
    /// The notched screen in global display coordinates (top-left origin) and its menu bar height.
    var screen: () -> (frame: CGRect, menuBarHeight: Double)? = { nil }
    /// Watch for open menus (a few times a second) while the island has something to show.
    var watchMenus = false { didSet { if watchMenus != oldValue { updatePolling() } } }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var frontDebounce: Task<Void, Never>?
    private var poll: Timer?
    /// Which Claude Code session the Claude app shows, read once a second only while that app is in front.
    private var viewedPoll: Timer?
    private var viewedReading = false
    private let claudeTitles = ClaudeWindowTitle()
    private var focusPoll: Timer?
    private var focusWatch: DispatchSourceFileSystemObject?
    private var frontTitlePoll: Timer?
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var cameras: [CMIOObjectID] = []
    private var cameraListener: CMIOObjectPropertyListenerBlock?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let windowReader = WindowReader()
    private var windowsReading = false
    /// The app whose window was last seen fullscreen: it stays fullscreen while that window does,
    /// even when the menu bar slides down under the pointer.
    private var fullscreenPID: Int32?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        observe(ws, NSWorkspace.didActivateApplicationNotification) { $0.frontmostChanged() }
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification) { $0.recheckScreen(after: [0.1, 0.7]) }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.set(\.locked, true) }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.set(\.locked, false) }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.set(\.locked, true) }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.set(\.locked, false) }
        observe(dn, Notification.Name("com.apple.screenIsLocked")) { $0.set(\.locked, true); $0.set(\.lockScreen, true) }
        observe(dn, Notification.Name("com.apple.screenIsUnlocked")) { $0.set(\.locked, false); $0.set(\.lockScreen, false) }
        if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { context.frontmostApp = app }
        startMicrophone()
        startCameras()
        startFocus()
        recheckScreen(after: [0])
        publish()
    }

    /// Typed within the last 1.5 s. Read when something would open by itself.
    func typingNow() -> Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.5
    }

    // MARK: - Frontmost app, fullscreen, menus

    private func frontmostChanged() {
        frontDebounce?.cancel()
        frontDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, app != Bundle.main.bundleIdentifier {
                context.frontmostApp = app
            }
            watchViewedSession(context.frontmostApp == Agents.app(.claude))
            watchFrontTitle(AppRules.browsers.contains(context.frontmostApp))
            recheckScreen(after: [0, 0.6])
            publish()
        }
    }

    /// The browser's front window title (its active tab), twice a second while a browser is in front: a tab switch
    /// sends no app notification. One short Accessibility read each.
    private func watchFrontTitle(_ on: Bool) {
        frontTitlePoll?.invalidate(); frontTitlePoll = nil
        guard on else { set(\.frontWindowTitle, nil); return }
        readFrontTitle()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readFrontTitle() } }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        frontTitlePoll = t
    }

    private func readFrontTitle() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var w: AnyObject?, t: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let win = w else { return }
        AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t)
        let title = t as? String
        if context.frontWindowTitle != title { context.frontWindowTitle = title; publish() }
    }

    /// The session you're looking at in the Claude app (owner, 11-07: hide only that one, so the others can be answered
    /// from the notch): its record focused last, read off the main thread once a second while the app is in front.
    /// The records are followed with FSEvents meanwhile, so a read touches only the ones that changed.
    private func watchViewedSession(_ on: Bool) {
        guard on != (viewedPoll != nil) else { return }
        viewedPoll?.invalidate(); viewedPoll = nil
        guard on else {
            FocusedSessionCache.shared.watch(nil)
            if context.viewedSession != nil { context.viewedSession = nil; publish() }
            return
        }
        FocusedSessionCache.shared.watch(AgentDirectory.live.claudeSessions)
        readViewedSession()
        // Four times a second: one Accessibility read of the window's title (cheap once its web area is found).
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readViewedSession() } }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        viewedPoll = t
    }

    private func readViewedSession() {
        guard !viewedReading,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Agents.app(.claude)).first?.processIdentifier
        else { return }
        viewedReading = true
        let titles = claudeTitles
        Task.detached(priority: .utility) { [weak self] in
            // Claude in front with none of its windows showing (owner, 11-11: the desktop, Claude's menu bar, no window):
            // you aren't looking at any session, so none leaves the notch.
            let visible = ContextSensing.showsWindow(ContextSensing.windows(), pid: pid)
            let id = visible ? AgentDirectory.live.focusedClaudeSession(title: titles.read(pid: pid)) : nil
            await MainActor.run {
                guard let self else { return }
                self.viewedReading = false
                guard self.viewedPoll != nil, self.context.viewedSession != id else { return }
                self.context.viewedSession = id
                self.publish()
            }
        }
    }

    /// Checks the window list now and again after each delay (a Space or fullscreen animation ends).
    private func recheckScreen(after delays: [Double]) {
        for d in delays {
            Task { [weak self] in
                if d > 0 { try? await Task.sleep(for: .seconds(d)) }
                self?.readWindows(force: true)
            }
        }
    }

    /// The window list, read off the main thread (`WindowReader`); one read at a time.
    private func readWindows(force: Bool = false) {
        guard !windowsReading, let s = screen() else { return }
        windowsReading = true
        let reader = windowReader
        reader.queue.async { [weak self] in
            let windows = reader.read(force: force)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.windowsReading = false
                    self?.apply(windows, screen: s)
                }
            }
        }
    }

    private func apply(_ windows: [ContextSensing.WindowInfo], screen s: (frame: CGRect, menuBarHeight: Double)) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let cover = ContextSensing.cover(windows, frontPID: front, screen: s.frame, menuBarHeight: s.menuBarHeight)
        let full = front != ownPID && ContextSensing.fullscreen(windows, frontPID: front, screen: s.frame,
                                                               menuBarHeight: s.menuBarHeight)
        // The Space says it when it can be read (a fullscreen Space, or a window over the whole screen, menu bar too);
        // the window list's guess, latched while the bar slides down under the pointer, only when it can't.
        let display = NotchGeometry.builtIn()?.0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let space = ContextSensing.activeSpaceType(display: display)
        let fullscreen: Bool
        if let space {
            fullscreenPID = nil
            fullscreen = front != ownPID && (space == ContextSensing.fullscreenSpaceType || cover == .wholeScreen)
        } else {
            if full { fullscreenPID = front } else if cover == .none || fullscreenPID != front { fullscreenPID = nil }
            fullscreen = full || fullscreenPID == front
        }
        if fullscreen != context.fullscreen {
            Self.log.notice("fullscreen \(fullscreen) (space type \(space.map(String.init) ?? "?", privacy: .public), cover \(String(describing: cover), privacy: .public), windows \(full))")
        }
        context.fullscreen = fullscreen
        context.menuOpen = ContextSensing.menuOpen(windows, ownPID: ownPID, screen: s.frame, menuBarHeight: s.menuBarHeight)
        publish()
    }

    private func updatePolling() {
        poll?.invalidate()
        poll = nil
        guard watchMenus else {
            if context.menuOpen || context.typing { context.menuOpen = false; context.typing = false; publish() }
            return
        }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Typing makes the island a little room (sim CTX2): the time since the last key, no permission needed.
                if let self { self.context.typing = self.typingNow(); self.publish() }
                self?.readWindows()
            }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    // MARK: - Microphone (CoreAudio: the default input "running somewhere")

    private func startMicrophone() {
        var defaultAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.watchInputDevice() }
        }
        watchInputDevice()
    }

    private func watchInputDevice() {
        var runningAddr = Self.runningAddress
        if inputDevice != kAudioObjectUnknown, let l = inputListener {
            AudioObjectRemovePropertyListenerBlock(inputDevice, &runningAddr, .main, l)
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        inputDevice = device
        guard device != kAudioObjectUnknown else { set(\.micInUse, false); return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readMicrophone() }
        }
        inputListener = listener
        AudioObjectAddPropertyListenerBlock(device, &runningAddr, .main, listener)
        readMicrophone()
    }

    private func readMicrophone() {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = Self.runningAddress
        AudioObjectGetPropertyData(inputDevice, &addr, 0, nil, &size, &running)
        set(\.micInUse, running != 0)
    }

    private static var runningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - Cameras (CoreMediaIO: any video device "running somewhere")

    private func startCameras() {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.watchCameras() }
        }
        watchCameras()
    }

    private func watchCameras() {
        var running = Self.cameraRunningAddress
        if let l = cameraListener {
            for c in cameras { CMIOObjectRemovePropertyListenerBlock(c, &running, .main, l) }
        }
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size)
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids)
        cameras = ids
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readCameras() }
        }
        cameraListener = listener
        for c in cameras { CMIOObjectAddPropertyListenerBlock(c, &running, .main, listener) }
        readCameras()
    }

    private func readCameras() {
        let any = cameras.contains { c in
            var running: UInt32 = 0
            var used: UInt32 = 0
            var addr = Self.cameraRunningAddress
            CMIOObjectGetPropertyData(c, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
            return running != 0
        }
        set(\.cameraInUse, any)
    }

    private static var cameraRunningAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    }

    // MARK: - Focus (on/off only, once allowed in the setup window)

    private func startFocus() {
        readFocus()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readFocus() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        focusPoll = t
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { $0.readFocus() }
    }

    func readFocus() {
        // Which mode, from macOS's Focus database when it's readable (Full Disk Access); else on or off only.
        if let state = FocusDatabase.read() {
            if context.focusOn != (state != nil) || context.focusName != state?.name {
                Self.log.notice("focus: \(state.map { "\($0.name) (\($0.identifier))" } ?? "off", privacy: .public)")
            }
            set(\.focusOn, state != nil)
            set(\.focusName, state?.name)
            set(\.focusSymbol, state?.symbol)
            watchFocusDatabase()
            return
        }
        set(\.focusName, nil)
        set(\.focusSymbol, nil)
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized else { set(\.focusOn, nil); return }
        set(\.focusOn, center.focusStatus.isFocused)
    }

    /// The database's folder changes as a Focus turns on, off or switches: read it again at once (the 30 s poll was
    /// the only signal, so a change could show half a minute late).
    private func watchFocusDatabase() {
        guard focusWatch == nil else { return }
        let fd = open(FocusDatabase.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // The files are replaced a moment after the folder changes: read once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.readFocus() } }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        focusWatch = src
    }

    // MARK: - Helpers

    private func set<V: Equatable>(_ kp: WritableKeyPath<DesktopContext, V>, _ v: V) {
        guard context[keyPath: kp] != v else { return }
        context[keyPath: kp] = v
        publish()
    }

    private var published: DesktopContext?

    private func publish() {
        guard context != published else { return }
        published = context
        onChange?(context)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (ContextMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        observers.append((center, token))
    }
}

/// The session the Claude app shows, read from its web view's title over Accessibility ("Liquid notch final changes -
/// Claude Code"): it changes the moment you switch, where the session file's `lastFocusedAt` lands ~3 s later. Electron
/// builds its tree only when asked (`AXManualAccessibility`); the web area is found once and kept. Used from one
/// background read at a time; every call has a short timeout, so a busy app can't hold it.
final class ClaudeWindowTitle: @unchecked Sendable {
    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var webArea: AXUIElement?

    func read(pid: pid_t) -> String? {
        if pid != self.pid { self.pid = pid; app = nil; webArea = nil }
        if app == nil {
            let a = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(a, 0.25)
            AXUIElementSetAttributeValue(a, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            app = a
        }
        if let w = webArea, let t = Self.title(w), !t.isEmpty { return Self.session(t) }
        webArea = nil
        guard let app else { return nil }
        // The focused window's web area with a title (breadth first, a bounded walk).
        var queue: [AXUIElement] = []
        if let w = Self.value(app, kAXFocusedWindowAttribute) { queue.append(w as! AXUIElement) }
        var seen = 0
        while !queue.isEmpty && seen < 1500 {
            let e = queue.removeFirst(); seen += 1
            if (Self.value(e, kAXRoleAttribute) as? String) == "AXWebArea", let t = Self.title(e), !t.isEmpty {
                webArea = e
                return Self.session(t)
            }
            queue += (Self.value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }

    /// "Liquid notch final changes - Claude Code" → "Liquid notch final changes".
    static func session(_ title: String) -> String? {
        let suffix = " - Claude Code"
        guard title.hasSuffix(suffix) else { return nil }
        return String(title.dropLast(suffix.count))
    }

    private static func title(_ e: AXUIElement) -> String? { value(e, kAXTitleAttribute) as? String }

    private static func value(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }
}

