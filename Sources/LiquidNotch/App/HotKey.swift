import Carbon.HIToolbox

/// A global keyboard shortcut through Carbon's hot keys: it needs no permission (unlike an event tap) and the key
/// doesn't reach the app in front.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    /// `modifiers`: Carbon's (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`). Nil if the system refuses it (taken).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.install()
        let id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4E_4F54), id: id)   // 'LNOT'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
        else { return nil }
        Self.actions[id] = action
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKey.actions[id]?() }   // Carbon delivers hot keys on the main thread
            return noErr
        }, 1, &spec, nil, nil)
    }
}
