import AppKit

/// Where the island's notch is: the physical notch, read from the system, or a virtual one drawn at the top centre of a
/// screen without a notch (11-11: an M1 Air showed nothing). Everything that needs the notch or its screen asks
/// `current()`, so the choice is made in one place.
struct NotchGeometry: Equatable {
    let displayID: CGDirectDisplayID
    /// Screen frame in global AppKit coordinates (origin bottom-left).
    let screenFrame: NSRect
    let notchMinX: CGFloat      // global
    let notchMaxX: CGFloat      // global
    /// Height of the notch: the hardware's, or the menu bar's for a virtual one.
    let notchHeight: CGFloat
    let scale: CGFloat
    /// No hardware under it: the island's own black is all there is.
    let isVirtual: Bool

    var notchWidth: CGFloat { notchMaxX - notchMinX }
    var notchCenterX: CGFloat { (notchMinX + notchMaxX) / 2 }

    /// A virtual notch's width: a MacBook notch's, so the collapsed island looks the same.
    static let virtualWidth: CGFloat = 185

    /// A panel of `size` centered on the notch with its top edge on the top of the screen.
    func panelFrame(size: CGSize) -> NSRect {
        NSRect(x: (notchCenterX - size.width / 2).rounded(), y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }

    // MARK: Settings

    /// Which screen the island goes on.
    enum Placement: String, CaseIterable {
        /// The built-in screen; the main one while it's off (lid closed).
        case builtIn
        /// The screen with the menu bar (System Settings › Displays' main display).
        case main
    }

    /// Whether a real notch is used where there is one.
    enum Mode: String, CaseIterable {
        case auto
        case alwaysVirtual
    }

    static let placementKey = "notchPlacement"
    static let modeKey = "notchMode"
    /// Posted when either setting changes, so the surface lays itself out again.
    static let settingsChanged = Notification.Name("LiquidNotch.notchSettingsChanged")

    static var placement: Placement {
        get { UserDefaults.standard.string(forKey: placementKey).flatMap(Placement.init) ?? .main }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: placementKey); NotificationCenter.default.post(name: settingsChanged, object: nil) }
    }

    static var mode: Mode {
        get { simulateNoNotch ? .alwaysVirtual : UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey); NotificationCenter.default.post(name: settingsChanged, object: nil) }
    }

    /// `-simulateNoNotch` at launch: every screen is treated as notchless, to try virtual mode on a notched Mac.
    static let simulateNoNotch = CommandLine.arguments.contains("-simulateNoNotch")

    // MARK: Choosing

    /// What's read from one screen, so the choice can be tested without the hardware.
    struct Screen {
        var displayID: CGDirectDisplayID
        var isBuiltIn: Bool
        var frame: NSRect
        var visibleFrame: NSRect
        var safeTop: CGFloat
        var auxLeftWidth: CGFloat?
        var auxRightWidth: CGFloat?
        var scale: CGFloat

        /// The menu bar's height: what the visible frame leaves at the top; the status bar's thickness when the menu
        /// bar hides itself.
        func menuBarHeight(statusBarThickness: CGFloat) -> CGFloat {
            let gap = frame.maxY - visibleFrame.maxY
            return gap > 0 ? gap : max(safeTop, statusBarThickness)
        }
    }

    /// The screen to use (index into `screens`, whose first is the main one) and its notch.
    static func choose(_ screens: [Screen], placement: Placement, mode: Mode,
                       statusBarThickness: CGFloat = 24) -> (index: Int, geometry: NotchGeometry)? {
        guard !screens.isEmpty else { return nil }
        let index = placement == .builtIn ? screens.firstIndex(where: \.isBuiltIn) ?? 0 : 0
        let s = screens[index]
        if mode == .auto, s.safeTop > 0, let left = s.auxLeftWidth, let right = s.auxRightWidth {
            // Widths of the unobscured areas, measured from the screen's own edges, so this holds wherever the screen
            // sits in the global arrangement.
            return (index, NotchGeometry(displayID: s.displayID, screenFrame: s.frame,
                                         notchMinX: s.frame.minX + left, notchMaxX: s.frame.maxX - right,
                                         notchHeight: s.safeTop, scale: s.scale, isVirtual: false))
        }
        let mid = s.frame.midX
        return (index, NotchGeometry(displayID: s.displayID, screenFrame: s.frame,
                                     notchMinX: mid - virtualWidth / 2, notchMaxX: mid + virtualWidth / 2,
                                     notchHeight: s.menuBarHeight(statusBarThickness: statusBarThickness),
                                     scale: s.scale, isVirtual: true))
    }

    /// The island's screen and notch now, from the connected screens and the settings. Nil only with no screen.
    @MainActor
    static func current() -> (NSScreen, NotchGeometry)? {
        let screens = NSScreen.screens
        let read = screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Screen(displayID: id, isBuiltIn: CGDisplayIsBuiltin(id) != 0, frame: screen.frame,
                          visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
                          auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
                          auxRightWidth: screen.auxiliaryTopRightArea?.width, scale: screen.backingScaleFactor)
        }
        guard let (i, g) = choose(read, placement: placement, mode: mode,
                                  statusBarThickness: NSStatusBar.system.thickness) else { return nil }
        return (screens[i], g)
    }
}
