import AppKit
import CoreImage
import ImageIO
import os
import UniformTypeIdentifiers

/// The album art as the lock screen's wallpaper (owner, 11-07: "swap it is nice but can we change it back and forth when
/// I click? and have a transition animation"). The owner's wallpaper is an aerial, which isn't a file macOS hands out
/// (`desktopImageURL` says DefaultDesktop.heic): so the wallpaper store (`com.apple.wallpaper/Store/Index.plist`) is backed
/// up byte for byte before the swap and written back to restore, with WallpaperAgent restarted so it rereads it (the
/// idea Atoll uses; our own code). Unlocking restores it, and so does the next launch if the app quit mid-swap.
///
/// Nothing of ours can draw under the system clock (test 5, 11-07: levels 100 and 200 don't show at all), so the swap is
/// hidden by a layer over the whole lock screen, kept as short as the agent allows (owner, 11-07: "the clock and the text
/// disappeared for 5 secs"). The agent is back about 0.25 s after the restart (the system log of the owner's lock), so
/// the layer waits for its new process instead of a fixed 1.6 s. The art is drawn ahead, off the main thread, as soon as
/// the song is known, so a swap starts at once. The cover flies from the card to its place in the middle (and back), and
/// a skipped song brings its own art (owner, 11-07: "when you skip song … the wallpaper don't change").
@MainActor
final class LockWallpaper {
    static let shared = LockWallpaper()

    private init() {
        // Setup's switch off brings yours back at once (11-11).
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let s = LockWallpaper.shared
                guard !Self.autoEnabled, s.auto || s.applied != .yours || FileManager.default.fileExists(atPath: Self.backup.path) else { return }
                Self.log.notice("wallpaper: the switch went off; yours comes back")
                s.auto = false
                s.wanted = .yours
                if s.applied == .yours { s.applied = .art("") }   // a backup left behind is put back too
                s.reconcile()
            }
        }
    }

    /// One song's wallpaper in pieces: the blurred fill, and the cover with its shadow (a sprite) that the transition
    /// moves on its own. Drawn together they're the file the store points at.
    struct Parts: @unchecked Sendable {
        let key: String
        let back: CGImage
        let sprite: CGImage
        /// The sprite's place on the screen, in points from the bottom left.
        let spriteRect: CGRect
        /// The cover's own place (the sprite without its shadow's margin), in points from the bottom left.
        let coverRect: CGRect
        let file: URL
    }

    private enum State: Equatable { case yours, art(String) }
    /// What the wallpaper is, and what it should be: the lock, songs and unlocking change `wanted`, `reconcile` gets there one swap at
    /// a time (owner, 11-07: "sometimes it appears, sometimes it doesn't": nothing a tap asks for is dropped).
    private var applied = State.yours
    private var wanted = State.yours

    private var busy = false
    private var song: (key: String, art: CGImage)?
    private var ready: Parts?
    private var shown: Parts?
    private var rendering: String?
    /// The lock screen, while locked (nil: swaps happen without a transition).
    private var screen: NSScreen?
    /// The lock card's cover, in screen points from the bottom left: where the flying cover starts and lands.
    var cardCover: CGRect?

    private var overlay: NSWindow?
    private let overlayRoot = CALayer()
    private let back = CALayer()
    private let sprite = CALayer()
    private let hole = CALayer()

    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "wallpaper")

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Liquid Notch")
    }
    private static var store: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }
    private static var backup: URL { folder.appendingPathComponent("wallpaper-store-backup.plist") }

    // MARK: - What the card and the lock tell it

    /// "Make this my default" (owner, 11-07): while the song is on the lock screen, playing or paused (like iPhone; the
    /// owner locked with a paused song and missed it: "you removed the wallpaper?"), its art is the wallpaper without a
    /// tap. The song leaving or unlocking brings yours back. Setup's switch turns it off. The art is drawn ahead while unlocked (`prepare`), so locking shows it at once (owner, 11-07: "when I lock,
    /// it uses my default and after a sec it changes").
    static let autoKey = "lockScreenArt"
    /// Off by default (11-11, v1: changing someone's wallpaper is opt-in).
    static var autoEnabled: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? false }
    private var auto = false
    /// When the Mac locked (a swap within a moment of it shows the art in place, without the cover's flight).
    private var lockedAt: Date?
    /// The screen's size, for drawing (known before the lock, from `prepare`).
    private var size: CGSize?
    /// A click on the big cover (owner, 11-07: "clicking it does nothing since mac just asks for the password").
    var onArtTap: (() -> Void)?
    /// The art is (or is becoming) the wallpaper, or yours is back: the lock card drops its own cover meanwhile.
    var onArtShown: ((Bool) -> Void)?
    /// Brings the lock card and the island back above the layer (they stay in sight while it works under them).
    var raiseAbove: (() -> Void)?
    private var catcher: NSWindow?

    /// The lock card shows a song (every island change while locked and the card shows).
    func lockMedia() {
        let want = Self.autoEnabled
        if !want && !auto { Self.log.notice("wallpaper: a song on the lock screen; the switch is off") }
        guard want != auto else { return }
        auto = want
        autoStart()
    }

    /// The Mac locked, on `screen`.
    func locked(on screen: NSScreen) {
        self.screen = screen
        size = screen.frame.size
        lockedAt = Date()
    }

    /// While unlocked: the playing song's art is drawn ahead, so a lock can show it at once.
    func prepare(key: String, art: NSImage?, on screen: NSScreen) {
        guard Self.autoEnabled, self.screen == nil, song?.key != key,
              let cg = art?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        size = screen.frame.size
        song = (key, cg)
        render()
    }

    /// A tap on the lock card's cover or the big cover (owner, 11-11): the art becomes the wallpaper, or yours comes back.
    /// Your own tap, so it works with Setup's automatic switch off too; the same backup and restore keep yours safe.
    func toggleByTap() {
        if case .art = wanted {
            auto = false
            wanted = .yours
            tapped = Date(); mark("tap: yours back")
        } else {
            guard screen != nil, let song else { Self.log.notice("wallpaper: tap with no song drawn yet"); return }
            wanted = .art(song.key)
            tapped = Date(); mark("tap: the art")
        }
        reconcile()
    }

    /// The song left the lock screen (the player quit or dropped it): yours comes back.
    func lockMediaLeft() {
        auto = false
        wanted = .yours
        reconcile()
    }

    private func autoStart() {
        guard auto, screen != nil, wanted == .yours, let song else { return }
        wanted = .art(song.key)
        tapped = Date()
        mark("auto")
        reconcile()
    }

    /// The song on the lock card (on lock and with every new cover): its art is drawn ahead, and if the art is the
    /// wallpaper, the new song's takes its place.
    func song(key: String, art: NSImage?, on screen: NSScreen) {
        self.screen = screen
        size = screen.frame.size
        guard let cg = art?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }   // the old cover stays until the new one comes
        guard song?.key != key else { return }
        song = (key, cg)
        if case .art = wanted { wanted = .art(key) }
        render()
        reconcile()
        autoStart()
    }


    /// Unlocked: yours comes back once the lock screen has gone (the art was for the lock screen only). Not at once:
    /// the agent's restart blinked the leaving lock screen black (owner, 11-07: "the wallpaper is blinking black at
    /// random moments at the lock screen"; every restore in the log came with an unlock). By then the desktop's colours
    /// cover the wallpaper, and a layer of the art under them covers the restart when they're off (`restore`).
    func unlocked() {
        onArtShown?(false)
        screen = nil
        lockedAt = nil
        unlockedAt = Date()
        auto = false
        wanted = .yours   // the art was for the lock screen (the desktop has its moving colours: `DesktopColors`)
        hideCatcher()
        if let overlay { overlay.orderOut(nil); LockSpace.shared.leave(overlay) }
        after(Self.unlockSettle + 0.05) { self.reconcile() }
    }

    /// How long the lock screen takes to leave after unlocking, with room to spare.
    nonisolated static let unlockSettle = 1.5
    private var unlockedAt: Date?

    /// Quitting while the art is the wallpaper: the store goes back now and the agent rereads it (no waiting: the app is
    /// leaving). If the app dies instead, the next launch puts it back (`recoverIfNeeded`).
    func restoreOnQuit() {
        guard FileManager.default.fileExists(atPath: Self.backup.path) else { return }
        Self.log.notice("wallpaper: quitting with the art up; yours goes back")
        if putBack() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["WallpaperAgent"]
            try? p.run()
        }
    }

    /// At launch: a swap left behind (the app quit while the art was the wallpaper) is put back.
    func recoverIfNeeded() {
        guard FileManager.default.fileExists(atPath: Self.backup.path) else { return }
        applied = .art("")
        wanted = .yours
        reconcile()
    }

    // MARK: - Getting there

    private func reconcile() {
        guard !busy, wanted != applied else { return }
        switch wanted {
        case .yours:
            // Just unlocked: `unlocked` comes back once the lock screen has gone.
            if screen == nil, let unlockedAt, Date().timeIntervalSince(unlockedAt) < Self.unlockSettle { return }
            restore()
        case .art(let key):
            guard let p = ready, p.key == key else { render(); return }   // comes back here once it's drawn
            if applied == .yours { show(p) } else { follow(p) }
        }
    }

    private func render() {
        guard let song, ready?.key != song.key, rendering != song.key, let size else { return }
        rendering = song.key
        let art = Parts.Box(song.art), key = song.key, folder = Self.folder
        let back = SongBackground.image(key: key, art: song.art, size: size)   // shared with the desktop
        Task.detached(priority: .userInitiated) {
            let p = Self.parts(key: key, art: art.image, size: size, folder: folder, back: await back.value)
            await MainActor.run {
                if self.rendering == key { self.rendering = nil }
                guard let p else { return }
                if let old = self.ready, old.file != self.shown?.file { try? FileManager.default.removeItem(at: old.file) }
                self.ready = p
                self.reconcile()
            }
        }
    }

    /// Yours → the art: the fill fades in and the cover flies from the card to the middle; under it the store changes and
    /// the agent restarts; once it's back with the art, the layer fades and the clock returns.
    ///
    /// One continuous move (owner, 11-07: "surely not smooth at all, it takes a few secs"): the fill is opaque in 0.25 s
    /// and the agent restarts right then, while the cover is still flying (0.55 s); the layer fades as soon as the flight
    /// has landed and the agent has had 0.25 s to draw (it has the picture ~0.2 s after it starts). About 0.85 s in all.
    private func show(_ p: Parts) {
        guard backUp() else { wanted = .yours; return }
        busy = true
        mark("show")
        guard let screen else { swap(to: p) { self.done(.art(p.key), p) }; return }
        // The card's cover leaves it as the big one comes (it flies from where the card's was).
        onArtShown?(true)
        if let lockedAt, Date().timeIntervalSince(lockedAt) < 2 { showAtLock(p, on: screen); return }
        let w = layer(on: screen, p, backOpacity: 0, cover: startRect(p, screen))
        w.alphaValue = 1
        w.orderFrontRegardless()
        let start = Date()
        animate(0.25, ease: false) { self.back.opacity = 1 }
        animate(0.55) { self.sprite.frame = p.spriteRect }
        after(0.25) {
            self.swap(to: p) {
                self.mark("agent up")
                self.after(max(0.25, 0.55 - Date().timeIntervalSince(start))) {
                    self.fade(w, 0.3) { self.done(.art(p.key), p) }
                }
            }
        }
    }

    /// Just locked: the art shows in place at once (the fill and the cover where they'll stay, no flight) and the store
    /// changes under it; the layer leaves once the agent has drawn the art, and the clock fades in over it. The agent
    /// restarts only once the layer is opaque (it restarted as the layer began to fade in, and the lock screen blinked
    /// black: owner, 11-07). "Agent up" is only its process: the layer left 0.3 s after it and the art wasn't drawn yet
    /// ("it appears, flashes black, then appears again before settling"), so it stays a full second, then fades slowly.
    private func showAtLock(_ p: Parts, on screen: NSScreen) {
        mark("at lock")
        let w = layer(on: screen, p, backOpacity: 1, cover: p.spriteRect)
        w.alphaValue = 0
        w.orderFrontRegardless()
        raiseAbove?()
        fadeIn(w, 0.15) {
            self.swap(to: p) {
                self.mark("agent up")
                self.after(Self.agentDraws) { self.fade(w, 0.6) { self.done(.art(p.key), p) } }
            }
        }
    }

    /// How long WallpaperAgent takes to draw once its new process is up, with room to spare.
    nonisolated static let agentDraws = 1.0

    /// The art → the next song's art, in place, under a crossfade that leaves the clock alone (owner, 11-07: "will the
    /// clock always disappear for a sec when changing?"; without a layer the agent's restart "flashes black"; changed in
    /// place it was "good … it changes suddenly"). A layer showing exactly what's there, with a soft hole where the clock
    /// is, comes in at once (it can't be seen); the store says the new file and the system's own call (what Settings uses)
    /// asks the running agent for it, so nothing restarts; the layer crossfades to the new art meanwhile and leaves once
    /// the agent has it. Only the hole changes at once. The card and the island stay above it. A failing call falls back
    /// to the restart.
    private func follow(_ p: Parts) {
        busy = true
        mark("follow (in place)")
        guard let screen, let shown else { swap(to: p) { self.done(.art(p.key), p) }; return }
        let w = layer(on: screen, shown, backOpacity: 1, cover: shown.spriteRect, clockHole: true)
        w.alphaValue = 1
        w.orderFrontRegardless()
        raiseAbove?()
        _ = Self.applyArt(p.file)
        do {
            try NSWorkspace.shared.setDesktopImageURL(p.file, for: screen, options: [:])
        } catch {
            Self.log.notice("wallpaper: the in-place change failed (\(error.localizedDescription, privacy: .public)); restarting")
            restartAgent { self.fade(w, 0.3) { self.done(.art(p.key), p) } }
            return
        }
        animate(0.5) {
            self.back.contents = p.back
            self.sprite.contents = p.sprite
            self.sprite.frame = p.spriteRect
        }
        after(0.8) {
            self.mark("in place done")
            self.fade(w, 0.2) { self.done(.art(p.key), p) }
        }
    }

    /// The art → yours: the layer comes in over the art (only the clock fades), the store goes back under it, and once
    /// the agent has your wallpaper again the fill fades away and the cover flies back into the card.
    private func restore() {
        busy = true
        mark(screen == nil ? "restore (unlocked)" : "restore (the song left)")
        hideCatcher()
        guard let screen, let shown else {
            // Unlocked (or at launch): the art is the desktop's wallpaper too, so a layer of it just above the
            // wallpaper (under the desktop's colours) covers the restart, then fades into yours.
            let covers = shown.map(desktopCovers) ?? []
            guard putBack() else { covers.forEach { $0.orderOut(nil) }; done(.yours, nil); return }
            restartAgent {
                self.mark("agent up")
                guard !covers.isEmpty else { self.done(.yours, nil); return }
                self.after(Self.agentDraws) {   // drawn, not just up (an aerial loads slower than a picture)
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.5
                        for w in covers { w.animator().alphaValue = 0 }
                    }, completionHandler: {
                        MainActor.assumeIsolated {
                            covers.forEach { $0.orderOut(nil) }
                            self.done(.yours, nil)
                        }
                    })
                }
            }
            return
        }
        let w = layer(on: screen, shown, backOpacity: 1, cover: shown.spriteRect)
        w.alphaValue = 0
        w.orderFrontRegardless()
        fadeIn(w, 0.15) {
            guard self.putBack() else { self.fade(w, 0.3) { self.done(.yours, nil) }; return }
            self.restartAgent {
                self.mark("agent up")
                // Drawn, not just up (an aerial loads slower than a picture).
                self.after(Self.agentDraws) {
                    self.animate(0.5) {
                        self.back.opacity = 0
                        self.sprite.frame = self.startRect(shown, screen)
                    }
                    self.after(0.45) { self.fade(w, 0.1) { self.done(.yours, nil) } }
                }
            }
        }
    }

    /// The art as the desktop shows it, on every screen just above the wallpaper and under the desktop's colours (which
    /// sit one level higher), on every Space: what the agent's restart would otherwise show black.
    private func desktopCovers(_ p: Parts) -> [NSWindow] {
        guard let source = CGImageSourceCreateWithURL(p.file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.backgroundColor = .black; w.hasShadow = false; w.isReleasedWhenClosed = false
            w.ignoresMouseEvents = true
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.setFrame(screen.frame, display: false)
            let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let l = CALayer()
            l.contents = image
            l.contentsGravity = .resizeAspectFill
            v.layer = l
            v.wantsLayer = true
            w.contentView = v
            w.orderFrontRegardless()
            return w
        }
    }

    private func done(_ state: State, _ p: Parts?) {
        mark("done")
        let previous = shown
        applied = state
        shown = p
        if let previous, previous.file != p?.file, previous.file != ready?.file { try? FileManager.default.removeItem(at: previous.file) }
        if state == .yours { cleanArt() }
        onArtShown?(state != .yours)
        if let p, let screen { showCatcher(over: p.coverRect, on: screen) }
        busy = false
        reconcile()
    }

    // MARK: - The store and the agent

    private func backUp() -> Bool {
        guard Self.backUp(store: Self.store, to: Self.backup) else {
            Self.log.notice("wallpaper: couldn't back the store up; not swapping")
            return false
        }
        return true
    }

    private func putBack() -> Bool { Self.putBack(Self.backup, to: Self.store) }

    /// Your wallpaper store, byte for byte, before the first change. Never replaced while one waits: a second swap must
    /// not back up the art as if it were yours (the backup is the only copy of the original).
    nonisolated static func backUp(store: URL, to backup: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: backup.path) { return true }
        guard let data = try? Data(contentsOf: store) else { return false }
        return (try? data.write(to: backup, options: .atomic)) != nil
    }

    /// Writes the backup back over the store and only then lets it go. Without a backup nothing is touched.
    nonisolated static func putBack(_ backup: URL, to store: URL) -> Bool {
        guard let data = try? Data(contentsOf: backup), (try? data.write(to: store, options: .atomic)) != nil else { return false }
        try? FileManager.default.removeItem(at: backup)
        return true
    }

    private func swap(to p: Parts, then: @escaping @MainActor () -> Void) {
        if Self.applyArt(p.file) { restartAgent(then: then) } else { then() }
    }

    /// Restarts WallpaperAgent so it rereads the store (launchd starts it again at once), and calls back once its new
    /// process is up (at most 2.5 s). The process table is read directly: LaunchServices' list of running apps can keep
    /// the old one for a while.
    private func restartAgent(then: @escaping @MainActor () -> Void) {
        let old = Self.agentPIDs()
        if old.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["WallpaperAgent"]
            try? p.run()
        } else {
            for pid in old { kill(pid, SIGTERM) }
        }
        mark("agent stopped")
        waitForAgent(replacing: Set(old), since: Date(), then: then)
    }

    private func waitForAgent(replacing old: Set<pid_t>, since start: Date, then: @escaping @MainActor () -> Void) {
        if Self.agentPIDs().contains(where: { !old.contains($0) }) { then(); return }
        if Date().timeIntervalSince(start) > 2.5 { mark("agent not seen in 2.5 s"); then(); return }
        after(0.03) { self.waitForAgent(replacing: old, since: start, then: then) }
    }

    private static func agentPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var name = [CChar](repeating: 0, count: 64)
        return pids.prefix(max(count, 0)).filter { pid in
            guard pid > 0 else { return false }
            let len = Int(proc_name(pid, &name, UInt32(name.count)))
            return len > 0 && String(decoding: name.prefix(len).map { UInt8(bitPattern: $0) }, as: UTF8.self) == "WallpaperAgent"
        }
    }

    /// Timings for the log (category `wallpaper`), from the start: where the time goes when it feels slow.
    private var tapped = Date()
    private func mark(_ what: String) {
        Self.log.notice("wallpaper: \(what, privacy: .public) +\(Int(Date().timeIntervalSince(self.tapped) * 1000)) ms")
    }

    /// Makes `file` both the desktop and the lock screen ("Idle") wallpaper in every entry of the store: the shared
    /// one (`AllSpacesAndDisplays`, which the lock screen reads; the owner's is "linked"), the system default, each display
    /// and each space. The desktop API alone wrote only part of it, so the lock screen showed the art only sometimes.
    static func applyArt(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: store),
              var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        let config: [String: Any] = ["type": "imageFile", "url": ["relative": file.absoluteString]]
        guard let configData = try? PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0) else { return false }
        let block: [String: Any] = [
            "Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image", "Files": [] as [Any], "Configuration": configData]],
                        "Shuffle": "$null"],
            "LastSet": Date(), "LastUse": Date(),
        ]
        func patch(_ e: inout [String: Any]) { e["Desktop"] = block; e["Idle"] = block; e["Type"] = "individual" }
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            var e = plist[key] as? [String: Any] ?? [:]
            patch(&e)
            plist[key] = e
        }
        func patchEach(_ dict: [String: Any]) -> [String: Any] {
            var d = dict
            for (k, v) in dict { if var e = v as? [String: Any] { patch(&e); d[k] = e } }
            return d
        }
        if let displays = plist["Displays"] as? [String: Any] { plist["Displays"] = patchEach(displays) }
        if var spaces = plist["Spaces"] as? [String: Any] {
            for (k, v) in spaces {
                guard var space = v as? [String: Any] else { continue }
                if var def = space["Default"] as? [String: Any] { patch(&def); space["Default"] = def }
                if let ds = space["Displays"] as? [String: Any] { space["Displays"] = patchEach(ds) }
                spaces[k] = space
            }
            plist["Spaces"] = spaces
        }
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return false }
        return (try? out.write(to: store, options: .atomic)) != nil
    }

    /// Removes the art files nothing uses any more (the one drawn ahead for the current song stays).
    private func cleanArt() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("lock-art-") && f.lastPathComponent != ready?.file.lastPathComponent {
            try? fm.removeItem(at: f)
        }
    }

    // MARK: - The big cover takes clicks

    /// An all but clear window over the big cover in the lock space, so a click there is ours (the lock screen would ask
    /// for the password): it shows the lyrics on the card.
    private func showCatcher(over cover: CGRect, on screen: NSScreen) {
        let frame = cover.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let w = catcher ?? {
            let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.canBecomeVisibleWithoutLogin = true
            let v = TapView()
            v.onTap = { [weak self] in self?.onArtTap?() }
            w.contentView = v
            catcher = w
            return w
        }()
        w.setFrame(frame, display: true)
        LockSpace.shared.join(w)
        w.orderFrontRegardless()
    }

    private func hideCatcher() {
        guard let catcher, catcher.isVisible else { return }
        catcher.orderOut(nil)
        LockSpace.shared.leave(catcher)
    }

    private final class TapView: NSView {
        var onTap: (() -> Void)?
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0, alpha: 0.01).setFill()   // a clear pixel would let the click through
            dirtyRect.fill()
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onTap?() }
    }

    // MARK: - The layer over the lock screen

    private func layer(on screen: NSScreen, _ p: Parts, backOpacity: Float, cover: CGRect, clockHole: Bool = false) -> NSWindow {
        let w = overlay ?? {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false
            w.ignoresMouseEvents = true
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.canBecomeVisibleWithoutLogin = true
            let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let root = overlayRoot
            v.layer = root
            v.wantsLayer = true
            root.addSublayer(back)
            root.addSublayer(sprite)
            w.contentView = v
            overlay = w
            return w
        }()
        w.setFrame(screen.frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = screen.backingScaleFactor
        back.frame = CGRect(origin: .zero, size: screen.frame.size)
        back.contentsScale = scale
        back.contents = p.back
        back.opacity = backOpacity
        sprite.contentsScale = scale
        sprite.contents = p.sprite
        sprite.frame = cover
        if clockHole {
            if hole.contents == nil || hole.frame.size != screen.frame.size {
                hole.contents = Self.clockHoleMask(size: screen.frame.size)
                hole.frame = CGRect(origin: .zero, size: screen.frame.size)
            }
            overlayRoot.mask = hole
        } else {
            overlayRoot.mask = nil
        }
        CATransaction.commit()
        LockSpace.shared.join(w)
        return w
    }

    /// Where the lock screen's date and clock are, from the top (the owner's screenshot, 11-07: the date's top 103 pt, the
    /// digits' bottom 265 pt of 1112; the digits 333 pt wide, centred).
    nonisolated static let clockTop = 103.0 / 1112

    /// The layer's mask for a song change: opaque everywhere but a soft hole around the date and clock.
    nonisolated static func clockHoleMask(size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height), feather = 18.0
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let top = size.height * clockTop - 18, bottom = size.height * clockBottom + 20
        let hole = CGRect(x: size.width / 2 - 206, y: size.height - bottom, width: 412, height: bottom - top)
        c.setBlendMode(.clear)
        c.addPath(CGPath(roundedRect: hole, cornerWidth: 40, cornerHeight: 40, transform: nil))
        c.fillPath()
        guard let sharp = c.makeImage() else { return nil }
        let blurred = CIImage(cgImage: sharp).clampedToExtent().applyingGaussianBlur(sigma: feather)
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        return ciContext.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// The sprite's frame when its cover sits exactly on the lock card's cover (the middle, smaller, without a card).
    private func startRect(_ p: Parts, _ screen: NSScreen) -> CGRect {
        let full = p.spriteRect, cover = p.coverRect
        let target = cardCover.map { local($0, screen) }
            ?? CGRect(x: cover.midX - 24, y: cover.midY - 24, width: 48, height: 48)
        let k = target.width / cover.width
        return CGRect(x: target.minX - (cover.minX - full.minX) * k, y: target.minY - (cover.minY - full.minY) * k,
                      width: full.width * k, height: full.height * k)
    }

    private func local(_ r: CGRect, _ screen: NSScreen) -> CGRect {
        r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func animate(_ duration: Double, ease: Bool = true, _ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(ease ? CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1)
                                                      : CAMediaTimingFunction(name: .easeInEaseOut))
        changes()
        CATransaction.commit()
    }

    private func fadeIn(_ w: NSWindow, _ duration: Double, then: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ $0.duration = duration; w.animator().alphaValue = 1 },
                                             completionHandler: { MainActor.assumeIsolated { then() } })
    }

    private func fade(_ w: NSWindow, _ duration: Double, then: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ $0.duration = duration; w.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                w.orderOut(nil)
                LockSpace.shared.leave(w)
                then()
            }
        })
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    // MARK: - Drawing (off the main thread)

    nonisolated private static let ciContext = CIContext()

    /// Where the lock screen's clock ends, from the top (its digits, measured on the owner's screenshot, 11-07: 265 pt of
    /// 1112).
    nonisolated static let clockBottom = 265.0 / 1112

    /// The sharp cover's place on a screen of `size` (points, from the bottom left): centred between the clock and the
    /// lock card, as far from one as from the other, and at least 8 pt clear of the card with its lyrics open (the owner's
    /// screenshots, 11-07: half the screen's height ran under the clock and into the card; then, 24 pt under the clock and
    /// 80 above the card, "it feels off center").
    nonisolated static func coverRect(in size: CGSize) -> CGRect {
        // Against the card as it is while the art is the wallpaper: without its own cover, shorter.
        let window = LockCardController.frame(on: CGRect(origin: .zero, size: size))
        let cardTop = window.minY + LockCardController.bare.height, lyricsTop = window.minY + LockCardController.bareLyrics.height
        let clock = size.height * (1 - clockBottom)
        let gap = max(lyricsTop + 8 - cardTop, 24)
        let side = max(clock - cardTop - gap * 2, 0)
        return CGRect(x: (size.width - side) / 2, y: cardTop + gap, width: side, height: side)
    }

    /// The lock screen's background for a screen of `size`: the cover blurred to fill it and darkened a touch, at 2×.
    /// Scaled to cover the screen and centred on the sharp cover (it was anchored at the bottom left: owner, 11-07, "the
    /// blurred album behind is off center"). The desktop shows it too (`SongBackground`, `DesktopColors`).
    nonisolated static func back(art cg: CGImage, size: CGSize) -> CGImage? {
        let scale = 2.0, w = Int(size.width * scale), h = Int(size.height * scale)
        let ci = CIImage(cgImage: cg)
        let place = coverRect(in: size)
        let fill = max(Double(w) / ci.extent.width, Double(h) / ci.extent.height) * 1.25
        let dx = (Double(w) - ci.extent.width * fill) / 2, dy = place.midY * scale - ci.extent.height * fill / 2
        let blurred = ci.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: fill, y: fill).concatenating(CGAffineTransform(translationX: dx, y: dy)))
            .applyingGaussianBlur(sigma: 60).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        guard let blur = ciContext.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: w, height: h)),
              let bc = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        bc.draw(blur, in: CGRect(x: 0, y: 0, width: w, height: h))
        bc.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        bc.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return bc.makeImage()
    }

    /// iPhone's expanded-art look: the background (`back`, drawn here unless it's handed in) and the sharp cover between
    /// the clock and the card with a soft shadow (`coverRect`; owner, 11-07: "a bit too small … and off center", then
    /// their screenshot of it running into both). Drawn at 2×; the composite is written as a JPEG for the store (it's
    /// mostly blur, and the agent reads it faster).
    nonisolated static func parts(key: String, art cg: CGImage, size: CGSize, folder: URL, back: CGImage? = nil) -> Parts? {
        let scale = 2.0, w = Int(size.width * scale), h = Int(size.height * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!, info = CGImageAlphaInfo.premultipliedLast.rawValue
        let place = coverRect(in: size)
        guard let backImage = back ?? Self.back(art: cg, size: size),
              let bc = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        bc.draw(backImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The cover with its shadow, in a margin wide enough for the shadow.
        let side = place.width * scale, pad = 64 * scale, corner = 26 * scale
        let ss = Int(side + pad * 2)
        guard let sc = CGContext(data: nil, width: ss, height: ss, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        let inner = CGRect(x: pad, y: pad, width: side, height: side)
        sc.saveGState()
        sc.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 40 * scale, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        sc.addPath(CGPath(roundedRect: inner, cornerWidth: corner, cornerHeight: corner, transform: nil))
        sc.setFillColor(NSColor.black.cgColor); sc.fillPath()
        sc.restoreGState()
        sc.addPath(CGPath(roundedRect: inner, cornerWidth: corner, cornerHeight: corner, transform: nil))
        sc.clip()
        sc.draw(cg, in: inner)
        guard let spriteImage = sc.makeImage() else { return nil }
        let coverPx = CGRect(x: place.minX * scale, y: place.minY * scale, width: side, height: side)
        let spritePx = coverPx.insetBy(dx: -pad, dy: -pad)
        // The two together: the file.
        bc.draw(spriteImage, in: spritePx)
        guard let composite = bc.makeImage() else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("lock-art-\(UUID().uuidString.prefix(6)).jpg")
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, composite, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        func points(_ r: CGRect) -> CGRect { CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale) }
        return Parts(key: key, back: backImage, sprite: spriteImage, spriteRect: points(spritePx), coverRect: points(coverPx), file: file)
    }
}

/// A song's lock-screen background (`LockWallpaper.back`), drawn once and shared by the lock screen and the desktop
/// (owner, 11-07: "the wallpaper is still not the same as the blurred one from the lock screen, and it's the easiest
/// change as it's already done"). It keeps the latest song's only (one image, ~30 MB at 2×).
@MainActor
enum SongBackground {
    private static var latest: (key: String, size: CGSize, task: Task<CGImage?, Never>)?

    static func image(key: String, art: CGImage, size: CGSize) -> Task<CGImage?, Never> {
        if let latest, latest.key == key, latest.size == size { return latest.task }
        let box = LockWallpaper.Parts.Box(art)
        let task = Task.detached(priority: .userInitiated) { LockWallpaper.back(art: box.image, size: size) }
        latest = (key, size, task)
        return task
    }
}

extension LockWallpaper.Parts {
    /// A cover handed to the drawing task (a CGImage is immutable).
    struct Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}
