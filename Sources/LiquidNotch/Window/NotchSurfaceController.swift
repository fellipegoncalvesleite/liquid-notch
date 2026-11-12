import AppKit
import IslandCore
import NowPlaying
import OSLog
import QuartzCore
import SwiftUI

/// Owns the panel on the notched screen and wires the island -> presentation -> motion
/// -> render, with the SwiftUI content layer riding on top of the liquid.
///
/// Also keeps the panel click-through everywhere except on the liquid itself:
/// mouse moves are hit-tested with the simulator's rule (`ShapeSDF.hit`).
@MainActor
final class NotchSurfaceController {
    /// Room for the card plus its glow, even dragged down: at 300 pt the glow was cut off in a hard line.
    static let panelSize = CGSize(width: 760, height: 420)

    let director = IslandDirector()
    /// What's playing on the Mac (P2): the adapter, else the players' notifications.
    private let nowPlaying = NowPlayingMonitor(adapter: AdapterLocation.find(sourceRoot: NotchSurfaceController.sourceRoot))
    /// Where you are on the Mac (P3).
    private let desktop = ContextMonitor()
    /// Live activities (P4).
    private let power = PowerMonitor()
    private let meetings = MeetingWatcher()
    private let pods = PodsWatcher()
    private let transfers = TransferWatcher()
    /// macOS's notification list (11-07): every app's notifications come to the notch.
    private let notices = NotificationStore()
    private let football = FootballWatcher()
    private let calls = CallBannerProbe()
    private let clipboard = ClipboardWatcher()
    let keys = MediaKeyTap()
    private var keyRetry: Timer?
    private let panel = NotchPanel()
    private let container = DropView()
    private let view: LiquidView
    private let content = NotchContentModel()
    /// The music bars' audio (owner, 11-06): tapped only while a real song plays and the bars are on the island.
    let bars = AudioBars()
    private let frameModel = FrameModel()
    private let animator: ShapeAnimator
    private let tuningStore: TuningStore
    private var clock: FrameClock!
    private var geometry: NotchGeometry?
    private var constants: SurfaceConstants?
    private var context = TargetContext()
    private var peekLeaveEnd: Scheduled?
    private(set) var mode: PresentationMode = .idle
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var pulseStart: Double?
    private let delights = Delights()
    private var overIsland = false
    private var wasHidden = false
    /// Hover intent: the last pointer sample, and the re-check once it stops (`updateMouse`).
    private var lastMouse: (p: SIMD2<Double>, at: Double) = (.zero, 0)
    private var intentCheck: Timer?
    /// Until then the panel keeps the pointer (a double-click's second press after the player opened).
    private var holdMouseUntil = 0.0
    /// Faster than this (points a second) over the island is passing through.
    static let hoverIntentSpeed = 450.0
    /// The lock screen: the island joins the lock space while it's up, and the music card shows below the clock.
    private lazy var lockCard = LockCardController(director: director)
    /// The song's colours drifting on the desktop (11-07).
    private let desktopColors = DesktopColors()
    private var wasLockScreen = false
    private var lockLeave: Scheduled?
    /// While locked, the input idle time four times a second: recent input shows the fingerprint for 2.5 s.
    private var lockInputPoll: Timer?
    /// The rainbow's colour while it runs (easter egg), over the island's own.
    private var auraOverride: String?
    private var pulseColor = SIMD3<Double>(1, 1, 1)
    /// Animator time: real time multiplied by the debug time scale, so slow motion slows the
    /// choreography delays and the sample clocks too.
    private var animatorTime = 0.0
    private var animatorTimeAt = CACurrentMediaTime()

    /// Debug: Reduce Motion on regardless of the system setting.
    var forceReduceMotion = false { didSet { updateReduceMotion() } }

    /// Fired after every rendered frame (debug readouts).
    var onFrame: ((ShapeFrame) -> Void)?

    /// The app's menu, shown on a right-click on the island (there's no menu bar icon).
    /// The island's right-click menu, for what's under the pointer.
    var contextMenu: ((HitRegion?) -> NSMenu)?

    init(renderer: LiquidRenderer, tuning: TuningStore) {
        tuningStore = tuning
        view = LiquidView(renderer: renderer)
        let t = tuning.tuning
        animator = ShapeAnimator(initial: ShapeState(mainHalfWidth: 0, mainHeight: 0, mainRadius: 0),
                                 configs: t.springs, dynamics: t.dynamics)
        animator.cardBridge = (t.cardNeckMax, t.cardBreakGap)
        clock = FrameClock { [unowned self] dt in
            let moving = animator.advance(dt)
            render()
            return moving || pulseAmount > 0
        }
        clock.timeScale = t.timeScale

        container.frame = NSRect(origin: .zero, size: Self.panelSize)
        view.frame = container.bounds
        container.addSubview(view)
        let host = ContentHostingView(rootView: NotchContentView(model: content, frame: frameModel, director: director))
        host.sizingOptions = []            // never let SwiftUI resize the panel
        host.frame = container.bounds
        container.addSubview(host)
        panel.contentView = container

        content.onPress = { [weak self] p in self?.pointerDown(p) }
        director.notchHalfWidth = { [weak self] in self?.geometry.map { Double($0.notchWidth) / 2 } ?? 104 }
        director.notchHeight = { [weak self] in self?.geometry.map { Double($0.notchHeight) } ?? 37.5 }
        content.onDrag = { [weak self] p in self?.director.pointerDragged(to: p) }
        content.onRelease = { [weak self] p in self?.pointerUp(p) }
        container.onEnter = { [weak self] in self?.director.fileDragEntered() ?? false }
        container.onDrop = { [weak self] urls in self?.director.filesDropped(urls) }
        wireDirector()
        wireTray()

        tuning.onChange = { [weak self] t in self?.apply(tuning: t) }
        nowPlaying.onChange = { [weak self] np in
            Self.log.info("now playing: \(np?.bundleID ?? "nothing", privacy: .public) \(np.map { $0.playing ? "playing" : "paused" } ?? "", privacy: .public)")
            self?.director.nowPlayingChanged(np)
        }
        nowPlaying.onSource = { [weak self] s in
            Self.log.info("now playing source: \(s.rawValue, privacy: .public)")
            self?.director.nowPlayingSource = s.rawValue
        }
        director.sendCommand = { [weak self] c in self?.nowPlaying.send(c) }
        director.sendCommandTo = { [weak self] c, app in self?.nowPlaying.send(c, to: app) }
        nowPlaying.onSecond = { [weak self] np in self?.director.nowPlaying2Changed(np) }
        director.sendSeek = { [weak self] seconds in self?.nowPlaying.seek(to: seconds) }
        director.sendShuffle = { [weak self] on in self?.nowPlaying.setShuffle(on) }
        director.sendRepeat = { [weak self] mode in self?.nowPlaying.setRepeat(mode) }
        director.probeModes = { [weak self] done in self?.nowPlaying.probeModes(done) }
        director.clickOpensFocus = { UserDefaults.standard.bool(forKey: "clickOpensFocus") }
        director.readVolume = { SystemVolume.muted ? 0 : SystemVolume.level }
        director.probePosition = { [weak self] done in self?.nowPlaying.probePosition(done) }
        director.openTrack = { [weak self] done in self?.nowPlaying.openTrack(link: { NSWorkspace.shared.open($0) }, done) ?? done(false) }
        // The desktop strip glows on the song's beat (`DesktopColors.audioFrame`, `BeatTracker`).
        bars.onOnset = { [weak self] onset, t, rate in self?.desktopColors.audioFrame(onset: onset, at: t, rate: rate) }
        desktopColors.pulseScale = { [weak self] in
            guard let self else { return 0 }
            let c = director.island.context
            let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            return DesktopColors.pulseScale(focusOn: c.focusOn, secondsSinceKey: key, presenting: c.presenting)
        }
        LockWallpaper.shared.raiseAbove = { [weak self] in
            guard let self else { return }
            panel.orderFrontRegardless()
            lockCard.raise()
        }
        nowPlaying.start()
        desktop.screen = { [weak self] in
            guard let g = self?.geometry else { return nil }
            return (CGDisplayBounds(g.displayID), Double(g.notchHeight))
        }
        desktop.onChange = { [weak self] c in
            Self.log.info("context: \(c.frontmostApp, privacy: .public) fullscreen \(c.fullscreen) menu \(c.menuOpen) locked \(c.locked) mic \(c.micInUse) camera \(c.cameraInUse)")
            self?.director.systemContextChanged(c)
        }
        director.typingNow = { [weak self] in self?.desktop.typingNow() ?? false }
        desktop.start()
        startLiveActivities()
        updateReduceMotion()
        syncContentSettings()
        observeSystem()
        relayout()
    }

    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "nowplaying")
    private static let lockLog = Logger(subsystem: "com.fellipe.liquidnotch", category: "lock")
    /// Once per lock: why the art didn't become the wallpaper (11-11: the owner saw it not happen).
    private var lockArtSkipLogged = false

    /// The repository, for `swift run` (the adapter built by `tools/build_adapter.sh`).
    private static var sourceRoot: URL {
        URL(fileURLWithPath: devFile()).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Stops the Now Playing feed (the adapter's perl process goes with it) and the key tap.
    func stop() {
        bars.shutdown()
        nowPlaying.stop()
        keys.stop()
        clipboard.stop()
    }

    /// The tray's sources: the clipboard, the Shortcuts command line (Focus runs through it too).
    private func wireTray() {
        let tray = director.tray
        clipboard.onText = { [weak tray] text in tray?.addClip(text) }
        clipboard.start()
        tray.copyToPasteboard = { [weak self] text in self?.clipboard.write(text) }
        tray.runShortcut = { name in ShortcutsCLI.run(shortcut: name) }
        tray.toggleFocus = { mode in Task { @MainActor in await FocusSwitcher.toggle(mode.rawValue) } }
        tray.listShortcuts = { [weak tray] in
            Task { @MainActor in
                let names = await ShortcutsCLI.list()
                tray?.shortcutsListed(names)
            }
        }
    }

    private func startLiveActivities() {
        power.onChange = { [weak self] p in self?.director.powerChanged(p) }
        power.onPlugIn = { [weak self] p in self?.director.pluggedIn(p) }
        power.onLow = { [weak self] p in self?.director.lowBattery(p) }
        power.start()
        meetings.onChange = { [weak self] m in self?.director.meetingChanged(m) }
        meetings.onAgenda = { [weak self] a in self?.director.agendaChanged(a) }
        meetings.onStart = { [weak self] e in self?.director.eventStarted(e) }
        director.startAlertsOn = { UserDefaults.standard.bool(forKey: "calendarStartAlerts") }
        meetings.start()
        pods.onConnect = { [weak self] p in self?.director.podsConnected(p) }
        pods.onUpdate = { [weak self] p in self?.director.podsUpdated(p) }
        pods.start()
        transfers.onStart = { [weak self] t in self?.director.transferStarted(t) }
        transfers.onUpdate = { [weak self] t in self?.director.transferUpdated(t) }
        transfers.onEnd = { [weak self] t, done in self?.director.transferEnded(t, finished: done) }
        director.transferControl = { [weak self] action in
            if action == .pauseDownload { self?.transfers.pauseOrResume() } else { self?.transfers.showInFinder() }
        }
        transfers.start()
        football.onReminder = { [weak self] m in self?.director.footballReminder(m) }
        football.onUpdate = { [weak self] m in self?.director.footballUpdated(m) }
        football.start()
        calls.start()
        notices.onChange = { [weak self] all, arrived in self?.director.noticesChanged(all: all, arrived: arrived) }
        if NotificationStore.enabled { notices.start() }
        NotificationCenter.default.addObserver(forName: NotificationStore.toggled, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NotificationStore.enabled { self.notices.start() } else { self.notices.stop(); self.director.noticesChanged(all: [], arrived: []) }
            }
        }
        // The volume and brightness keys: only with Accessibility, so the system's HUD is replaced,
        // never shown beside ours. Retried until it's allowed.
        keys.onLevel = { [weak self] l in self?.director.levelChanged(brightness: l.brightness, level: l.level) }
        director.setLevel = { kind, level in
            switch kind {
            case .brightness: return SystemBrightness.set(level)
            case .volume:
                guard SystemVolume.set(level) else { return false }
                if level == 0 { SystemVolume.setMuted(true) }   // like the keys: all the way down is mute
                else if SystemVolume.muted { SystemVolume.setMuted(false) }
                return true
            }
        }
        keys.onAskKey = { [weak self] in self?.director.toggleAsk() }
        if let g = geometry { SystemBrightness.display = g.displayID }
        keys.start()
        if !keys.running {
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.keys.start()
                    if self.keys.running { self.keyRetry?.invalidate(); self.keyRetry = nil }
                }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            keyRetry = t
        }
    }

    private func wireDirector() {
        let d = director
        d.tuning = { [weak self] in self?.tuningStore.tuning ?? Tuning() }
        d.reduceMotion = { [weak self] in self?.animator.reduceMotion ?? false }
        d.clock = { [weak self] in self?.now() ?? 0 }
        d.schedule = { [weak self] seconds, body in
            IslandDirector.taskSchedule(seconds / max(self?.tuningStore.tuning.timeScale ?? 1, 0.05), body)
        }
        d.onChange = { [weak self] in self?.activitiesChanged() }
        d.onKick = { [weak self] v in self?.kick(v) }
        d.onTakeover = { [weak self] in self?.takeover() }
        d.onPulse = { [weak self] hex in self?.pulse(hex) }
        // Quick ask: the answers stream in; the field takes the keyboard without activating the app.
        d.quickAsk.onEvent = { [weak d] id, e in d?.askEvent(id, e) }
        d.onWantsKey = { [weak self] in self?.panel.makeKey() }
    }

    private func now() -> Double {
        let t = CACurrentMediaTime()
        animatorTime += (t - animatorTimeAt) * max(tuningStore.tuning.timeScale, 0.05)
        animatorTimeAt = t
        return animatorTime
    }

    // MARK: - Presentation

    /// Debug: force a shape. Stops every activity so nothing fights the choice.
    func present(_ newMode: PresentationMode) {
        director.force(newMode)
        context = TargetContext()
        go(to: newMode)
    }

    private func go(to newMode: PresentationMode) {
        guard let targets else { mode = newMode; return }
        if newMode == .card && mode != .card && !animator.reduceMotion && animator.current.cardHalfWidth < 1 {
            // The card pours out of the notch's own bottom edge, unless it's still on its way back.
            animator.snapChannels(ShapeTargets.cardChannels, from: targets.cardSeed)
        }
        let (first, stages) = targets.transition(from: mode, to: newMode, reduceMotion: animator.reduceMotion)
        mode = newMode
        animator.setTargets(first, then: stages)
        updateGroups()
        clock.wake()
    }

    /// The island changed: work out the shape and what shows on it.
    private func activitiesChanged() {
        let d = director
        let island = d.island
        let wanted = d.mode
        context.pressed = d.pressed
        context.drag = d.drag
        context.auraHex = auraOverride ?? d.auraHex
        context.typing = island.context.typing
        // Into a menu or fullscreen the island drains slowly into the notch (sim CTX2), not with its bounce.
        let hidden = island.context.menuOpen || island.context.fullscreen
        if hidden && !wasHidden { animator.soften(for: 0.9) }
        wasHidden = hidden
        updateLockScreen()
        // Music only (owner, 11-07: a movie in Chrome put Chrome's icon on the desktop: "shouldn't happen with anything
        // that isn't music"; `NowPlaying.isMusic`).
        desktopColors.update(on: island.mediaOn && director.mediaIsMusic, key: director.media.artKey,
                             art: director.media.artwork?.image, playing: director.playing,
                             fullscreen: island.context.fullscreen)
        context.bubbleModes = Set(PresentationMode.allCases.filter { island.hasBubble($0) })
        context.leftBallModes = Set(PresentationMode.allCases.filter { island.balls($0)[1] != nil })
        context.moreModes = Set(PresentationMode.allCases.filter { island.balls($0)[2] != nil })
        if d.forcedMode != nil { context.bubbleModes = [.split]; context.leftBallModes = []; context.moreModes = [] }
        context.activityHoldsEars = island.earsHeld
        context.activityEar = island.heldEar
        context.card = island.cardSize(player: playerCard)
        context.idleHover = d.idleHover
        let peek = d.groups.peekPlace
        let peekCard = peek.flatMap { d.groups.balls[$0] }.map(Island.peekCard)   // a song's is wider (11-06)
        if peek != nil && context.peekPlace == nil, let targets {
            // The peek grows out of its ball, clear of the ears (it used to rise out of the notch and pull it down).
            var t = targets
            t.context.peekPlace = peek
            t.context.peekCard = peekCard
            if animator.current.cardHalfWidth < 1 { animator.snapChannels(ShapeTargets.cardChannels + [\.cardX], from: t.peekSeed(mode)) }
            context.peekLeave = nil
        } else if peek == nil, context.peekPlace != nil, d.mode != .card {
            // It shrinks away where it is, then the card channels go home unseen.
            context.peekLeave = SIMD2(animator.current.cardX, animator.current.cardTop)
            peekLeaveEnd?.cancel()
            peekLeaveEnd = d.schedule(0.8) { [weak self] in self?.context.peekLeave = nil }
        }
        context.peekPlace = peek
        context.peekCard = peekCard
        animator.dragging = d.drag != nil
        // The panel took the keyboard for a field (quick ask, a reply): once its card closes, the app you were in gets it
        // back (the panel never activated anything, so that app is still the front one).
        if panel.isKeyWindow, !island.opened { NSWorkspace.shared.frontmostApplication?.activate() }
        // Menus only need watching while the island has something to show (and pull back from).
        desktop.watchMenus = island.live && !island.context.locked
        if d.holdsShape {
            updateGroups()                 // content leaves; the shape follows after
        } else if wanted != mode {
            go(to: wanted)
        } else {
            if let targets { animator.setFinal(targets.resting(mode)) }
            updateGroups()
            clock.wake()
        }
    }

    /// On lock the panel joins the lock space (boring.notch's way: the island is already there, it just stays visible);
    /// it leaves 0.6 s after unlock so the unlock moment carries over without a flicker. The music card shows while a
    /// song is on.
    private func updateLockScreen() {
        let island = director.island, locked = island.context.lockScreen
        if locked != wasLockScreen {
            wasLockScreen = locked
            if locked {
                lockLeave?.cancel(); lockLeave = nil
                LockSpace.shared.join(panel)
                if let screen = NotchGeometry.current()?.0 { LockWallpaper.shared.locked(on: screen) }
                director.setLockTouched(false)
                let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                        self?.director.setLockTouched(idle < 2.5)
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                lockInputPoll = t
            } else {
                lockInputPoll?.invalidate(); lockInputPoll = nil
                lockCard.hide()
                LockWallpaper.shared.unlocked()   // the art was for the lock screen only
                lockLeave = director.schedule(0.6) { [weak self] in
                    guard let self, !director.island.context.lockScreen else { return }
                    LockSpace.shared.leave(panel)
                }
            }
        }
        guard locked else {
            lockArtSkipLogged = false
            // The art is drawn ahead while unlocked, so locking shows it at once.
            if island.mediaOn, director.mediaIsMusic, let screen = NotchGeometry.current()?.0 {
                LockWallpaper.shared.prepare(key: director.media.artKey, art: director.media.artwork?.image, on: screen)
            }
            return
        }
        if island.mediaOn && !lockCard.shown, let screen = NotchGeometry.current()?.0 {
            lockCard.show(on: screen)
        } else if !island.mediaOn && lockCard.shown {
            lockCard.hide()
            LockWallpaper.shared.lockMediaLeft()
        }
        // The art becomes the wallpaper for music only; a video or anything else keeps yours (or brings it back).
        if lockCard.shown {
            if director.mediaIsMusic { LockWallpaper.shared.lockMedia() } else {
                if !lockArtSkipLogged {
                    lockArtSkipLogged = true
                    Self.lockLog.notice("lock art: not music (\(self.director.nowPlaying?.bundleID ?? "?", privacy: .public), kind \(self.director.nowPlaying.map { "\($0.kind)" } ?? "none", privacy: .public))")
                }
                LockWallpaper.shared.lockMediaLeft()
            }
        }
    }

    private var playerCard: CardSize {
        let t = tuningStore.tuning
        return CardSize(width: t.cardHalfWidth * 2, height: t.cardHeight, radius: t.cardRadius)
    }

    private func updateGroups() {
        content.groups = director.groups
        if content.bars !== bars { content.bars = bars }
        // The bars follow the audio only while a real song plays (not the debug panel's samples), they're on the
        // island (the ears, or a ball's peek of the song) or the desktop strip pulses to them (wherever the song is), and
        // motion isn't reduced.
        let g = content.groups
        bars.update(wanted: !director.sampleOn && director.nowPlaying?.playing == true
                    && (g.musicEars || g.peekPlace.flatMap { g.balls[$0] } == .media || desktopColors.wantsBeats)
                    && !animator.reduceMotion)
        if mode == .card {
            // Kept as it was while the card closes, so its content (the art, the bars) rides it back.
            content.card = context.card ?? playerCard
        }
        content.cardIsPlayer = NotchContentModel.artRidesCard(mode: mode, groups: director.groups, was: content.cardIsPlayer)
        content.playerWidth = playerCard.width
        content.playerHeight = playerCard.height
        content.mode = mode
    }

    /// An activity took over the ears from the ears: they pinch in a little, then the new one stretches out.
    private func takeover() {
        guard let targets, mode == .compact || mode == .duo, !animator.reduceMotion else { return }
        let rest = targets.resting(.compact)
        var squeeze = rest
        squeeze.mainHalfWidth = max(animator.current.mainHalfWidth - 16, targets.notchHalfWidth)
        squeeze.glowIntensity = 0
        animator.setTargets(squeeze, then: [(0.08, rest)])
        clock.wake()
    }

    private func kick(_ v: Double) {
        guard !animator.reduceMotion else { return }
        animator.kick(\.kBezel, v)
        animator.kick(\.mainHalfWidth, v * 0.6)
        if mode == .card { animator.kick(\.cardHalfWidth, v * 0.5) }
        clock.wake()
    }

    /// A colour flash on the dim bloom that starts at 0.4 and fades to nothing over 600 ms.
    private func pulse(_ hex: String) {
        let t = tuningStore.tuning
        guard t.dimGlow, t.glowPulse, !animator.reduceMotion else { return }
        pulseColor = SRGB.parse(hex) ?? SIMD3(1, 1, 1)
        pulseStart = now()
        clock.wake()
    }

    private var pulseAmount: Double {
        guard let start = pulseStart else { return 0 }
        let k = (now() - start) / 0.6
        if k >= 1 { pulseStart = nil; return 0 }
        return tuningStore.tuning.pulseIntensity * (1 - k) * (1 - k)
    }

    private var targets: ShapeTargets? {
        geometry.map {
            ShapeTargets(notchHalfWidth: Double($0.notchWidth / 2), notchHeight: Double($0.notchHeight),
                         tuning: tuningStore.tuning, context: context)
        }
    }

    private func apply(tuning t: Tuning) {
        animator.configs = t.springs
        animator.dynamics = t.dynamics
        animator.cardBridge = (t.cardNeckMax, t.cardBreakGap)
        clock.timeScale = t.timeScale
        rebuildConstants()
        syncContentSettings()
        context.card = director.island.cardSize(player: playerCard)
        content.card = context.card ?? playerCard
        // Slider changes animate to the new resting shape, which is the point of tuning live.
        if let targets { animator.setTarget(targets.resting(mode)) }
        clock.wake()
    }

    private func syncContentSettings() {
        let t = tuningStore.tuning
        frameModel.peekHeight = t.peekHeight
        frameModel.expandedHeight = t.expandedHeight
        content.contentDelay = t.contentDelay
        content.timeScale = t.timeScale
    }

    // MARK: - Geometry

    private func readWallpaperTint() {
        guard let screen = NotchGeometry.current()?.0, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        Task.detached(priority: .utility) {
            let tint = WallpaperTint.tint(url: url)
            await MainActor.run { [weak self] in
                guard let self, tint != context.bloomHex else { return }
                context.bloomHex = tint
                activitiesChanged()
            }
        }
    }

    private func relayout() {
        guard let (_, g) = NotchGeometry.current() else {
            // No screen at all (every display asleep or gone).
            geometry = nil
            panel.orderOut(nil)
            return
        }
        let changed = g != geometry
        geometry = g
        frameModel.notchHalfWidth = Double(g.notchWidth / 2)
        frameModel.notchHeight = Double(g.notchHeight)
        rebuildConstants()
        if changed {
            panel.setFrame(g.panelFrame(size: Self.panelSize), display: false)
            clock.attach(to: view)
            // A new screen is not an animation: place the shape where it belongs.
            if let targets { animator.snap(to: targets.resting(mode)) }
        }
        panel.orderFrontRegardless()
        render()
    }

    private func rebuildConstants() {
        guard let g = geometry, let targets else { return }
        let t = tuningStore.tuning
        let n = targets.notchConstants
        animator.floor = (targets.notchHalfWidth, targets.notchHeight)
        constants = SurfaceConstants(
            viewSize: SIMD2(Double(Self.panelSize.width), Double(Self.panelSize.height)),
            scale: Double(g.scale),
            notchHalfWidth: n.halfWidth, notchHeight: n.height, notchRadius: n.radius,
            cornerExponent: t.cornerExponent, kNotch: t.kNotch, kDrop: t.kDrop, edgeFeather: t.edgeFeather)
    }

    private var drawnFrame: ShapeFrame? {
        guard let targets else { return nil }
        return targets.drawn(animator.frame)
    }

    private var uniforms: ShapeUniforms? {
        guard let constants, let f = drawnFrame else { return nil }
        let t = tuningStore.tuning
        let extras = FrameExtras(cardNeck: f.cardNeck, earGlowOffset: mode == .card ? 8 : 0,
                                 pulseColor: pulseColor, pulse: pulseAmount,
                                 hairline: t.dimGlow && t.hairline ? 0.08 : 0)
        return ShapeUniforms(state: f.state, neckRadius: f.neckRadius, dropRadii: f.dropRadii,
                             constants: constants, extras: extras)
    }

    private func render() {
        guard let u = uniforms, let f = drawnFrame else { return }
        view.draw(u)
        // The content layer follows the same frame the shader just drew.
        frameModel.update(f)
        // The shape can move out from under a still pointer.
        updateMouse()
        onFrame?(animator.frame)
    }

    // MARK: - Pointer

    /// What a panel point is over, with the simulator's margins.
    private func hit(_ p: SIMD2<Double>) -> HitRegion? {
        // The empty notch takes the pointer too, so it can swell and open the tray.
        guard mode != .idle || (director.island.canOpenEmptyTray && director.forcedMode == nil), let u = uniforms else { return nil }
        return ShapeSDF.hit(p, u, earPad: tuningStore.tuning.hitPad)
    }

    /// The gap between the ears and the open card counts as hover, so travelling down to the card
    /// never closes it. It covers where the card will rest, not where it is. Clicks there still
    /// reach the window below.
    private func inCorridor(_ p: SIMD2<Double>) -> Bool {
        guard mode == .card, let f = drawnFrame else { return false }
        let cd = context.card ?? playerCard
        let t = tuningStore.tuning
        let nh = geometry.map { Double($0.notchHeight) } ?? 37.5
        return abs(p.x - Self.panelSize.width / 2) <= cd.halfWidth && p.y >= f.state.mainHeight - 1
            && p.y <= nh + t.cardGap + cd.height
    }


    private func panelPoint(_ global: NSPoint) -> SIMD2<Double> {
        let f = panel.frame
        return SIMD2(Double(global.x - f.minX), Double(f.maxY - global.y))
    }

    private func updateMouse(still: Bool = false) {
        let p = panelPoint(NSEvent.mouseLocation)
        let h = hit(p)
        // While pressed the drag is ours, wherever the pointer goes.
        let holding = CACurrentMediaTime() < holdMouseUntil
        if !director.holdsPointer, !holding, panel.ignoresMouseEvents != (h == nil) { panel.ignoresMouseEvents = h == nil }
        // Hover intent: the pointer's speed from the last move. Fast over the island is passing through (to a tab, a
        // window's title bar): nothing opens. Slow, or still for a tenth of a second, is a hover.
        let t = CACurrentMediaTime(), dt = t - lastMouse.at
        let speed = dt > 0 ? (pow(p.x - lastMouse.p.x, 2) + pow(p.y - lastMouse.p.y, 2)).squareRoot() / dt : 0
        lastMouse = (p, t)
        let settled = still || speed < Self.hoverIntentSpeed
        intentCheck?.invalidate(); intentCheck = nil
        if h != nil && !settled {
            let check = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.updateMouse(still: true) } }
            RunLoop.main.add(check, forMode: .common)
            intentCheck = check
        }
        director.pointerMoved(hit: h, corridor: inCorridor(p), buttonDown: NSEvent.pressedMouseButtons != 0, settled: settled)
        updateNear(p, over: h != nil)
        overIsland = h != nil && director.island.live
        delights.pointer(x: p.x, over: overIsland, pressed: director.pressed || NSEvent.pressedMouseButtons != 0)
    }

    /// Anticipation (sim `near`): the island notices the pointer coming. Only with something on it and its ears out,
    /// not over the liquid itself (the hover takes over there). Measured from the ears' resting edge, so their own
    /// widening never feeds back into it.
    private func updateNear(_ p: SIMD2<Double>, over: Bool) {
        var near = 0.0
        if director.island.live, director.forcedMode == nil, !animator.reduceMotion, !over, mode == .compact || mode == .duo,
           var t = targets {
            t.context.near = 0
            let s = t.resting(mode)
            let dx = max(abs(p.x - (FrameModel.cx + s.mainX)) - s.mainHalfWidth, 0), dy = max(p.y - s.mainHeight, 0)
            near = ShapeTargets.near(distance: (dx * dx + dy * dy).squareRoot())
        }
        guard near != context.near else { return }
        context.near = near
        if let targets {
            animator.setFinal(targets.resting(mode))
            clock.wake()
        }
    }

    private func pointerDown(_ p: SIMD2<Double>) {
        let wasOpen = director.island.opened
        director.pointerDown(at: p, hit: hit(p))
        // A card just opened under a press: keep the pointer for the double-click time, so a second press on the notch or
        // beside it (where the ears were) is ours and not the menu bar's.
        if !wasOpen && director.island.opened {
            holdMouseUntil = CACurrentMediaTime() + NSEvent.doubleClickInterval
            panel.ignoresMouseEvents = false
        }
    }

    private func pointerUp(_ p: SIMD2<Double>) {
        director.pointerUp(at: p, hit: hit(p), corridor: inCorridor(p))
        updateMouse()
    }

    // MARK: - System

    private func observeSystem() {
        // Mouse-moved global monitors need no permission (only key monitoring does).
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.updateMouse()
            return e
        }) { monitors.append(l) }
        // Scrolling on the island steps through it (player, then tools); elsewhere it scrolls what's under it.
        if let l = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            guard let self, e.window === panel else { return e }
            let raw = Double(e.scrollingDeltaY)
            guard raw != 0 || e.phase == .began else { return e }
            // Natural scrolling flips the deltas: fingers moving down pull the content down either way.
            let pull = e.isDirectionInvertedFromDevice ? raw : -raw
            let used = director.scrolled(pull: pull, precise: e.hasPreciseScrollingDeltas, began: e.phase == .began,
                                         momentum: !e.momentumPhase.isEmpty, hit: hit(panelPoint(NSEvent.mouseLocation)))
            return used ? nil : e
        }) { monitors.append(l) }
        // A right-click on the island opens the app's menu, except while the reply field is typing
        // (the panel is key only then) so the text menu still works there.
        if let l = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] e in
            guard let self, e.window === panel, !panel.isKeyWindow, let region = hit(panelPoint(NSEvent.mouseLocation)),
                  let menu = contextMenu?(region), let v = panel.contentView else { return e }
            NSMenu.popUpContextMenu(menu, with: e, for: v)
            return nil
        }) { monitors.append(l) }
        // The Konami code (easter egg): keys are only looked at while the pointer rests on the island (a global key
        // monitor needs Accessibility, which the app already asks for; without it this stays silent).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            let code = e.keyCode
            MainActor.assumeIsolated { if self?.overIsland == true { self?.delights.key(code) } }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if self?.overIsland == true, self?.panel.isKeyWindow == false { self?.delights.key(e.keyCode) }
            return e
        }) { monitors.append(l) }
        delights.kickWidth = { [weak self] v in
            guard let self, !animator.reduceMotion else { return }
            animator.kick(\.mainHalfWidth, v); clock.wake()
        }
        delights.kick = { [weak self] v in self?.kick(v) }
        delights.pulse = { [weak self] hex in self?.pulse(hex) }
        delights.aura = { [weak self] hex in self?.auraOverride = hex; self?.activitiesChanged() }
        delights.reduceMotion = { [weak self] in self?.animator.reduceMotion ?? true }
        // A click anywhere else closes the open card.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.director.clickOutside() }
        }) { monitors.append(g) }

        let nc = NotificationCenter.default
        let wc = NSWorkspace.shared.notificationCenter
        // The bloom's tint follows the wallpaper (each Space can have its own).
        readWallpaperTint()
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readWallpaperTint() }
            })
        }
        // Displays connected or gone, a resolution change, the lid closed, or the Show on / Notch settings.
        for name in [NSApplication.didChangeScreenParametersNotification, NotchGeometry.settingsChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            })
        }
        observers.append(wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        })
        observers.append(wc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReduceMotion() }
        })
    }

    private func updateReduceMotion() {
        let on = forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animator.reduceMotion = on
        content.reduceMotion = on
    }
}
