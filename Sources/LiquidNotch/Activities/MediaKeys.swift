import AppKit
import AudioToolbox
import CoreAudio
import IslandCore
import OSLog

/// The default output's volume and mute (CoreAudio).
enum SystemVolume {
    private static var device: AudioObjectID? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The volume (0…1), or nil when the output has none we can set (HDMI, some interfaces).
    static var level: Double? {
        guard let dev = device else { return nil }
        var addr = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return Double(v)
    }

    static var muted: Bool {
        guard let dev = device else { return false }
        var addr = muteAddress
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m != 0
    }

    @discardableResult
    static func set(_ level: Double) -> Bool {
        guard let dev = device else { return false }
        var addr = volumeAddress
        var v = Float32(min(max(level, 0), 1))
        guard AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr else { return false }
        if level > 0 && muted { setMuted(false) }
        return true
    }

    @discardableResult
    static func setMuted(_ on: Bool) -> Bool {
        guard let dev = device else { return false }
        var addr = muteAddress
        var m = UInt32(on ? 1 : 0)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }
}

/// The built-in display's brightness, through DisplayServices (private; `DisplayServicesGetBrightness`
/// read 0.635 on this Mac).
@MainActor
enum SystemBrightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getter = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setter = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }

    /// The display the keys act on: the built-in (notched) one.
    static var display: CGDirectDisplayID = CGMainDisplayID()

    static var level: Double? {
        guard let getter else { return nil }
        var b: Float = 0
        return getter(display, &b) == 0 ? Double(b) : nil
    }

    @discardableResult
    static func set(_ level: Double) -> Bool {
        guard let setter else { return false }
        return setter(display, Float(min(max(level, 0), 1))) == 0
    }
}

/// The volume and brightness keys, caught before the system sees them, so the island's HUD replaces
/// the system's instead of showing beside it. Needs Accessibility. A key is only swallowed when the
/// change was applied here; anything else goes on to the system untouched.
@MainActor
final class MediaKeyTap {
    enum Key: Int { case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

    /// A key press was handled: show the HUD at this level.
    var onLevel: ((HUDLevel) -> Void)?
    /// ⌥Space: quick ask (owner, 11-07: "give a better shortcut for asking, or override claude current shortcut"). The
    /// tap sees it before the apps do and swallows it, so Claude's own quick entry doesn't open as well.
    var onAskKey: (() -> Void)?
    private var swallowSpaceUp = false
    private(set) var running = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "keys")

    struct HUDLevel: Equatable {
        var brightness: Bool
        var level: Double
    }

    /// Option alone (no ⌘, ⌃ or ⇧) with Space.
    nonisolated static func isAskChord(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate) && flags.isDisjoint(with: [.maskCommand, .maskControl, .maskShift])
    }

    /// Decodes an NX_SYSDEFINED media-key event's data1: the key, and whether it's going down.
    nonisolated static func decode(subtype: Int16, data1: Int) -> (key: Key, down: Bool)? {
        guard subtype == 8, let key = Key(rawValue: (data1 & 0xFFFF0000) >> 16) else { return nil }
        let flags = data1 & 0xFFFF
        return (key, (flags & 0xFF00) >> 8 == 0x0A)
    }

    /// The next level after a key: sixteen steps, or sixty-four with ⌥⇧ (as macOS does).
    nonisolated static func step(_ level: Double, up: Bool, fine: Bool) -> Double {
        let n = fine ? 64.0 : 16.0
        let next = up ? (level * n + 0.5).rounded(.down) / n + 1 / n : (level * n - 0.5).rounded(.up) / n - 1 / n
        return min(max(next, 0), 1)
    }

    func start() {
        guard !running, AXIsProcessTrusted() else { return }
        // NX_SYSDEFINED for the media keys; key down and up only to catch ⌥Space (anything else passes straight on).
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(info).takeUnretainedValue()
            // Added to the main run loop, so this runs on the main thread.
            let swallow = MainActor.assumeIsolated { tap.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: me) else {
            Self.log.notice("key tap unavailable")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        running = true
        Self.log.notice("key tap running")
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        running = false
    }

    /// True when the key was handled here (and must not reach the system).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return false
        }
        if type == .keyDown || type == .keyUp {
            guard event.getIntegerValueField(.keyboardEventKeycode) == 49 else { return false }   // Space
            if type == .keyUp { defer { swallowSpaceUp = false }; return swallowSpaceUp }
            guard Self.isAskChord(event.flags), onAskKey != nil else { return false }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onAskKey?() }
            swallowSpaceUp = true
            return true
        }
        guard let ns = NSEvent(cgEvent: event), let (key, down) = Self.decode(subtype: ns.subtype.rawValue, data1: ns.data1)
        else { return false }
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        switch key {
        case .soundUp, .soundDown, .mute:
            guard let current = SystemVolume.level else { return false }
            guard down else { return true }        // the key's release is ours too
            var level = SystemVolume.muted ? 0 : current
            if key == .mute {
                let mute = !SystemVolume.muted
                guard SystemVolume.setMuted(mute) else { return false }
                level = mute ? 0 : current
            } else {
                level = Self.step(level, up: key == .soundUp, fine: fine)
                guard SystemVolume.set(level) else { return false }
                if level == 0 { SystemVolume.setMuted(true) }
            }
            onLevel?(HUDLevel(brightness: false, level: level))
            return true
        case .brightnessUp, .brightnessDown:
            guard let current = SystemBrightness.level else { return false }
            guard down else { return true }
            let level = Self.step(current, up: key == .brightnessUp, fine: fine)
            guard SystemBrightness.set(level) else { return false }
            onLevel?(HUDLevel(brightness: true, level: level))
            return true
        }
    }
}
