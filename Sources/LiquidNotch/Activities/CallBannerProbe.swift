import AppKit
import ApplicationServices
import OSLog

/// Spike for incoming calls (P4): watches Notification Center over Accessibility and logs how each new
/// banner is built (element roles and button labels only; never other text, so no names or message
/// content), so the first real FaceTime or iPhone call shows how to detect it and press Accept.
/// Category `calls`.
@MainActor
final class CallBannerProbe {
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "calls")
    private var observer: AXObserver?
    private var app: AXUIElement?

    func start() {
        guard observer == nil, AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }
        let pid = nc.processIdentifier
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, info in
            guard let info else { return }
            let probe = Unmanaged<CallBannerProbe>.fromOpaque(info).takeUnretainedValue()
            let ref = ElementRef(element)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { probe.describe(ref.element) }
            }
        }, &obs) == .success, let obs else { return }
        let element = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, element, kAXWindowCreatedNotification as CFString, me)
        AXObserverAddNotification(obs, element, kAXCreatedNotification as CFString, me)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        app = element
        Self.log.notice("call probe: watching Notification Center")
    }

    private func describe(_ root: AXUIElement) {
        var roles: [String: Int] = [:]
        var buttons: [String] = []
        var identifiers: Set<String> = []
        var budget = 300
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard budget > 0, depth < 10 else { return }
            budget -= 1
            let role = string(e, kAXRoleAttribute) ?? "?"
            roles[role, default: 0] += 1
            if let id = string(e, kAXIdentifierAttribute) { identifiers.insert(id) }
            if role == kAXButtonRole as String {
                buttons.append(string(e, kAXTitleAttribute) ?? string(e, kAXDescriptionAttribute) ?? "untitled")
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                for c in list { walk(c, depth + 1) }
            }
        }
        walk(root, 0)
        guard !buttons.isEmpty || roles.count > 1 else { return }
        let summary = roles.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        Self.log.notice("banner: buttons [\(buttons.joined(separator: ", "), privacy: .public)] ids [\(identifiers.sorted().joined(separator: ", "), privacy: .public)] roles \(summary, privacy: .public)")
    }

    private func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}

/// Carries an AXUIElement across the observer callback's hop (CF types are thread-safe to retain).
private struct ElementRef: @unchecked Sendable {
    let element: AXUIElement
    init(_ e: AXUIElement) { element = e }
}
