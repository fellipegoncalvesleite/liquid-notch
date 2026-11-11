import XCTest
import IslandCore

/// Phase 2 of the agents (sim AG1, AG4, AG5): what hook calls make of the sessions.
final class AgentsTests: XCTestCase {
    private func hook(_ event: String, _ id: String = "s1", _ provider: AgentProvider = .claude, host: String = "",
                      tool: String = "", detail: String = "", options: [String] = [], kind: String = "") -> AgentHook {
        AgentHook(provider: provider, event: event, sessionID: id, cwd: "/Users/f/Developer/liquid-notch", host: host,
                  tool: tool, detail: detail, options: options, kind: kind)
    }

    func testATurnFromPromptToDone() {
        var a = Agents()
        a.apply(hook("SessionStart"))
        XCTAssertEqual(a.urgent()?.state, .ready)
        XCTAssertFalse(a.active(.claude))
        a.apply(hook("UserPromptSubmit"))
        a.apply(hook("PreToolUse", tool: "Edit"))
        XCTAssertEqual(a.urgent()?.state, .working)
        XCTAssertEqual(a.urgent()?.step, "Edit")
        XCTAssertEqual(a.urgent()?.project, "liquid-notch")
        XCTAssertTrue(a.apply(hook("PermissionRequest", tool: "Bash", detail: "swift test")))
        XCTAssertEqual(a.urgent()?.need, .permission(tool: "Bash", detail: "swift test"))
        XCTAssertTrue(a.needsYou(.claude))
        a.answered("s1")
        XCTAssertEqual(a.urgent()?.state, .working)
        a.apply(hook("Stop"))
        XCTAssertEqual(a.urgent()?.state, .done)
        a.read("s1")
        XCTAssertEqual(a.urgent()?.state, .ready)
        XCTAssertFalse(a.active(.claude))
        a.apply(hook("SessionEnd"))
        XCTAssertTrue(a.sessions.isEmpty)
    }

    func testAQuestionAndALimit() {
        var a = Agents()
        a.apply(hook("PreToolUse", "q", .claude, tool: "AskUserQuestion", detail: "Which one?", options: ["A", "B"]))
        XCTAssertEqual(a.urgent()?.need, .question(text: "Which one?", options: ["A", "B"]))
        // Claude Code may ask through PermissionRequest too: still a question, not Allow / Deny.
        a.apply(hook("PermissionRequest", "q2", .claude, tool: "AskUserQuestion", detail: "Ship it?", options: ["Yes"]))
        XCTAssertEqual(a.sessions.first { $0.id == "q2" }?.need, .question(text: "Ship it?", options: ["Yes"]))
        // A usage limit stops the turn (StopFailure); the session carries on by itself when it resets.
        a.apply(hook("UserPromptSubmit", "l"))
        a.apply(hook("StopFailure", "l", kind: "rate_limit"))
        XCTAssertEqual(a.sessions.first { $0.id == "l" }?.state, .error)
        XCTAssertEqual(a.sessions.first { $0.id == "l" }?.step, "Usage limit")
        a.apply(hook("Stop", "l"))
        XCTAssertEqual(a.sessions.first { $0.id == "l" }?.state, .error, "a stop doesn't clear the limit")
        a.apply(hook("Notification", "l", kind: "quota_auto_resume_fired"))
        XCTAssertEqual(a.sessions.first { $0.id == "l" }?.state, .working)
        a.apply(hook("Notification", "l", kind: "idle_prompt"))
        XCTAssertEqual(a.sessions.first { $0.id == "l" }?.state, .working, "other notifications change nothing")
    }

    // Tools run side by side: another one finishing doesn't answer the one waiting on you; that one finishing does.
    func testOnlyTheWaitingToolAnswersIt() {
        var a = Agents()
        a.apply(hook("PreToolUse", tool: "Read"))
        a.apply(hook("PreToolUse", tool: "Bash"))
        a.apply(hook("PermissionRequest", tool: "Bash", detail: "rm -rf .build"))
        a.apply(hook("PostToolUse", tool: "Read"))
        XCTAssertEqual(a.urgent()?.state, .needs)
        a.apply(hook("PostToolUse", tool: "Bash"))
        XCTAssertEqual(a.urgent()?.state, .working)
    }

    // The app a session runs in comes from its hook; without one, its provider's usual app.
    func testTheHostApp() {
        var a = Agents()
        a.apply(hook("SessionStart", "t", host: "com.apple.Terminal"))
        a.apply(hook("PreToolUse", "t", tool: "Edit"))
        XCTAssertEqual(a.sessions.first.map(Agents.app(of:)), "com.apple.Terminal")
        a.apply(hook("SessionStart", "x", .codex))
        XCTAssertEqual(a.sessions.last.map(Agents.app(of:)), Agents.app(.codex))
    }

    // On the island: a provider that needs you comes before the song, unless its app is in front; working ones after.
    func testAgentsInTheQueue() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.agent(hook("UserPromptSubmit", "c", host: "com.anthropic.claudefordesktop")))
        XCTAssertEqual(i.arrangement.ears, .media)
        XCTAssertEqual(i.arrangement.balls, [.agents(.claude)])
        i.apply(.agent(hook("PermissionRequest", "c", tool: "Bash", detail: "swift test")))
        XCTAssertEqual(i.arrangement.ears, .agents(.claude))
        XCTAssertEqual(i.arrangement.balls, [.media])
        i.apply(.context(DesktopContext(frontmostApp: "com.anthropic.claudefordesktop")))
        XCTAssertEqual(i.arrangement.ears, .agents(.claude), "in the app, on another session: it still comes forward")
        i.apply(.context(DesktopContext(frontmostApp: "com.anthropic.claudefordesktop", viewedSession: "c")))
        XCTAssertEqual(i.arrangement.ears, .media, "looking at that session: it asks you there")
        XCTAssertFalse(i.arrangement.all.contains(.agents(.claude)), "and it leaves the island (owner, 11-07)")
        i.apply(.context(DesktopContext()))
        i.apply(.agentAnswered("c"))
        XCTAssertEqual(i.arrangement.ears, .media)
        i.apply(.agent(hook("SessionEnd", "c")))
        XCTAssertTrue(i.arrangement.balls.isEmpty)
    }

    // Each provider on its own; the urgent one first; hidden until it needs you.
    func testProvidersAndHiding() {
        var a = Agents()
        a.apply(hook("UserPromptSubmit", "c1", .claude))
        a.apply(hook("UserPromptSubmit", "x1", .codex))
        XCTAssertEqual(a.sessions(.codex).count, 1)
        a.setHidden(.codex, true)
        XCTAssertTrue(a.isHidden(.codex))
        a.apply(hook("PermissionRequest", "x1", .codex, tool: "shell", detail: "make"))
        XCTAssertFalse(a.isHidden(.codex))
        XCTAssertEqual(a.urgent()?.id, "x1")
        a.answered("x1")
        XCTAssertTrue(a.isHidden(.codex))
        a.apply(hook("SessionEnd", "x1", .codex))
        XCTAssertFalse(a.hidden.contains(.codex), "hidden ends with its sessions")
    }

    // VIEW1: only the session you're looking at leaves; the provider's others keep its ball (owner, 11-07).
    func testOnlyTheViewedSessionLeaves() {
        var i = Island()
        i.apply(.agent(hook("UserPromptSubmit", "a", host: "com.anthropic.claudefordesktop")))
        i.apply(.agent(hook("UserPromptSubmit", "b", host: "com.anthropic.claudefordesktop")))
        i.apply(.context(DesktopContext(frontmostApp: "com.anthropic.claudefordesktop", viewedSession: "a")))
        XCTAssertEqual(i.agents.sessions(.claude).map(\.id), ["b"])
        XCTAssertTrue(i.arrangement.all.contains(.agents(.claude)), "b keeps the ball")
        XCTAssertEqual(i.agents.sessions.count, 2, "a is kept, only left out of what shows")
        i.apply(.context(DesktopContext(frontmostApp: "com.anthropic.claudefordesktop", viewedSession: "b")))
        XCTAssertEqual(i.agents.sessions(.claude).map(\.id), ["a"])
    }
}
