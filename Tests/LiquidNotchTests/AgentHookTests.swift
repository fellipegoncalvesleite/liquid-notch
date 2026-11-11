import IslandCore
import XCTest
@testable import LiquidNotch

/// Phase 2 of the agents, end to end: the installer on a throwaway home (never the real ~/.claude or ~/.codex), the
/// hook script against a real socket, and the director holding approvals for the card.
@MainActor
final class AgentHookTests: XCTestCase {
    /// Short, because a Unix socket's path is at most 103 bytes.
    private func makeHome() -> URL {
        let home = URL(fileURLWithPath: "/tmp/lnt-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func ours(_ hooks: [String: Any], _ event: String) -> Int {
        (hooks[event] as? [[String: Any]] ?? []).filter { "\($0)".contains("agent-hook.sh") }.count
    }

    // Their own hooks and settings stay; ours go in once per event, however often it's switched on; switched off, the
    // file is as it was and the script is gone. Each edit backs the file up first.
    func testTheInstallerKeepsTheirHooksAndUndoesCleanly() throws {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = #"{"env":{"A":"1"},"hooks":{"Stop":[{"hooks":[{"command":"say done","type":"command"}]}]},"model":"opus"}"#
        try theirs.write(to: claude, atomically: true, encoding: .utf8)

        try HookInstaller.install(home)
        try HookInstaller.install(home)
        XCTAssertTrue(HookInstaller.installed(home))
        for t in HookInstaller.targets(home) {
            let hooks = try json(t.file)["hooks"] as? [String: Any] ?? [:]
            for e in t.events { XCTAssertEqual(ours(hooks, e), 1, "\(t.provider) \(e)") }
        }
        let root = try json(claude)
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual(((root["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 2, "theirs and ours")
        let dir = claude.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("liquid-notch-backup") }.sorted()
        XCTAssertEqual(backups.count, 2)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(backups[0]), encoding: .utf8), theirs)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: HookInstaller.scriptURL(home).path))

        try HookInstaller.uninstall(home)
        XCTAssertFalse(HookInstaller.installed(home))
        XCTAssertEqual(try json(claude) as NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(theirs.utf8)) as? NSDictionary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HookInstaller.scriptURL(home).path))
    }

    // A file that isn't JSON is left as it is, and neither app gets the hook.
    func testTheInstallerLeavesABrokenFileAlone() throws {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json".write(to: codex, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.install(home))
        XCTAssertEqual(try String(contentsOf: codex, encoding: .utf8), "{ not json")
        XCTAssertFalse(HookInstaller.installed(home))
        let claude = try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
        XCTAssertFalse(claude.contains("agent-hook.sh"), "both or neither")
    }

    private struct Run { let status: Int32; let out: String; let seconds: Double }

    /// Runs the installed script as Claude Code would: input on stdin, the event and provider as arguments. Spins
    /// the main run loop meanwhile, where the socket answers.
    private func run(_ home: URL, _ event: String, _ input: String) throws -> Run {
        let p = Process()
        p.executableURL = HookInstaller.scriptURL(home)
        p.arguments = [event, "claude"]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "__CFBundleIdentifier": "com.example.host"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        let start = Date()
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        while p.isRunning { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Run(status: p.terminationStatus, out: out, seconds: Date().timeIntervalSince(start))
    }

    // The script: an event is sent and returns at once; an approval prints the card's answer, or nothing; with no
    // notch listening it exits 0 at once and prints nothing (fail-open).
    func testTheScriptAgainstTheSocket() throws {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try HookInstaller.install(home)
        let socket = AgentSocket(path: home.appendingPathComponent("Library/Application Support/Liquid Notch/agents.sock").path)
        var lines: [AgentSocket.Line] = []
        var answer: String? = AgentHook.decision(allow: true)
        socket.onLine = { line, reply in
            lines.append(line)
            reply?(answer)
        }
        socket.start()

        let tool = #"{"session_id":"s1","cwd":"/x/liquid-notch","tool_name":"Bash","tool_input":{"command":"swift test"}}"#
        let sent = try run(home, "PreToolUse", tool)
        XCTAssertEqual(sent.status, 0)
        XCTAssertEqual(sent.out, "")
        XCTAssertLessThan(sent.seconds, 1, "never waits on the notch (the script takes ~20 ms; a cold spawn more)")
        let until = Date(timeIntervalSinceNow: 3)
        while lines.isEmpty && Date() < until { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        XCTAssertEqual(lines.first?.event, "PreToolUse")
        XCTAssertEqual(lines.first?.host, "com.example.host")
        XCTAssertEqual(lines.first.flatMap(AgentHook.init)?.detail, "swift test")

        let allowed = try run(home, "PermissionRequest", tool)
        XCTAssertEqual(allowed.out.trimmingCharacters(in: .newlines), AgentHook.decision(allow: true))
        answer = nil
        let unanswered = try run(home, "PermissionRequest", tool)
        XCTAssertEqual(unanswered.status, 0)
        XCTAssertEqual(unanswered.out, "")

        socket.stop()
        let alone = try run(home, "PermissionRequest", tool)
        XCTAssertEqual(alone.status, 0)
        XCTAssertEqual(alone.out, "")
        XCTAssertLessThan(alone.seconds, 1)
    }

    private func line(_ event: String, tool: String = "Bash") -> AgentSocket.Line {
        AgentSocket.Line(provider: "claude", event: event, host: "com.anthropic.claudefordesktop",
                         raw: Data(#"{"session_id":"s","cwd":"/x/app","tool_name":"\#(tool)","tool_input":{"command":"swift test"}}"#.utf8))
    }

    // The director holds an approval for the card for 24 s; its app in front, or a question, is answered at once with
    // nothing; a newer approval isn't cut short by an older one's timer; answered in its app, the held hook is let go.
    func testApprovalsWaitForTheCard() {
        let d = IslandDirector()
        let s = ManualScheduler()
        d.schedule = s.schedule
        d.frontmostApp = { "com.apple.finder" }
        var replies: [String?] = []
        let keep: (String?) -> Void = { replies.append($0) }

        d.agentHook(line("PermissionRequest"), reply: keep)
        XCTAssertTrue(d.answerable.contains("s"))
        XCTAssertEqual(d.island.arrangement.ears, .agents(.claude))
        d.answerAgent("s", allow: true)
        XCTAssertEqual(replies, [AgentHook.decision(allow: true)])
        XCTAssertFalse(d.answerable.contains("s"))

        d.agentHook(line("PermissionRequest"), reply: keep)
        s.advance(25)
        XCTAssertEqual(replies.count, 2)
        XCTAssertNil(replies[1] ?? nil)
        XCTAssertFalse(d.answerable.contains("s"), "past the hook's wait it's answered in its app")

        // Looking at that very session in its app: it asks you there (11-07: per session, not per app).
        d.frontmostApp = { "com.anthropic.claudefordesktop" }
        d.setContext(DesktopContext(frontmostApp: "com.anthropic.claudefordesktop", viewedSession: "s"))
        d.agentHook(line("PermissionRequest"), reply: keep)
        XCTAssertEqual(replies.count, 3)
        d.setContext(DesktopContext())
        d.frontmostApp = { "com.apple.finder" }
        d.agentHook(line("PermissionRequest", tool: "AskUserQuestion"), reply: keep)
        XCTAssertEqual(replies.count, 4)

        d.agentHook(line("PermissionRequest"), reply: keep)
        s.advance(20)
        d.agentHook(line("PermissionRequest"), reply: keep)
        XCTAssertEqual(replies.count, 5, "the older one is let go")
        s.advance(10)
        XCTAssertTrue(d.answerable.contains("s"), "the older timer doesn't end the newer approval")
        d.agentHook(line("PostToolUse"), reply: nil)
        XCTAssertEqual(replies.count, 6)
        XCTAssertFalse(d.answerable.contains("s"))
    }
}
