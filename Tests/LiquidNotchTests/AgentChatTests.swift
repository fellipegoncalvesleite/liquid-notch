import AppKit
import IslandCore
import XCTest
@testable import LiquidNotch

/// The agents' chat (11-06): transcripts read into the card with tool runs folded, where each session lives and how it
/// opens, the ball's own hover, and replies. Everything on disk here is a temporary folder.
@MainActor
final class AgentChatTests: XCTestCase {
    private func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lnchat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func lines(_ objects: [[String: Any]]) -> [Substring] {
        objects.map { Substring(String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!) }
    }

    // Claude Code: typed turns, the agent's text, tool runs folded between them; reminders, meta turns, tool results,
    // thinking and sidechains left out.
    func testClaudeTranscript() {
        let items = AgentTranscript.parseClaude(lines([
            ["type": "user", "message": ["role": "user", "content": "<system-reminder>ignore</system-reminder>Port the peek"]],
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "a message from another session"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "hm"],
                                                                                ["type": "text", "text": "On it."]]]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "name": "Bash", "input": ["command": "swift build\necho"]]]]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "name": "Edit", "input": ["file_path": "/a/Island.swift"]]]]],
            ["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "content": [["type": "text", "text": "a subagent"]]]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Done: the peek **works**."]]]],
            ["type": "user", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]],
        ]))
        XCTAssertEqual(items, [.you("Port the peek"), .agent("On it."),
                               .tools("Ran 1 command · edited 1 file", ["$ swift build", "Edited Island.swift"]),
                               .agent("Done: the peek **works**.")])
        XCTAssertEqual(AgentTranscript.summary([.init(.command, "$ swift test")]), "Ran swift test")
    }

    // Codex: finished items (newer rollouts) or user/agent events (older ones).
    func testCodexTranscript() {
        func done(_ item: [String: Any]) -> [String: Any] { ["type": "event_msg", "payload": ["type": "item_completed", "item": item]] }
        let items = AgentTranscript.parseCodex(lines([
            done(["type": "UserMessage", "content": [["type": "text", "text": "# Files mentioned by the user:\n## a.png\n## My request for Codex:\nFix the build"]]]),
            done(["type": "Reasoning"]),
            done(["type": "CommandExecution", "command": ["/bin/zsh", "-lc", "make"]]),
            done(["type": "McpToolCall", "tool": "js", "arguments": ["title": "Find your Chrome session"]]),
            done(["type": "AgentMessage", "content": [["type": "Text", "text": "Fixed."]]]),
        ]))
        XCTAssertEqual(items, [.you("Fix the build"), .tools("Ran 1 command · used 1 tool", ["$ make", "Find your Chrome session"]), .agent("Fixed.")])
        let old = AgentTranscript.parseCodex(lines([
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>…"]]]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Hi"]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "shell"]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "Hello"]],
        ]))
        XCTAssertEqual(old, [.you("Hi"), .tools("Ran a command", ["Ran a command"]), .agent("Hello")])
    }

    // Only the tail is read; a line cut at its start is dropped; a tail of nothing but tool output reads further back.
    func testReadsTheTail() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        var text = String(repeating: "x", count: 100) + "\n"
        for i in 0..<5 { text += #"{"type":"user","message":{"role":"user","content":"turn \#(i)"}}"# + "\n" }
        text += #"{"type":"progress","blob":""# + String(repeating: "b", count: 2_000_000) + "\"}\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentTranscript.read(url, provider: .claude, limit: 2), [.you("turn 3"), .you("turn 4")])
    }

    // The Claude app's record by Claude Code session ID (not by an ID that only appears in another field), Codex's
    // latest thread name, its rollout, and each app's link.
    func testWhereSessionsLive() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("claude/acct/org")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        func record(_ local: String, _ cli: String, _ extra: [String: Any] = [:]) throws {
            var d: [String: Any] = ["sessionId": local, "cliSessionId": cli, "title": "Session \(local)"]
            d.merge(extra) { a, _ in a }
            try JSONSerialization.data(withJSONObject: d).write(to: sessions.appendingPathComponent("\(local).json"))
        }
        try record("local_a", "cli-1")
        try record("local_b", "cli-2", ["lastAssistantCliSessionId": "cli-1"])
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codex.appendingPathComponent("sessions/2026/11/06"), withIntermediateDirectories: true)
        try """
        {"id":"th-1","thread_name":"Old name"}
        {"id":"th-2","thread_name":"Other"}
        {"id":"th-1","thread_name":"Fix the build"}
        """.write(to: codex.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let rollout = codex.appendingPathComponent("sessions/2026/11/06/rollout-2026-11-06T10-00-00-th-1.jsonl")
        try "".write(to: rollout, atomically: true, encoding: .utf8)
        let dir = AgentDirectory(claudeSessions: root.appendingPathComponent("claude"), codexHome: codex)

        XCTAssertEqual(dir.claudeRecord(cliID: "cli-1"), .init(localID: "local_a", title: "Session local_a"))
        XCTAssertNil(dir.claudeRecord(cliID: "cli-9"))
        XCTAssertEqual(dir.codexName(id: "th-1"), "Fix the build")
        XCTAssertEqual(dir.codexTranscript(id: "th-1")?.lastPathComponent, rollout.lastPathComponent)

        let inApp = AgentSession(id: "cli-1", provider: .claude, project: "p", host: Agents.app(.claude), state: .working)
        XCTAssertEqual(AgentDirectory.link(inApp, claude: dir.claudeRecord(cliID: "cli-1"))?.absoluteString,
                       "claude://code/continue?session=local_a")
        let inTerminal = AgentSession(id: "cli-1", provider: .claude, project: "p", host: "com.apple.Terminal", state: .working)
        XCTAssertNil(AgentDirectory.link(inTerminal, claude: nil))
        let thread = AgentSession(id: "th-1", provider: .codex, project: "p", state: .working)
        XCTAssertEqual(AgentDirectory.link(thread, claude: nil)?.absoluteString, "codex://threads/th-1")
    }

    private func line(_ provider: String, _ event: String, _ id: String, _ host: String, _ extra: String = "") -> AgentSocket.Line {
        AgentSocket.Line(provider: provider, event: event, host: host,
                         raw: Data(#"{"session_id":"\#(id)","cwd":"/x/liquid-notch"\#(extra)}"#.utf8))
    }

    private func waitUntil(_ ok: () -> Bool) async {
        for _ in 0..<200 where !ok() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // A ball's own hover: it peeks (the ears stay as they are: the song doesn't preview); the ears' hover ends it; a
    // press on the peek opens that ball's card; leaving lets it go after the linger.
    func testABallPeeksOnItsOwn() async {
        let d = IslandDirector()
        let s = ManualScheduler()
        d.schedule = s.schedule
        d.startMusic()
        d.agentHook(line("claude", "UserPromptSubmit", "c1", Agents.app(.claude)), reply: nil)
        XCTAssertEqual(d.island.arrangement.ears, .media)
        XCTAssertEqual(d.island.balls(.duo)[0], .agents(.claude))

        d.pointerMoved(hit: .bubble(0), corridor: false, buttonDown: false)
        XCTAssertEqual(d.island.peekBall, .agents(.claude))
        XCTAssertEqual(d.mode, .duo, "the ears don't open")
        XCTAssertEqual(d.groups.peekPlace, 0)
        XCTAssertFalse(d.groups.peek)
        d.pointerMoved(hit: .card, corridor: false, buttonDown: false)
        XCTAssertEqual(d.island.peekBall, .agents(.claude), "on the peek itself")
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        XCTAssertNil(d.island.peekBall)
        XCTAssertEqual(d.mode, .peek, "the ears' own hover")

        d.pointerMoved(hit: .bubble(0), corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .duo)
        d.pointerDown(at: .zero, hit: .card)
        XCTAssertEqual(d.island.cardOwner, .agents(.claude))
        XCTAssertNil(d.island.peekBall)
        d.clickOutside()

        d.pointerMoved(hit: .bubble(0), corridor: false, buttonDown: false)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        XCTAssertNotNil(d.island.peekBall, "it lingers")
        s.advance(2)
        XCTAssertNil(d.island.peekBall)
    }

    // Claude in the ears previews on hover, like a song (owner, 11-06: "when claude is on the top bar, hovering should
    // still do something"): the ears grow their lip with the session's title and the last line it wrote, read on hover;
    // leaving lingers, then lets it go; a press opens the chat.
    func testTheEarsPreviewTheirSession() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("c1.jsonl")
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Ported the ears' preview."}]}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let d = IslandDirector()
        let s = ManualScheduler()
        d.schedule = s.schedule
        d.agentDirectory = AgentDirectory(claudeSessions: root.appendingPathComponent("claude"), codexHome: root)
        d.agentHook(line("claude", "UserPromptSubmit", "c1", Agents.app(.claude), #","transcript_path":"\#(transcript.path)""#), reply: nil)
        XCTAssertEqual(d.island.arrangement.ears, .agents(.claude))
        XCTAssertEqual(d.mode, .compact)

        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .peek)
        XCTAssertEqual(d.groups.agentsPeek, .claude)
        XCTAssertFalse(d.groups.peek)
        await waitUntil { d.agentChats["c1"] != nil }
        XCTAssertEqual(d.peekText(.agents(.claude)).line, "Working · Ported the ears' preview.")

        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .peek, "it lingers")
        s.advance(2)
        XCTAssertEqual(d.mode, .compact)

        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        d.pointerDown(at: .zero, hit: .ears)
        XCTAssertEqual(d.mode, .card)
        XCTAssertEqual(d.island.cardOwner, .agents(.claude))
        XCTAssertNil(d.groups.agentsPeek)
    }

    // Hovering a session that needs you shows only its question, at once (owner, 11-06: "i go with instinct to hover it,
    // and it lags me when it doesnt open"), in the ears or in its ball: Allow answers from there and it closes; a press
    // grows it into the chat; leaving lingers, then closes.
    func testHoverShowsTheQuestion() async {
        let d = IslandDirector()
        let s = ManualScheduler()
        d.schedule = s.schedule
        d.frontmostApp = { "" }
        var answers: [String?] = []
        let ask = #","tool_name":"Bash","tool_input":{"command":"swift test"}"#
        d.agentHook(line("claude", "UserPromptSubmit", "c1", Agents.app(.claude)), reply: nil)
        d.agentHook(line("claude", "PermissionRequest", "c1", Agents.app(.claude), ask), reply: { answers.append($0) })
        XCTAssertEqual(d.island.arrangement.ears, .agents(.claude))

        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .card)
        XCTAssertTrue(d.groups.agentsQuestion)
        XCTAssertTrue(d.answerable.contains("c1"))
        d.answerAgent("c1", allow: true)
        XCTAssertEqual(answers.count, 1)
        XCTAssertNotEqual(d.mode, .card, "answered: it closes")
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .peek, "back at work: the hover is the preview again")
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        s.advance(2)

        // In its ball (a recording holds the ears): the same, and a press grows it into the chat.
        d.show(.recording, opened: false)
        d.agentHook(line("claude", "PermissionRequest", "c1", Agents.app(.claude), ask), reply: { answers.append($0) })
        XCTAssertEqual(d.island.arrangement.ears, .activity)
        guard let place = d.island.balls(d.mode).firstIndex(of: .agents(.claude)) else { return XCTFail("no ball") }
        d.pointerMoved(hit: .bubble(place), corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .card)
        XCTAssertTrue(d.groups.agentsQuestion)
        XCTAssertNil(d.island.peekBall)
        d.pointerMoved(hit: .card, corridor: false, buttonDown: false)
        XCTAssertTrue(d.groups.agentsQuestion, "onto the card itself")
        d.pointerDown(at: .zero, hit: .card)
        d.pointerUp(at: .zero, hit: .card, corridor: false)
        XCTAssertEqual(d.mode, .card)
        XCTAssertFalse(d.groups.agentsQuestion, "a press: the chat")
        XCTAssertEqual(d.island.cardOwner, .agents(.claude))
        d.clickOutside()

        d.pointerMoved(hit: .bubble(place), corridor: false, buttonDown: false)
        XCTAssertTrue(d.groups.agentsQuestion)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        XCTAssertEqual(d.mode, .card, "it lingers")
        s.advance(2)
        XCTAssertNotEqual(d.mode, .card)
    }

    // The ears' preview grows from their own width: Claude's 96 pt ears never shrink while the lip grows (sim `AG.ear`).
    func testTheEarsPreviewKeepsTheirWidth() {
        let tuning = Tuning()
        var t = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tuning)
        t.context.activityHoldsEars = true
        t.context.activityEar = 96
        let compact = t.resting(.compact), peek = t.resting(.peek)
        XCTAssertEqual(peek.mainHalfWidth, 104 + 96 + tuning.peekExtra, accuracy: 0.01)
        XCTAssertEqual(peek.mainHeight, tuning.peekHeight, accuracy: 0.01)
        XCTAssertGreaterThan(peek.mainHalfWidth, compact.mainHalfWidth)
    }

    // The peek and the card read the transcript; the peek says who (the Claude app's title) and the last line written.
    func testThePeekReadsTheChat() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("c1.jsonl")
        try [#"{"type":"user","message":{"role":"user","content":"Port the peek"}}"#,
             #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on it.\n\nThe ball peeks now."}]}}"#]
            .joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let claude = root.appendingPathComponent("claude/a/o")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_z", "cliSessionId": "c1", "title": "Liquid Notch: peek"])
            .write(to: claude.appendingPathComponent("local_z.json"))
        let d = IslandDirector()
        d.agentDirectory = AgentDirectory(claudeSessions: root.appendingPathComponent("claude"), codexHome: root)
        d.startMusic()                                   // the song holds the ears: the session waits in a ball
        d.agentHook(line("claude", "UserPromptSubmit", "c1", Agents.app(.claude), #","transcript_path":"\#(transcript.path)""#), reply: nil)
        d.pointerMoved(hit: .bubble(0), corridor: false, buttonDown: false)
        await waitUntil { d.agentChats["c1"] != nil && d.agentTitles["c1"] != nil }
        XCTAssertEqual(d.agentChats["c1"], [.you("Port the peek"), .agent("Working on it.\n\nThe ball peeks now.")])
        let (title, line) = d.peekText(.agents(.claude))
        XCTAssertEqual(title, "Liquid Notch: peek")
        XCTAssertEqual(line, "Working · The ball peeks now.")

        var opened: [URL] = []
        d.openURL = { opened.append($0) }
        d.openAgentApp(.claude)
        XCTAssertEqual(opened.map(\.absoluteString), ["claude://code/continue?session=local_z"])
    }

    // Replies: Codex queues it on the thread; the Claude app gets it copied and its session opened to paste it; a
    // Codex reply it doesn't take falls back to the same.
    func testReplies() async {
        let d = IslandDirector()
        var queued: [(String, String)] = [], copied: [String] = [], opened: [URL] = []
        var accept = true
        d.codexQueue = { thread, text in await MainActor.run { queued.append((thread, text)); return accept } }
        d.copyText = { copied.append($0) }
        d.openURL = { opened.append($0) }
        d.agentHook(line("codex", "UserPromptSubmit", "th-1", Agents.app(.codex)), reply: nil)
        d.agentHook(line("claude", "UserPromptSubmit", "c1", "com.apple.Terminal"), reply: nil)
        let codex = d.island.agents.sessions(.codex)[0], claude = d.island.agents.sessions(.claude)[0]
        XCTAssertEqual(d.replyPlaceholder(codex), "Reply · sent to Codex")
        XCTAssertEqual(d.replyRoute(claude), .paste(app: "com.apple.Terminal"))

        d.replyAgent(codex, "  ship it  ")
        await waitUntil { d.agentNotes["th-1"] == "Queued for Codex" }
        XCTAssertEqual(queued.map(\.0), ["th-1"])
        XCTAssertEqual(queued.map(\.1), ["ship it"])
        XCTAssertEqual(d.agentChats["th-1"], [.you("ship it")])
        XCTAssertTrue(copied.isEmpty)

        accept = false
        d.replyAgent(codex, "again")
        await waitUntil { !copied.isEmpty }
        XCTAssertEqual(copied, ["again"])
        XCTAssertEqual(opened.last?.absoluteString, "codex://threads/th-1")
        XCTAssertTrue(d.agentNotes["th-1"]?.hasPrefix("Codex didn't take it") == true)

        d.replyAgent(claude, "yes")
        XCTAssertEqual(copied.last, "yes")
        XCTAssertTrue(d.agentNotes["c1"]?.contains("paste it in") == true)
    }

    // The peek grows out of its ball and shrinks back there: no bridge ever forms to the ears and the notch never moves
    // (owner, 11-06: hovering the ball pulled the notch down too).
    func testThePeekNeverTouchesTheNotch() {
        let tuning = Tuning()
        var t = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tuning)
        t.context.bubbleModes = [.duo]
        let rest = t.resting(.duo)
        let a = ShapeAnimator(initial: rest, configs: tuning.springs, dynamics: tuning.dynamics)
        a.floor = (104, 37.5)
        a.cardBridge = (tuning.cardNeckMax, tuning.cardBreakGap)
        a.snap(to: rest)
        var maxNeck = 0.0, mainH = Set<Double>()
        func run(_ seconds: Double) {
            for _ in 0..<Int(seconds * 240) {
                a.advance(1.0 / 240)
                maxNeck = max(maxNeck, a.frame.cardNeck)
                mainH.insert((a.current.mainHeight * 100).rounded())
            }
        }
        var p = t
        p.context.peekPlace = 0
        p.context.peekCard = Island.ballPeekCard
        a.snapChannels(ShapeTargets.cardChannels + [\.cardX], from: p.peekSeed(.duo))
        a.setFinal(p.resting(.duo))
        run(1)
        XCTAssertEqual(a.current.cardHeight, Island.ballPeekCard.height, accuracy: 0.5)
        var leave = t
        leave.context.peekLeave = SIMD2(a.current.cardX, a.current.cardTop)
        a.setFinal(leave.resting(.duo))
        run(1)
        XCTAssertLessThan(a.current.cardHalfWidth, 0.5, "gone")
        XCTAssertEqual(maxNeck, 0, "never bridged to the ears")
        XCTAssertEqual(mainH, [3750], "the notch never moved")
    }

    // The peek's shape: the ball swells, the card hangs under it leaning in, and stays on the panel; the ears don't move.
    func testThePeekShape() {
        var t = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: Tuning())
        t.context.bubbleModes = [.duo]
        let before = t.resting(.duo)
        t.context.peekPlace = 0
        t.context.peekCard = Island.ballPeekCard
        let after = t.resting(.duo)
        XCTAssertEqual(after.dropRadius, before.dropRadius + 3)
        XCTAssertEqual(after.mainHalfWidth, before.mainHalfWidth)
        XCTAssertEqual(after.cardHeight, Island.ballPeekCard.height)
        XCTAssertGreaterThan(after.cardTop, 37.5)
        XCTAssertGreaterThan(after.cardX, 0)
        XCTAssertLessThan(after.cardX - Island.ballPeekCard.halfWidth, after.dropX, "under its ball")
        XCTAssertGreaterThan(after.cardX + Island.ballPeekCard.halfWidth, after.dropX)
        XCTAssertLessThan(after.cardX + Island.ballPeekCard.halfWidth, 380, "on the panel")
    }
}
