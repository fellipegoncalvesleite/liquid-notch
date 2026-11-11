import AppKit

/// Where the physical notch is, read from the system rather than hardcoded.
struct NotchGeometry: Equatable {
    let displayID: CGDirectDisplayID
    /// Screen frame in global AppKit coordinates (origin bottom-left).
    let screenFrame: NSRect
    let notchMinX: CGFloat      // global
    let notchMaxX: CGFloat      // global
    /// Height of the notch, which on notched Macs is also the menu bar height.
    let notchHeight: CGFloat
    let scale: CGFloat

    var notchWidth: CGFloat { notchMaxX - notchMinX }
    var notchCenterX: CGFloat { (notchMinX + notchMaxX) / 2 }

    /// The built-in notched screen, if one is connected and awake. With the lid
    /// closed the built-in screen disappears from `NSScreen.screens`, so this is nil.
    static func builtIn() -> (NSScreen, NotchGeometry)? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let top = screen.safeAreaInsets.top
            guard CGDisplayIsBuiltin(id) != 0, top > 0,
                  let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
            else { continue }
            // Use the widths of the unobscured areas, measured from the screen's own
            // edges, so this holds wherever the screen sits in the global arrangement.
            let frame = screen.frame
            return (screen, NotchGeometry(
                displayID: id, screenFrame: frame,
                notchMinX: frame.minX + left.width, notchMaxX: frame.maxX - right.width,
                notchHeight: top, scale: screen.backingScaleFactor))
        }
        return nil
    }

    /// A panel of `size` centered on the notch with its top edge on the top of the screen.
    func panelFrame(size: CGSize) -> NSRect {
        NSRect(x: (notchCenterX - size.width / 2).rounded(), y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}
