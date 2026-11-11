import AppKit

/// Borderless, transparent, non-activating panel that sits over the menu bar.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none

        // Level: the menu bar is kCGMainMenuWindowLevel (24) and status items sit at
        // kCGStatusWindowLevel (25). +3 clears both so the ears draw over the menu
        // bar, while pop-up menus (101), the system HUDs and the screen saver all
        // stay above us. Same band other notch apps use.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        // On every Space (fullscreen ones too, so alerts and the HUD can still show there),
        // never moved by Mission Control, not in Cmd-` cycling. Over a fullscreen window the
        // island hides everything else itself (`DesktopContext.fullscreen`, from ContextMonitor).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    // AppKit nudges windows out from under the menu bar; this one belongs there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // Key only when a text field needs it (the Messages reply); `becomesKeyOnlyIfNeeded` keeps
    // every other click from taking focus, and the panel never activates the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
