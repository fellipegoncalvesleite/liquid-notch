import AppKit
import IslandCore
import SwiftUI

// The island on the lock screen (11-07, docs/superpowers/specs/2026-11-07-lock-screen-design.md). A window shows there
// only inside a SkyLight space at an absolute level (spike 3 on macOS 27.0.1: levels 300, 400 and 600 show, a plain
// shielding-level window doesn't); clicks and hovers reach it (spike 4). Our windows draw over the system's clock and
// password field, so nothing here covers the screen. Private API, like the Now Playing adapter: if a symbol is missing
// the lock screen simply shows nothing of ours.

/// One SkyLight space at level 400 ("notification centre at screen lock"), created once; windows join it on lock and
/// leave it after unlock.
@MainActor
final class LockSpace {
    static let shared = LockSpace()

    private typealias MainConn = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var add: AddWindows?
    private var remove: RemoveWindows?
    private(set) var available = false

    private init() {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let main = dlsym(sky, "SLSMainConnectionID").map({ unsafeBitCast($0, to: MainConn.self) }),
              let create = dlsym(sky, "SLSSpaceCreate").map({ unsafeBitCast($0, to: SpaceCreate.self) }),
              let level = dlsym(sky, "SLSSpaceSetAbsoluteLevel").map({ unsafeBitCast($0, to: SpaceSetLevel.self) }),
              let show = dlsym(sky, "SLSShowSpaces").map({ unsafeBitCast($0, to: ShowSpaces.self) })
        else { return }
        add = dlsym(sky, "SLSSpaceAddWindowsAndRemoveFromSpaces").map { unsafeBitCast($0, to: AddWindows.self) }
        remove = dlsym(sky, "SLSRemoveWindowsFromSpaces").map { unsafeBitCast($0, to: RemoveWindows.self) }
        guard add != nil else { return }
        connection = main()
        space = create(connection, 1, 0)
        _ = level(connection, space, 400)
        _ = show(connection, [space] as CFArray)
        available = true
    }

    func join(_ window: NSWindow) {
        guard available, let add else { return }
        _ = add(connection, space, [window.windowNumber] as CFArray, 7)
    }

    func leave(_ window: NSWindow) {
        guard available, let remove else { return }
        _ = remove(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}

// MARK: - The ears: locked, and the unlock moment

/// Locked: a closed lock on the left; the Touch ID fingerprint shows on the right only once you start unlocking (owner,
/// 11-07: "it should appear just when you start unlocking with Touch ID, kinda like Face ID does it"). Nothing tells an
/// app that a finger is on the sensor, so "starting" is any key, trackpad or mouse input on the lock screen
/// (`lockTouched`). Unlocked: the lock opens with a bounce and a green check appears (from the fingerprint if it showed).
struct LockEars: View {
    let id: ActivityID
    let side: EarSide
    var unlocking = false
    @State private var opened = false
    @Environment(\.islandMotion) private var motion

    var body: some View {
        let unlocking = id == .unlocked
        let open = unlocking && (opened || motion.stills)   // stills show where the moment lands
        Group {
            switch side {
            case .left:
                Image(systemName: open ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .nonRepeating, value: opened)
            case .right:
                if open || unlocking {
                    Image(systemName: open ? "checkmark.circle.fill" : "touchid")
                        .font(.system(size: open ? 17 : 16, weight: .medium))
                        .foregroundStyle(open ? IslandColor.green : .white.opacity(0.7))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .frame(width: 22, height: 22)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: unlocking)
        .task(id: id) {
            guard unlocking else { opened = false; return }
            if motion.stills || motion.reduce { opened = true; return }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.spring(duration: 0.35, bounce: 0.4)) { opened = true }
        }
    }
}

// MARK: - The music card on the lock screen

/// iPhone's lock-screen player, for the Mac: a frosted card centred below the system clock and clear of the login
/// controls. The window is the expanded card's size (transparent around the card, so clicks pass through there); the
/// card sits at its bottom and grows upwards when the cover is tapped.
@MainActor
final class LockCardController {
    nonisolated static let collapsed = CGSize(width: 360, height: 176)
    /// The window's size: the card with the lyrics (the cover grows to 104 pt beside three lines; owner, 11-07).
    nonisolated static let expanded = CGSize(width: 360, height: 232)
    /// The card while the art is the wallpaper (no cover of its own: a 40 pt title row), and with its lyrics then.
    nonisolated static let bare = CGSize(width: 360, height: 168)
    nonisolated static let bareLyrics = CGSize(width: 360, height: 212)
    /// The collapsed card's centre, from the top of the screen: low, where the account photo was (the owner turned the
    /// lock screen's name and photo off, 11-07, so the music takes that place), 24 pt above the password field (the
    /// owner's screenshot, 11-07: at 0.82 the card touched it).
    nonisolated static let centreFromTop = 0.798
    /// With the lock screen's photo and name showing (macOS's default), they sit there: the card goes up, between the clock
    /// and them (v1, 11-11; not yet seen on a lock screen with the photo).
    nonisolated static let centreFromTopWithAvatar = 0.6

    /// Lock Screen settings › "Show user name and photo" off (`HideUserAvatarAndName`, readable by any app).
    nonisolated static var avatarHidden: Bool {
        (NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.loginwindow.plist")?["HideUserAvatarAndName"] as? Bool) ?? false
    }

    nonisolated static func centre(avatarHidden: Bool) -> Double { avatarHidden ? centreFromTop : centreFromTopWithAvatar }

    private var window: NSWindow?
    private let director: IslandDirector
    private(set) var shown = false

    init(director: IslandDirector) {
        self.director = director
        // The big cover on the wallpaper: a tap brings your wallpaper back (owner, 11-11).
        LockWallpaper.shared.onArtTap = { [weak director] in
            guard director != nil else { return }
            LockWallpaper.shared.toggleByTap()
        }
        LockWallpaper.shared.onArtShown = { [weak director] on in
            guard let director, director.lockArt != on else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.12)) { director.lockArt = on }
        }
    }

    /// The window's frame on `screen`: the card's bottom stays where the collapsed card's bottom is.
    nonisolated static func frame(on screen: NSRect, avatarHidden: Bool = LockCardController.avatarHidden) -> NSRect {
        let bottomFromTop = screen.height * centre(avatarHidden: avatarHidden) + collapsed.height / 2
        return NSRect(x: screen.midX - expanded.width / 2, y: screen.maxY - bottomFromTop,
                      width: expanded.width, height: expanded.height)
    }

    func show(on screen: NSScreen) {
        guard LockSpace.shared.available else { return }
        let w = window ?? makeWindow()
        w.setFrame(Self.frame(on: screen.frame), display: false)
        // A fresh card each lock: it always starts small (owner, 11-07: "it shouldn't stay as default, the long card").
        let host = NSHostingView(rootView: LockMusicCard(director: director))
        host.frame = NSRect(origin: .zero, size: Self.expanded)
        host.autoresizingMask = [.width, .height]
        w.contentView = host
        LockSpace.shared.join(w)
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; w.animator().alphaValue = 1 }
        shown = true
    }

    /// Back above the wallpaper's layer, which works under it.
    func raise() {
        if shown { window?.orderFrontRegardless() }
    }

    func hide() {
        guard shown, let w = window else { return }
        shown = false
        director.lockLyrics = false
        director.lockArt = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; w.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                guard !self.shown else { return }
                w.orderOut(nil)
                w.contentView = nil   // nothing of it keeps drawing while the Mac is unlocked
                LockSpace.shared.leave(w)
            }
        })
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.expanded), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.canBecomeVisibleWithoutLogin = true
        w.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: LockMusicCard(director: director))
        host.frame = NSRect(origin: .zero, size: Self.expanded)
        host.autoresizingMask = [.width, .height]
        w.contentView = host
        window = w
        return w
    }
}

/// The card itself, laid out like iPhone's lock-screen player (owner, 11-07: "too high compared to iPhone … why does it
/// have a volume slider? … it's not really following the iPhone design"): a small cover with title over artist and the
/// AirPlay button on the right, a thin seek bar with both times under it, and the three transport buttons; light frosted
/// glass, 360 wide like the iPhone's. Tapping the cover shows the synced lyrics (owner, 11-07): the cover slides left and
/// grows to 104 pt, three lines beside it, the card grows upwards; a tap on the cover or the lyrics goes back.
struct LockMusicCard: View {
    let director: IslandDirector
    @State private var scrub: Double?
    @Namespace private var art
    @Environment(\.islandMotion) private var motion

    /// Shown on the card or not: the director's, so the big cover on the wallpaper can toggle them too.
    private var lyricsShown: Bool { director.lockLyrics }

    var body: some View {
        let _ = director.now
        let media = director.media
        // The cover is the wallpaper: none on the card, which is shorter (iPhone; owner, 11-07).
        let bare = director.lockArt
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                if lyricsShown {
                    HStack(alignment: .top, spacing: 14) {
                        if !bare { cover(media, size: 104, corner: 14).transition(.opacity.combined(with: .scale(scale: 0.6))) }
                        LyricsList(director: director, style: .lock)
                            .frame(height: bare ? 84 : 104)
                            .contentShape(Rectangle())
                            .onTapGesture { showLyrics(false) }
                            .transition(.opacity.combined(with: .offset(x: 24)))
                    }
                } else {
                    HStack(spacing: 11) {
                        if !bare { cover(media, size: 48, corner: 10).transition(.opacity.combined(with: .scale(scale: 0.6))) }
                        VStack(alignment: .leading, spacing: 0) {
                            Marquee(text: media.title, font: .system(size: 15, weight: .semibold))
                            Marquee(text: media.artist, font: .system(size: 15), color: .white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { showLyrics(true) }      // the title opens the lyrics beside the cover
                        .transition(.opacity)
                        AirPlayButton(size: 26).foregroundStyle(.white.opacity(0.85)).transition(.opacity)
                    }
                    .frame(height: bare ? 40 : 48)
                }
                progress(media)
                HStack(spacing: 46) {
                    control("backward.fill", 24, "Previous track") { director.nextTrack(-1) }
                    control(director.playing ? "pause.fill" : "play.fill", 30, director.playing ? "Pause" : "Play") { director.togglePlaying() }
                    control("forward.fill", 24, "Next track") { director.nextTrack(1) }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(16)
            .frame(width: LockCardController.collapsed.width)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(width: LockCardController.expanded.width, height: LockCardController.expanded.height, alignment: .bottom)
        // The song's art is drawn ahead, and follows a skip while it's the wallpaper (here, not on the cover: the cover
        // isn't on the card then).
        .task(id: media.artKey) {
            if let screen = NotchGeometry.builtIn()?.0 {
                LockWallpaper.shared.song(key: media.artKey, art: media.artwork?.image, on: screen)
            }
        }
    }

    private func showLyrics(_ on: Bool) {
        withAnimation(motion.reduce ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.18)) { director.lockLyrics = on }
    }

    private func cover(_ media: MediaInfo, size: Double, corner: Double) -> some View {
        AlbumArt(media: media, corner: corner)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .matchedGeometryEffect(id: "cover", in: art)

            .contentShape(Rectangle())
            // Where the flying cover starts and lands, in screen points (the card's window is placed by `frame(on:)`).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
                guard let screen = NotchGeometry.builtIn()?.0 else { return }
                let w = LockCardController.frame(on: screen.frame)
                LockWallpaper.shared.cardCover = CGRect(x: w.minX + r.minX, y: w.maxY - r.maxY, width: r.width, height: r.height)
            }
            // A tap makes the art the wallpaper (owner, 11-11: "when you click on the artwork on the lock screen it should
            // become your wallpaper"); a tap on the big cover there brings yours back. The lyrics open from the title.
            .onTapGesture { LockWallpaper.shared.toggleByTap() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(lyricsShown ? "Hide the lyrics" : "Show the lyrics")
    }

    /// Ticks on its own twice a second while playing: the island's ticker doesn't run on the lock screen (the song isn't
    /// in its ears), so the bar sat at 0:00 after a skip (owner, 11-07).
    private func progress(_ media: MediaInfo) -> some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !director.playing || motion.stills)) { _ in
            progressBar(media)
        }
    }

    private func progressBar(_ media: MediaInfo) -> some View {
        let length = media.duration ?? 0
        let elapsed = scrub.map { $0 * length } ?? director.elapsed
        return VStack(spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.9)).frame(width: length > 0 ? w * min(elapsed / length, 1) : 0)
                }
                .frame(height: scrub != nil ? 8 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(length > 0 ? DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(max(v.location.x / max(w, 1), 0), 1) }
                    .onEnded { v in director.seek(to: min(max(v.location.x / max(w, 1), 0), 1) * length); scrub = nil } : nil)
            }
            .frame(height: 14)
            .animation(.easeOut(duration: 0.15), value: scrub != nil)
            HStack {
                Text(clockText(elapsed))
                Spacer()
                Text(length > 0 ? "-" + clockText(max(length - elapsed, 0)) : "")
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(scrub != nil ? 0.95 : 0.55))
        }
    }

    private func control(_ symbol: String, _ size: Double, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 16, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}
