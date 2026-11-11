import ColorSync
import CoreGraphics
import Foundation

/// Reads what the window list says about the screen: a fullscreen window in front, a menu open
/// under the menu bar. Window bounds and levels need no Screen Recording permission (titles do,
/// and aren't used). Pure functions over `WindowInfo`, so they can be tested with made-up lists.
enum ContextSensing {
    struct WindowInfo: Equatable, Sendable {
        var pid: Int32
        var layer: Int
        /// Global display coordinates, top-left origin.
        var bounds: CGRect
        var owner = ""
    }

    /// The level pop-up menus (the menu bar's, status items', context menus) draw at.
    static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// The on-screen windows' numbers only: far less for the window server to put together than their descriptions
    /// (0.055 ms against 0.36 ms here). `CGWindowListCreate`, which Swift doesn't import, called through its symbol; nil if
    /// it can't be found.
    static func windowNumbers() -> [UInt32]? {
        guard let listCreate,
              let list = listCreate(CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements]).rawValue, kCGNullWindowID)?
                .takeRetainedValue() else { return nil }
        return (0..<CFArrayGetCount(list)).map { UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(list, $0))) }
    }

    private typealias ListCreate = @convention(c) (UInt32, UInt32) -> Unmanaged<CFArray>?
    private static let listCreate: ListCreate? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreate")
        .map { unsafeBitCast($0, to: ListCreate.self) }

    /// The type of the Space in front (SkyLight's `SLSSpaceGetType`: 0 a desktop, 4 a fullscreen app's Space), nil if it
    /// can't be read. The window list can't tell a fullscreen window from a zoomed one on a notched screen when the menu
    /// bar window stays listed (owner, 11-07: a movie fullscreen in Chrome kept the island and the desktop colours), so
    /// the Space itself is asked first. Cheap: two calls into the window server.
    /// The Space in front on `display` (the notched screen; with separate Spaces per display, a fullscreen app on another
    /// screen isn't ours), else the active one.
    static func activeSpaceType(display: CGDirectDisplayID? = nil) -> Int32? {
        guard let main = sky.main, let type = sky.type else { return nil }
        let cid = main()
        var space: UInt64 = 0
        if let display, let current = sky.current, let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
           let name = CFUUIDCreateString(nil, uuid) {
            space = current(cid, name)
        }
        if space == 0, let active = sky.active { space = active(cid) }
        return space == 0 ? nil : type(cid, space)
    }

    /// SkyLight's type of a fullscreen app's Space.
    static let fullscreenSpaceType: Int32 = 4

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    private struct Sky: @unchecked Sendable {
        var main: MainConnection?, active: ActiveSpace?, current: CurrentSpace?, type: SpaceType?
    }
    private static let sky: Sky = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW) else {
            return Sky()
        }
        return Sky(main: dlsym(h, "SLSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) },
                   active: dlsym(h, "SLSGetActiveSpace").map { unsafeBitCast($0, to: ActiveSpace.self) },
                   current: dlsym(h, "SLSManagedDisplayGetCurrentSpace").map { unsafeBitCast($0, to: CurrentSpace.self) },
                   type: dlsym(h, "SLSSpaceGetType").map { unsafeBitCast($0, to: SpaceType.self) })
    }()

    /// The windows on screen now.
    static func windows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { return nil }
            return WindowInfo(pid: pid, layer: layer, bounds: rect, owner: w[kCGWindowOwnerName as String] as? String ?? "")
        }
    }

    /// The app shows a real window in the current Space (not only its menu bar: hidden, minimised, on another Space or
    /// every window closed). Normal-level windows of a usable size; a sliver or a toolbar popover doesn't count.
    static func showsWindow(_ windows: [WindowInfo], pid: Int32) -> Bool {
        windows.contains { $0.pid == pid && $0.layer == 0 && $0.bounds.width >= 200 && $0.bounds.height >= 150 }
    }

    enum Cover { case none, belowMenuBar, wholeScreen }

    /// How much of the screen the frontmost app's biggest window covers: all of it, or everything
    /// below the menu bar. On a notched screen a fullscreen window stops under the notch, which is
    /// also exactly what a zoomed window does, so `belowMenuBar` alone doesn't mean fullscreen.
    static func cover(_ windows: [WindowInfo], frontPID: Int32, screen: CGRect, menuBarHeight: Double) -> Cover {
        var best = Cover.none
        for w in windows where w.pid == frontPID && w.layer == 0
            && abs(w.bounds.minX - screen.minX) <= 1 && abs(w.bounds.width - screen.width) <= 1
            && abs(w.bounds.maxY - screen.maxY) <= 1 {
            if w.bounds.minY <= screen.minY + 1 { return .wholeScreen }
            if w.bounds.minY <= screen.minY + menuBarHeight + 1 { best = .belowMenuBar }
        }
        return best
    }

    /// The menu bar is showing on this screen (a fullscreen Space hides it).
    static func menuBarVisible(_ windows: [WindowInfo], screen: CGRect, menuBarHeight: Double) -> Bool {
        windows.contains { w in
            w.layer == Int(CGWindowLevelForKey(.mainMenuWindow)) && w.owner == "Window Server"
                && w.bounds.height <= menuBarHeight + 4 && abs(w.bounds.minY - screen.minY) <= 1
                && w.bounds.intersects(screen)
        }
    }

    /// Fullscreen: a window covers the whole screen, or covers everything below the menu bar while
    /// the menu bar is hidden.
    static func fullscreen(_ windows: [WindowInfo], frontPID: Int32, screen: CGRect, menuBarHeight: Double) -> Bool {
        switch cover(windows, frontPID: frontPID, screen: screen, menuBarHeight: menuBarHeight) {
        case .wholeScreen: true
        case .belowMenuBar: !menuBarVisible(windows, screen: screen, menuBarHeight: menuBarHeight)
        case .none: false
        }
    }

    /// The frontmost app's front window (its first normal window in the list, which runs front to back, on screen only)
    /// is mostly on `screen`. No window on screen (minimized, hidden): false. Global top-left coordinates.
    static func frontWindowOnScreen(_ windows: [WindowInfo], frontPID: Int32, screen: CGRect) -> Bool {
        guard let w = windows.first(where: { $0.pid == frontPID && $0.layer == 0 && $0.bounds.width > 1 && $0.bounds.height > 1 })
        else { return false }
        let shared = w.bounds.intersection(screen)
        return !shared.isNull && shared.width * shared.height * 2 > w.bounds.width * w.bounds.height
    }

    /// A menu hangs from the menu bar of this screen (an app's menu or a status item's), not ours.
    static func menuOpen(_ windows: [WindowInfo], ownPID: Int32, screen: CGRect, menuBarHeight: Double) -> Bool {
        windows.contains { w in
            w.pid != ownPID && w.layer == popUpMenuLayer && w.bounds.height > 4
                && w.bounds.intersects(screen) && w.bounds.minY <= screen.minY + menuBarHeight + 4
        }
    }
}

/// Reads the window list off the main thread, in full only when the windows on screen change (or once a second: a window
/// resizing changes no numbers). The window server can take milliseconds to answer while it's busy (a profile with music
/// playing, 11-07: the island's main thread waited ~3 ms on it five times a second), and the island must never wait on
/// it. Used only on its own queue.
final class WindowReader: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.fellipe.liquidnotch.windows", qos: .utility)
    private var numbers: [UInt32]?
    private var windows: [ContextSensing.WindowInfo] = []
    private var at = -Double.infinity

    func read(force: Bool) -> [ContextSensing.WindowInfo] {
        let now = ProcessInfo.processInfo.systemUptime, current = ContextSensing.windowNumbers()
        if !force, let current, current == numbers, now - at < 1 { return windows }
        windows = ContextSensing.windows()
        numbers = current
        at = now
        return windows
    }
}
