import Foundation

/// Adds the notch's hook to Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`), only when the
/// Setup row is pressed (owner, 11-06: "Yes, add them"), and takes it out again. Each file is backed up first, the
/// owner's own hooks are left alone (ours are told apart by the script's path), and the file must still parse after
/// the edit, or the backup goes back.
enum HookInstaller {
    enum Failure: Error { case unreadable(URL), invalidAfterWrite(URL) }

    struct Target {
        let provider: String
        let file: URL
        let events: [String]
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func targets(_ home: URL = home) -> [Target] {
        [
            Target(provider: "claude", file: home.appendingPathComponent(".claude/settings.json"),
                   events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                            "Notification", "Stop", "StopFailure", "SessionEnd"]),
            // Codex has no Notification or StopFailure event.
            Target(provider: "codex", file: home.appendingPathComponent(".codex/hooks.json"),
                   events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                            "Stop", "SessionEnd"]),
        ]
    }

    /// Beside the socket (`AgentSocket.path`), which is where the script looks for it.
    static func scriptURL(_ home: URL = home) -> URL {
        home.appendingPathComponent("Library/Application Support/Liquid Notch/agent-hook.sh")
    }

    /// Every event but an approval reads its input, sends it in the background and returns at once; an approval
    /// waits up to 25 s for Allow or Deny (its hook timeout is 30). Fail-open: no socket, no notch, no answer: exit 0
    /// with nothing printed, and the session goes on as if the hook weren't there. `__CFBundleIdentifier` names the
    /// app the session runs in (Claude's desktop app, Codex, a terminal).
    static let script = """
    #!/bin/sh
    # Liquid Notch: tells the notch what a Claude Code or Codex session is doing. Fail-open: if Liquid Notch isn't
    # listening, this exits 0 at once and changes nothing. Only PermissionRequest (Allow or Deny, up to 25 s) and Claude
    # asking you a question (your pick, up to 10 minutes: Claude waits for you anyway) wait for an answer.
    SOCK="$HOME/Library/Application Support/Liquid Notch/agents.sock"
    [ -S "$SOCK" ] || exit 0
    EVENT="$1"; PROVIDER="$2"
    INPUT=$(tr -d '\n')
    WAIT=0
    [ "$EVENT" = PermissionRequest ] && WAIT=25
    if [ "$EVENT" = PreToolUse ] && printf '%s' "$INPUT" | /usr/bin/grep -q '"tool_name"[[:space:]]*:[[:space:]]*"AskUserQuestion"'; then WAIT=600; fi
    if [ "$WAIT" != 0 ]; then
      printf '%s\t%s\t%s\t%s\n' "$PROVIDER" "$EVENT" "$__CFBundleIdentifier" "$INPUT" | /usr/bin/nc -U -w "$WAIT" "$SOCK" 2>/dev/null
    else
      ( printf '%s\t%s\t%s\t%s\n' "$PROVIDER" "$EVENT" "$__CFBundleIdentifier" "$INPUT" | /usr/bin/nc -U -w 1 "$SOCK" ) </dev/null >/dev/null 2>&1 &
    fi
    exit 0

    """

    /// Each hook's timeout: an approval waits 25 s (30), Claude's PreToolUse up to 10 minutes for a question's pick
    /// (610), SessionEnd 2 (Codex clamps it to 3), the rest 5.
    static func timeout(_ event: String, provider: String) -> Int {
        if event == "PermissionRequest" { return 30 }
        if event == "PreToolUse" && provider == "claude" { return 610 }
        return event == "SessionEnd" ? 2 : 5
    }

    /// Our installed entries carry an older timeout (an update changed it): `install` again rewrites only our entries,
    /// with a backup of each file first.
    static func needsUpgrade(_ home: URL = home) -> Bool {
        guard installed(home) else { return false }
        for t in targets(home) {
            guard let data = try? Data(contentsOf: t.file),
                  let hooks = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["hooks"] as? [String: Any] else { continue }
            for event in t.events {
                for g in hooks[event] as? [[String: Any]] ?? [] where isOurs(g, home) {
                    for h in g["hooks"] as? [[String: Any]] ?? [] where (h["timeout"] as? Int) != timeout(event, provider: t.provider) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Rewrites our own script (not the settings files) when it changed in an update, so an installed hook keeps up.
    static func refreshScript(_ home: URL = home) {
        let url = scriptURL(home)
        guard installed(home), (try? String(contentsOf: url, encoding: .utf8)) != script else { return }
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Our entries are in both files.
    static func installed(_ home: URL = home) -> Bool { targets(home).allSatisfy { contains($0, home) } }

    static func install(_ home: URL = home) throws {
        let script = scriptURL(home)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        do {
            for t in targets(home) {
                try edit(t, home) { hooks in
                    for event in t.events {
                        var groups = hooks[event] as? [[String: Any]] ?? []
                        // Codex clamps SessionEnd to 3 s (and warns), Claude Code budgets 1.5 s for it.
                        let timeout = Self.timeout(event, provider: t.provider)
                        groups.append(["hooks": [["type": "command", "command": command(event, t.provider, home),
                                                  "timeout": timeout]]])
                        hooks[event] = groups
                    }
                }
            }
        } catch {
            try? uninstall(home)   // both or neither
            throw error
        }
    }

    /// Takes our entries out (files without them aren't touched) and the script with them.
    static func uninstall(_ home: URL = home) throws {
        for t in targets(home) where contains(t, home) {
            try edit(t, home) { _ in }
        }
        try? FileManager.default.removeItem(at: scriptURL(home))
    }

    static func command(_ event: String, _ provider: String, _ home: URL = home) -> String {
        "\"\(scriptURL(home).path)\" \(event) \(provider)"
    }

    private static func isOurs(_ group: [String: Any], _ home: URL) -> Bool {
        let path = scriptURL(home).path
        return (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(path) == true }
    }

    private static func contains(_ t: Target, _ home: URL) -> Bool {
        guard let data = try? Data(contentsOf: t.file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]] ?? []).contains { isOurs($0, home) } }
    }

    /// Backs the file up, takes our old entries out, lets `change` add new ones, writes it, and checks it parses.
    private static func edit(_ t: Target, _ home: URL, _ change: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: t.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        let before = fm.fileExists(atPath: t.file.path) ? try Data(contentsOf: t.file) : nil
        if let before {
            if !before.isEmpty {
                guard let r = (try? JSONSerialization.jsonObject(with: before)) as? [String: Any] else { throw Failure.unreadable(t.file) }
                root = r
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = f.string(from: Date()).replacingOccurrences(of: ":", with: "")
            try before.write(to: t.file.deletingLastPathComponent()
                .appendingPathComponent("\(t.file.lastPathComponent).liquid-notch-backup-\(stamp)"))
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }   // not ours to judge
            let kept = groups.filter { !isOurs($0, home) }
            if kept.count < groups.count { hooks[event] = kept.isEmpty ? nil : kept }
        }
        change(&hooks)
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: t.file, options: .atomic)
        guard let check = try? Data(contentsOf: t.file), (try? JSONSerialization.jsonObject(with: check)) is [String: Any] else {
            if let before { try? before.write(to: t.file, options: .atomic) }
            throw Failure.invalidAfterWrite(t.file)
        }
    }
}
