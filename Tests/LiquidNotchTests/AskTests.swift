import IslandCore
import XCTest
@testable import LiquidNotch

/// Quick ask (agents phase 3): the card (ASK1), a question becoming a session with its answer streaming (ASK2–ASK3),
/// follow-ups and the 10-minute stay (ASK4), the notch's own hooks ignored (ASK5), the parsers (ASK6), the barrel roll.
@MainActor
final class AskTests: XCTestCase {
    private func director(screen: Bool = false) -> (IslandDirector, ManualScheduler, [(String, AgentProvider, String, Data?)]) {
        let d = IslandDirector(), s = ManualScheduler()
        d.schedule = s.schedule
        d.frontmostApp = { "" }
        d.screenAllowed = { screen }
        d.captureScreen = { nil }
        var sent: [(String, AgentProvider, String, Data?)] = []
        d.askSend = { sent.append(($0, $1, $2, $3)) }
        sentBox = { sent }
        return (d, s, sent)
    }
    private var sentBox: () -> [(String, AgentProvider, String, Data?)] = { [] }

    // ASK1: the ask card opens on the empty notch at 420 × 148, asks the chosen provider, and closes like a card.
    func testASK1TheAskCard() {
        let (d, _, _) = director()
        d.openAsk()
        XCTAssertEqual(d.mode, .card)
        XCTAssertEqual(d.island.askOpen, .claude)
        XCTAssertEqual(d.groups.agentsAsk, .claude)
        XCTAssertEqual(d.island.cardSize(player: CardSize(width: 372, height: 168, radius: 40)), Island.askCard)
        XCTAssertFalse(d.askShotAllowed, "no permission: the chip is off, nothing prompts")
        d.setAskProvider(.codex)
        XCTAssertEqual(d.island.askOpen, .codex)
        d.closeAsk()
        XCTAssertNil(d.island.askOpen)
        XCTAssertEqual(d.mode, .idle)
    }

    // ASK2: Return makes a session (project Ask) and its chat card; the question goes to the provider, with the frame.
    func testASK2AQuestionBecomesASession() {
        let (d, _, _) = director()
        d.openAsk(.claude)
        d.submitAsk("What's this error?")
        let s = d.island.agents.sessions.first
        XCTAssertEqual(s?.project, "Ask")
        XCTAssertEqual(s?.state, .working)
        XCTAssertNil(d.island.askOpen)
        XCTAssertEqual(s?.provider, .ask, "the notch's own conversation, apart from the sessions it watches")
        XCTAssertEqual(d.groups.agentsCard, .ask, "the card grows into the chat")
        XCTAssertEqual(d.agentShown(.ask)?.id, s?.id)
        XCTAssertEqual(d.askBackend[s!.id], .claude)
        XCTAssertEqual(d.agentChats[s!.id], [.you("What's this error?")])
        XCTAssertEqual(sentBox().map(\.2), ["What's this error?"])
        XCTAssertEqual(d.replyRoute(s!), .ask)
        XCTAssertEqual(d.agentTitle(s!), "What's this error?")
    }

    // ASK3: deltas stream into one message; the end settles it (read at once while its chat shows); errors show in it.
    func testASK3TheAnswerStreams() {
        let (d, _, _) = director()
        d.openAsk(.claude)
        d.submitAsk("hi")
        let id = d.island.agents.sessions[0].id
        d.askEvent(id, .delta("Hello"))
        d.askEvent(id, .delta(" there"))
        XCTAssertEqual(d.agentChats[id]?.last, .agent("Hello there"))
        d.askEvent(id, .tool("WebSearch"))
        XCTAssertEqual(d.agentChats[id]?.last, .tools("Searched the web", []))
        d.askEvent(id, .done(error: nil))
        XCTAssertEqual(d.island.agents.sessions[0].state, .ready, "its chat was showing: read")
        XCTAssertTrue(d.island.arrangement.all.contains(.agents(.ask)), "read, it keeps its ball: that's where you type")
    }

    // ASK4: a follow-up goes to the same session; a read Ask session leaves 10 minutes later, a new turn keeps it.
    func testASK4FollowUpAndStay() {
        let (d, s, _) = director()
        d.openAsk(.codex)
        d.submitAsk("first")
        let session = d.island.agents.sessions[0]
        d.askEvent(session.id, .done(error: nil))
        d.replyAgent(d.island.agents.sessions[0], "and then?")
        XCTAssertEqual(sentBox().map(\.2), ["first", "and then?"])
        XCTAssertEqual(sentBox().last?.0, session.id)
        XCTAssertEqual(sentBox().last?.1, .codex, "answered by the conversation's own backend")
        XCTAssertEqual(d.island.agents.sessions[0].state, .working)
        s.advance(700)
        XCTAssertEqual(d.island.agents.sessions.count, 1, "working: it stays")
        d.askEvent(session.id, .done(error: nil))
        d.closeAsk()
        d.selectAgent(d.island.agents.sessions[0])
        if d.island.agents.sessions[0].state == .done { d.selectAgent(d.island.agents.sessions[0]) }
        s.advance(599)
        XCTAssertEqual(d.island.agents.sessions.count, 1)
        s.advance(2)
        XCTAssertTrue(d.island.agents.sessions.isEmpty, "10 minutes after it was read, it leaves")
    }

    // ASK5: Codex's hooks fire for the notch's own questions: lines from the Ask folder are ignored.
    func testASK5OwnHooksIgnored() {
        let (d, _, _) = director()
        let json = #"{"session_id":"t1","cwd":"\#(QuickAsk.workspace.path)"}"#
        d.agentHook(AgentSocket.Line(provider: "codex", event: "UserPromptSubmit", host: "", raw: Data(json.utf8)), reply: nil)
        XCTAssertTrue(d.island.agents.sessions.isEmpty)
    }

    // ASK6: the stream parsers.
    func testASK6Parsers() {
        let claude = QuickAskParsing.claude([
            #"{"type":"system","subtype":"init","session_id":"abc"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"WebSearch"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Found it"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false}"#,
        ])
        XCTAssertEqual(claude, [.delta("Hi"), .tool("WebSearch"), .delta("\n\nFound it"), .done(error: nil)])
        let codex = QuickAskParsing.codex([
            #"{"type":"thread.started","thread_id":"th1"}"#,
            #"{"type":"item.started","item":{"type":"web_search"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"One"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Two"}}"#,
            #"{"type":"turn.completed"}"#,
        ])
        XCTAssertEqual(codex.thread, "th1")
        XCTAssertEqual(codex.events, [.tool("WebSearch"), .delta("One"), .delta("\n\nTwo"), .done(error: nil)])
        XCTAssertEqual(QuickAskParsing.codex([#"{"type":"turn.failed","error":{"message":"Nope"}}"#]).events, [.done(error: "Nope")])
    }

    // ASK7: ask for a barrel roll and the ball does one.
    func testASK7BarrelRoll() {
        let (d, s, _) = director()
        d.openAsk()
        d.submitAsk("do a barrel roll")
        XCTAssertEqual(d.barrelRolls, 0)
        s.advance(0.9)
        XCTAssertEqual(d.barrelRolls, 1)
    }

    // AG2: Claude's question waits for your pick while its app is elsewhere; the pick answers through updatedInput.answers.
    func testAG2AnswerAQuestion() throws {
        let (d, _, _) = director()
        let input = #"{"questions":[{"question":"Port it now?","options":[{"label":"Now"},{"label":"Later"}]}]}"#
        let json = #"{"session_id":"q1","cwd":"/tmp/x","tool_name":"AskUserQuestion","tool_input":\#(input)}"#
        let line = AgentSocket.Line(provider: "claude", event: "PreToolUse", host: "", raw: Data(json.utf8))
        XCTAssertTrue(line.waits)
        var answer: String??
        d.agentHook(line, reply: { answer = .some($0) })
        XCTAssertTrue(d.answerable.contains("q1"))
        XCTAssertNil(answer, "held for your pick")
        d.answerQuestion("q1", "Later")
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((answer!!).utf8)) as? [String: Any])
        let hso = try XCTUnwrap(out["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hso["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hso["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(hso["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["answers"] as? [String: String])?["Port it now?"], "Later")
        XCTAssertNotNil(updated["questions"], "the tool's own input goes back with it")
        XCTAssertEqual(d.island.agents.sessions.first?.state, .working)
    }

    // AG2b: opening the session in its app while its question waits here lets the app ask it at once.
    func testAG2bGoingToTheAppReleasesIt() {
        let (d, _, _) = director()
        let json = #"{"session_id":"q2","cwd":"/tmp/x","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"A"}]}]}}"#
        var answered = false
        d.agentHook(AgentSocket.Line(provider: "claude", event: "PreToolUse", host: "", raw: Data(json.utf8)), reply: { _ in answered = true })
        XCTAssertFalse(answered)
        d.setContext(DesktopContext(frontmostApp: Agents.app(.claude)))
        XCTAssertFalse(answered, "in the app on another session: still answerable from the notch")
        d.setContext(DesktopContext(frontmostApp: Agents.app(.claude), viewedSession: "q2"))
        XCTAssertTrue(answered, "opening that session lets the app ask it")
        XCTAssertFalse(d.answerable.contains("q2"))
    }

    // IDLE1: sessions you've stopped using leave by themselves (owner, 11-07); one that needs you never does; a new
    // event re-arms the timer, and a gone session comes back with its next event.
    func testIDLE1IdleSessionsLeave() {
        let (d, s, _) = director()
        func hook(_ event: String, _ id: String, _ extra: String = "") {
            let json = #"{"session_id":"\#(id)","cwd":"/tmp/p"\#(extra)}"#
            d.agentHook(AgentSocket.Line(provider: "claude", event: event, host: "", raw: Data(json.utf8)), reply: nil)
        }
        hook("UserPromptSubmit", "a"); hook("Stop", "a")                  // done, unread: 30 minutes
        hook("UserPromptSubmit", "b")                                   // working: an hour of silence
        hook("UserPromptSubmit", "c"); hook("PreToolUse", "c", #","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[]}]}"#)
        s.advance(1700)
        XCTAssertEqual(Set(d.island.agents.sessions.map(\.id)), ["a", "b", "c"])
        hook("UserPromptSubmit", "a"); hook("Stop", "a")                  // used again: the clock restarts
        s.advance(200)
        XCTAssertTrue(d.island.agents.sessions.contains { $0.id == "a" })
        s.advance(1700)
        XCTAssertFalse(d.island.agents.sessions.contains { $0.id == "a" }, "30 minutes after its last event")
        s.advance(2000)
        XCTAssertFalse(d.island.agents.sessions.contains { $0.id == "b" }, "silent for an hour")
        XCTAssertTrue(d.island.agents.sessions.contains { $0.id == "c" }, "it needs you: it stays")
        hook("UserPromptSubmit", "a")
        XCTAssertTrue(d.island.agents.sessions.contains { $0.id == "a" }, "back with its next event")
        XCTAssertEqual(IslandDirector.idleLimit(.ready), 600)
    }

    // CLOSE1 (owner, 11-07: "put an x here so I can close some sessions"): the × on a chip drops that session; its later
    // events are ignored, until it needs you (an approval brings it back).
    func testCLOSE1ClosingASessionFromItsChip() throws {
        let (d, _, _) = director()
        func hook(_ event: String, _ id: String, _ extra: String = "") {
            let json = #"{"session_id":"\#(id)","cwd":"/tmp/p"\#(extra)}"#
            d.agentHook(AgentSocket.Line(provider: "claude", event: event, host: "", raw: Data(json.utf8)), reply: nil)
        }
        hook("UserPromptSubmit", "a"); hook("UserPromptSubmit", "b")
        let a = try XCTUnwrap(d.island.agents.sessions.first { $0.id == "a" })
        d.closeSession(a)
        XCTAssertEqual(d.island.agents.sessions.map(\.id), ["b"])
        hook("PreToolUse", "a", #","tool_name":"Bash""#); hook("Stop", "a")
        XCTAssertFalse(d.island.agents.sessions.contains { $0.id == "a" }, "no longer followed")
        hook("PermissionRequest", "a", #","tool_name":"Bash""#)
        XCTAssertEqual(d.island.agents.sessions.first { $0.id == "a" }?.state, .needs, "it needs you: back")
    }

    // ASK8: the Ask chat stays open while you use the screen (owner, 11-07); Esc / × close it; asking again opens the
    // conversation you have, the `+` a new one.
    func testASK8StaysOpenAndContinues() {
        let (d, s, _) = director()
        d.openAsk(); d.submitAsk("first")
        XCTAssertTrue(d.island.holdsOpen)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: false)
        s.advance(5)
        d.clickOutside()
        XCTAssertTrue(d.island.opened, "leaving and clicking elsewhere keep it open")
        d.closeAsk()
        XCTAssertFalse(d.island.opened)
        let focus = d.askFocusTick
        d.openAsk()
        XCTAssertEqual(d.groups.agentsCard, .ask, "asking again opens the conversation you have")
        XCTAssertNil(d.island.askOpen)
        XCTAssertGreaterThan(d.askFocusTick, focus, "with its field ready")
        d.openAsk(new: true)
        XCTAssertNotNil(d.island.askOpen, "the + starts a new one")
    }

    // ASK9: with Screen on, a fresh frame goes with every message, the first and each follow-up.
    func testASK9FreshScreenEachMessage() async {
        let (d, _, _) = director(screen: true)
        var captures = 0
        d.captureScreen = { captures += 1; return ScreenFrame(jpeg: Data([UInt8(captures)])) }
        d.openAsk(); d.submitAsk("what's on screen?")
        for _ in 0..<50 where sentBox().count < 1 { await Task.yield() }
        let id = d.island.agents.sessions[0].id
        d.askEvent(id, .done(error: nil))
        d.replyAgent(d.island.agents.sessions[0], "and now?")
        for _ in 0..<50 where sentBox().count < 2 { await Task.yield() }
        XCTAssertEqual(sentBox().map { $0.3 }, [Data([1]), Data([2])])
        XCTAssertEqual(d.agentChats[id]?.filter { if case .tools("Looked at your screen", _) = $0 { true } else { false } }.count, 1)
        d.toggleAskShot()
        d.replyAgent(d.island.agents.sessions[0], "private one")
        for _ in 0..<50 where sentBox().count < 3 { await Task.yield() }
        XCTAssertNil(sentBox().last?.3 ?? nil, "off: nothing of the screen goes")
    }

    // KEY1: ⌥Space alone opens Ask; with ⌘, ⌃ or ⇧ it's someone else's.
    func testKEY1AskChord() {
        XCTAssertTrue(MediaKeyTap.isAskChord([.maskAlternate]))
        XCTAssertFalse(MediaKeyTap.isAskChord([.maskAlternate, .maskCommand]))
        XCTAssertFalse(MediaKeyTap.isAskChord([.maskAlternate, .maskShift]))
        XCTAssertFalse(MediaKeyTap.isAskChord([]))
    }

    // ASK10: the shortcut toggles Ask; it opens into the last conversation only within 10 minutes of its last message.
    func testASK10ToggleAndContinueWindow() {
        let (d, _, _) = director()
        var now = Date(timeIntervalSinceReferenceDate: 5000)
        d.date = { now }
        d.toggleAsk()
        XCTAssertNotNil(d.island.askOpen, "nothing going: the ask card")
        d.toggleAsk()
        XCTAssertFalse(d.island.opened, "again: it closes")
        d.toggleAsk(); d.submitAsk("first")
        d.toggleAsk()
        XCTAssertFalse(d.island.opened, "the chat closes too")
        now += 300
        d.toggleAsk()
        XCTAssertEqual(d.groups.agentsCard, .ask, "5 minutes later: the same conversation")
        d.toggleAsk()
        now += 700
        d.toggleAsk()
        XCTAssertNotNil(d.island.askOpen, "15 minutes since its last message: a fresh question")
    }

    // INTENT1: passing over the island fast opens nothing; settling on it opens the preview.
    func testINTENT1PassingThrough() {
        let (d, _, _) = director()
        d.startMusic()
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false, settled: false)
        XCTAssertFalse(d.island.hovered, "just passing through")
        d.pointerMoved(hit: .ears, corridor: false, buttonDown: false, settled: true)
        XCTAssertTrue(d.island.hovered)
    }

    // VIEW2: the viewed Claude session is the record focused last; a record is read again only when it changes.
    func testVIEW2FocusedSessionReader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ln-view2-\(UUID().uuidString)/acct/org")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func record(_ name: String, _ cli: String, _ focused: Double) throws {
            let json = #"{"cliSessionId":"\#(cli)","lastFocusedAt":\#(focused),"title":"t"}"#
            try Data(json.utf8).write(to: root.appendingPathComponent("local_\(name).json"))
        }
        try record("a", "cli-a", 1000)
        try record("b", "cli-b", 2000)
        let dir = AgentDirectory(claudeSessions: root.deletingLastPathComponent().deletingLastPathComponent(), codexHome: root)
        let cache = FocusedSessionCache()
        XCTAssertEqual(dir.focusedClaudeSession(cache: cache), "cli-b")
        try record("a", "cli-a", 3000)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: root.appendingPathComponent("local_a.json").path)
        XCTAssertEqual(dir.focusedClaudeSession(cache: cache), "cli-a", "switching sessions in the app")
        // The window's title wins at once (the record's focus time lands ~3 s later).
        let json = #"{"cliSessionId":"cli-c","lastFocusedAt":10,"title":"Mac suite lid click behavior"}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("local_c.json"))
        XCTAssertEqual(dir.focusedClaudeSession(title: "Mac suite lid click behavior", cache: cache), "cli-c")
        XCTAssertEqual(ClaudeWindowTitle.session("Mac suite lid click behavior - Claude Code"), "Mac suite lid click behavior")
        XCTAssertNil(ClaudeWindowTitle.session("Claude"))
    }

    // VIEW3: watched (the Claude app in front), the folder is listed once; after that a read touches only the records
    // FSEvents names, so switching, a new session and a removed one still land, and nothing else is listed or stat'ed.
    func testVIEW3WatchedReadsOnlyChangedRecords() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ln-view3-\(UUID().uuidString)")
        let root = base.appendingPathComponent("acct/org")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func record(_ name: String, _ cli: String, _ focused: Double, _ title: String) throws {
            let json = #"{"cliSessionId":"\#(cli)","lastFocusedAt":\#(focused),"title":"\#(title)"}"#
            try Data(json.utf8).write(to: root.appendingPathComponent("local_\(name).json"), options: .atomic)
        }
        func soon(_ check: () -> Bool) -> Bool {
            for _ in 0..<150 { if check() { return true }; Thread.sleep(forTimeInterval: 0.02) }
            return false
        }
        try record("a", "cli-a", 1000, "Alpha")
        try record("b", "cli-b", 2000, "Beta")
        let dir = AgentDirectory(claudeSessions: base, codexHome: base)
        let cache = FocusedSessionCache()
        cache.watch(base)
        defer { cache.watch(nil) }
        XCTAssertEqual(dir.focusedClaudeSession(cache: cache), "cli-b")
        XCTAssertEqual(dir.focusedClaudeSession(title: "Alpha", cache: cache), "cli-a")
        XCTAssertEqual(cache.listings, 1, "listed once, then read from memory")
        try record("a", "cli-a", 3000, "Alpha")
        XCTAssertTrue(soon { dir.focusedClaudeSession(cache: cache) == "cli-a" }, "switching sessions in the app")
        try record("c", "cli-c", 10, "Gamma")
        XCTAssertTrue(soon { dir.focusedClaudeSession(title: "Gamma", cache: cache) == "cli-c" }, "a new session")
        try FileManager.default.removeItem(at: root.appendingPathComponent("local_a.json"))
        XCTAssertTrue(soon { dir.focusedClaudeSession(cache: cache) == "cli-b" }, "a removed session")
        XCTAssertEqual(cache.listings, 1)
        // Unwatched (the app not in front), every read lists the folder, as before.
        cache.watch(nil)
        XCTAssertEqual(dir.focusedClaudeSession(cache: cache), "cli-b")
        XCTAssertEqual(cache.listings, 2)
    }
}
