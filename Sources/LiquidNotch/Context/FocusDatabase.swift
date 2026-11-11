import Foundation

/// Which Focus is on (11-11: "it doesn't recognize if it's already on or which mode"). The public API
/// (`INFocusStatusCenter`) only says on or off; macOS keeps the active mode in `~/Library/DoNotDisturb/DB`:
/// `Assertions.json` names the modes asserted now (by their identifier) and `ModeConfigurations.json` gives each one's
/// name and symbol. Both need Full Disk Access (asked for Messages). Undocumented, so the reading is tolerant: it looks
/// for the keys anywhere in the files, and anything it can't make sense of reads as "not readable".
enum FocusDatabase {
    struct Mode: Equatable, Sendable {
        var identifier: String
        var name: String
        var symbol: String?
    }

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")

    /// nil: not readable (no Full Disk Access, or a layout this doesn't know). `.some(nil)`: no Focus on.
    static func read(folder: URL = folder) -> Mode?? {
        guard let a = try? Data(contentsOf: folder.appendingPathComponent("Assertions.json")),
              let assertions = try? JSONSerialization.jsonObject(with: a) else { return nil }
        let configs = (try? Data(contentsOf: folder.appendingPathComponent("ModeConfigurations.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return .some(active(assertions: assertions, configurations: configs))
    }

    /// The first asserted mode, named from the configurations (or from its identifier when they don't name it).
    static func active(assertions: Any, configurations: Any?) -> Mode? {
        guard let id = strings(forKey: "assertionDetailsModeIdentifier", in: assertions).first else { return nil }
        let mode = configurations.flatMap { modeDict(id, in: $0) }
        let name = (mode?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName(id)
        return Mode(identifier: id, name: name, symbol: mode?["symbolImageName"] as? String)
    }

    /// "com.apple.donotdisturb.mode.default" → Do Not Disturb, ".sleep" → Sleep; anything else, its last part.
    static func fallbackName(_ id: String) -> String {
        switch id.split(separator: ".").last.map(String.init) ?? id {
        case "default": "Do Not Disturb"
        case "sleep": "Sleep"
        case "driving": "Driving"
        case "workout": "Fitness"
        case "reduce-interruptions": "Reduce Interruptions"
        case let last: last.capitalized
        }
    }

    private static func strings(forKey key: String, in node: Any) -> [String] {
        if let d = node as? [String: Any] {
            var out: [String] = []
            if let s = d[key] as? String { out.append(s) }
            for v in d.values { out += strings(forKey: key, in: v) }
            return out
        }
        if let a = node as? [Any] { return a.flatMap { strings(forKey: key, in: $0) } }
        return []
    }

    /// The `mode` dictionary whose `modeIdentifier` is `id`, wherever it sits.
    private static func modeDict(_ id: String, in node: Any) -> [String: Any]? {
        if let d = node as? [String: Any] {
            if let m = d["mode"] as? [String: Any], m["modeIdentifier"] as? String == id { return m }
            if d["modeIdentifier"] as? String == id, d["name"] != nil { return d }
            for v in d.values { if let m = modeDict(id, in: v) { return m } }
        } else if let a = node as? [Any] {
            for v in a { if let m = modeDict(id, in: v) { return m } }
        }
        return nil
    }
}
