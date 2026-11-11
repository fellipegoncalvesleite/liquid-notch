import AppKit
import ApplicationServices
import OSLog

/// Sets a Focus the way a person would (owner, 11-01: "just make it flash the settings and press it"): Control
/// Center opens for a moment, Focus is pressed, then the mode, and it closes. Nothing public sets a Focus; this
/// uses Accessibility, which the app already has for the volume keys. Logs roles and identifiers only.
///
/// On macOS 27 the system's menu bar items belong to `com.apple.MenuBarAgent` (Control Center's own extras menu bar
/// is empty), each one an `AXMenuBarItem` inside a group (`com.apple.menuextra.focusmode`, `…controlcenter`). Older
/// systems keep them in Control Center, so both are searched.
@MainActor
enum FocusSwitcher {
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "focus")

    /// Turns `mode` on (pressing the mode that's on turns it off). True when the mode was found and pressed.
    @discardableResult
    static func toggle(_ mode: String) async -> Bool {
        let apps = ["com.apple.MenuBarAgent", "com.apple.controlcenter"].compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first.map { AXUIElementCreateApplication($0.processIdentifier) }
        }
        guard AXIsProcessTrusted(), !apps.isEmpty else { log.notice("focus: no Accessibility or Control Center"); return false }
        let extras = apps.flatMap { menuExtras($0) }
        // A Focus item in the menu bar opens the modes directly; else Control Center, then its Focus module.
        let focusExtra = extras.first { id($0)?.contains("focus") == true }
        guard let opener = focusExtra ?? extras.first(where: { id($0)?.contains("controlcenter") == true }) else {
            log.notice("focus: no Control Center item; extras \(extras.compactMap(id).joined(separator: ","), privacy: .public)")
            return false
        }
        AXUIElementPerformAction(opener, kAXPressAction as CFString)
        defer { close(opener) }

        if focusExtra == nil {
            guard let module = await find(in: apps, timeout: 1, where: { e in
                (id(e)?.lowercased().contains("focus") == true || label(e) == "Focus") && isPressable(e)
            }) else { log.notice("focus: Focus module not found"); dump(apps); return false }
            AXUIElementPerformAction(module, kAXPressAction as CFString)
        }
        guard let row = await find(in: apps, timeout: 1, where: { label($0) == mode && isPressable($0) }) else {
            log.notice("focus: mode not found"); dump(apps); return false
        }
        AXUIElementPerformAction(row, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(250))   // let the press land before Control Center closes
        log.notice("focus: pressed")
        return true
    }

    private static func close(_ opener: AXUIElement) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            AXUIElementPerformAction(opener, kAXPressAction as CFString)
        }
    }

    // MARK: - Accessibility

    /// The menu bar items an app shows on the right: the `AXMenuBarItem`s under its extras menu bar (macOS 27 puts each
    /// in a group).
    private static func menuExtras(_ app: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            if attribute(e, kAXRoleAttribute) as? String == kAXMenuBarItemRole as String { out.append(e); return }
            guard depth < 3 else { return }
            for c in children(attribute(e, kAXChildrenAttribute)) { walk(c, depth + 1) }
        }
        for c in children(attribute(app, "AXExtrasMenuBar")) { walk(c, 0) }
        return out
    }

    /// Polls the windows of Control Center and the menu bar agent until a matching element shows (their panels animate
    /// in).
    private static func find(in apps: [AXUIElement], timeout: Double, where match: (AXUIElement) -> Bool) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for w in apps.flatMap({ children(attribute($0, kAXWindowsAttribute)) }) {
                if let e = search(w, match, depth: 0) { return e }
            }
            try? await Task.sleep(for: .milliseconds(60))
        } while Date() < deadline
        return nil
    }

    private static func search(_ e: AXUIElement, _ match: (AXUIElement) -> Bool, depth: Int) -> AXUIElement? {
        if match(e) { return e }
        guard depth < 12 else { return nil }
        for c in children(attribute(e, kAXChildrenAttribute)) {
            if let hit = search(c, match, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func children(_ v: CFTypeRef?) -> [AXUIElement] {
        if let list = v as? [AXUIElement] { return list }
        if let v, CFGetTypeID(v) == AXUIElementGetTypeID() { return children(attribute(v as! AXUIElement, kAXChildrenAttribute)) }
        return []
    }

    private static func id(_ e: AXUIElement) -> String? { attribute(e, kAXIdentifierAttribute) as? String }

    private static func label(_ e: AXUIElement) -> String? {
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = attribute(e, a) as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func isPressable(_ e: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success, let list = names as? [String] else { return false }
        return list.contains(kAXPressAction as String)
    }

    /// When something isn't found: the roles and identifiers Control Center and the menu bar agent show (no other text).
    private static func dump(_ apps: [AXUIElement]) {
        var parts: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 8, parts.count < 80 else { return }
            let role = attribute(e, kAXRoleAttribute) as? String ?? "?"
            parts.append("\(String(repeating: ".", count: depth))\(role)\(id(e).map { "#\($0)" } ?? "")")
            for c in children(attribute(e, kAXChildrenAttribute)) { walk(c, depth + 1) }
        }
        for w in apps.flatMap({ children(attribute($0, kAXWindowsAttribute)) }) { walk(w, 0) }
        log.notice("focus tree: \(parts.joined(separator: " "), privacy: .public)")
    }
}
