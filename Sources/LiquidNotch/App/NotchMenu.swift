import AppKit

/// The right-click menu's Show On and Notch submenus (11-11): which screen the island goes on, and whether a real notch
/// is used where there is one. Then Check for Updates….
@MainActor
final class NotchMenu: NSObject, NSMenuItemValidation {
    static let shared = NotchMenu()

    func add(to menu: NSMenu) {
        let show = NSMenu()
        for (p, title) in [(NotchGeometry.Placement.builtIn, "Built-in Display"), (.main, "Main Display")] {
            let item = show.addItem(withTitle: title, action: #selector(setPlacement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            item.state = NotchGeometry.placement == p ? .on : .off
        }
        menu.addItem(withTitle: "Show On", action: nil, keyEquivalent: "").submenu = show

        let notch = NSMenu()
        for (m, title) in [(NotchGeometry.Mode.auto, "Auto"), (.alwaysVirtual, "Always Virtual")] {
            let item = notch.addItem(withTitle: title, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = NotchGeometry.mode == m ? .on : .off
            // -simulateNoNotch holds it on Always Virtual.
            item.isEnabled = !NotchGeometry.simulateNoNotch
        }
        notch.autoenablesItems = false
        menu.addItem(withTitle: "Notch", action: nil, keyEquivalent: "").submenu = notch

        // Updates (1.1): Sparkle checks daily by itself; this checks now.
        let update = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
    }

    @objc private func checkForUpdates() { Updates.shared.checkNow() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(checkForUpdates) || Updates.shared.canCheck
    }

    @objc private func setPlacement(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = NotchGeometry.Placement(rawValue: raw) { NotchGeometry.placement = p }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = NotchGeometry.Mode(rawValue: raw) { NotchGeometry.mode = m }
    }
}
