import Foundation

/// Claude and Codex sessions, as the notch sees them through their hooks
/// (`docs/superpowers/specs/2026-11-06-agents-design.md`, phase 2: the balls and approvals).
public enum AgentProvider: String, CaseIterable, Sendable {
    case claude, codex
    /// The notch's own conversation (quick ask, 11-07): its own ball, apart from the sessions it watches (owner: "make it
    /// stay open when you started an ask chat different from the working session, cause it is different").
    case ask

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .ask: "Ask"
        }
    }

    /// The ones that answer a quick ask (Ask itself runs on one of them).
    public static let backends: [AgentProvider] = [.claude, .codex]
}

public enum AgentState: Sendable, Equatable {
    /// Running a turn.
    case working
    /// Waiting on you: a permission or a question.
    case needs
    /// Finished a turn you haven't looked at.
    case done
    /// Read and waiting for you (quiet: no ball).
    case ready
    /// Stopped by an error or a usage limit.
    case error
}

/// What a session waits on you for.
public enum AgentNeed: Sendable, Equatable {
    /// A tool wants permission: the tool and what it runs (a command, a file).
    case permission(tool: String, detail: String)
    /// A question with its options (answered in the session's app for now).
    case question(text: String, options: [String])

    /// The tool the session waits on: only that tool finishing answers it (another may finish meanwhile).
    var tool: String {
        switch self {
        case .permission(let tool, _): tool
        case .question: "AskUserQuestion"
        }
    }
}

public struct AgentSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var provider: AgentProvider
    /// The working folder's name.
    public var project: String
    /// The bundle ID of the app it runs in (Claude's desktop app, Codex, a terminal), empty when unknown.
    public var host: String
    /// Its transcript (JSONL), from the hook, empty when unknown.
    public var transcript = ""
    public var state: AgentState
    /// The tool it's running, while it works.
    public var step: String
    public var need: AgentNeed?
    /// When it last changed (sessions order by it within a state).
    public var serial: Int

    public init(id: String, provider: AgentProvider, project: String, host: String = "", state: AgentState,
                step: String = "", need: AgentNeed? = nil, serial: Int = 0) {
        self.id = id
        self.provider = provider
        self.project = project
        self.host = host
        self.state = state
        self.step = step
        self.need = need
        self.serial = serial
    }
}

/// One hook call, decoded.
public struct AgentHook: Sendable, Equatable {
    public var provider: AgentProvider
    public var event: String
    public var sessionID: String
    public var cwd: String
    /// The app the session runs in (bundle ID), empty when unknown.
    public var host: String
    /// `transcript_path`: Claude Code's session JSONL, Codex's rollout.
    public var transcript = ""
    public var tool: String
    /// A short form of the tool's input: the command, the file, the question.
    public var detail: String
    public var options: [String]
    /// Claude Code only: a Notification's `notification_type`, a StopFailure's `error` (`rate_limit`…).
    public var kind: String

    public init(provider: AgentProvider, event: String, sessionID: String, cwd: String = "", host: String = "",
                tool: String = "", detail: String = "", options: [String] = [], kind: String = "") {
        self.provider = provider
        self.event = event
        self.sessionID = sessionID
        self.cwd = cwd
        self.host = host
        self.tool = tool
        self.detail = detail
        self.options = options
        self.kind = kind
    }
}

/// The sessions and what the island makes of them.
public struct Agents: Sendable, Equatable {
    public private(set) var sessions: [AgentSession] = []
    /// Hidden from the island's menu, per provider, until its sessions end (one that needs you shows anyway).
    public var hidden: Set<AgentProvider> = []
    /// The session you're looking at in its app: kept, but left out of what the island shows (`sessions(_:)`, `urgent`).
    public var viewing: String?
    private var nextSerial = 1

    public init() {}

    /// Applies one hook call. Returns true when the session now waits on you (the island jolts once).
    @discardableResult
    public mutating func apply(_ h: AgentHook) -> Bool {
        if h.event == "SessionEnd" {
            sessions.removeAll { $0.id == h.sessionID }
            for p in AgentProvider.allCases where !sessions.contains(where: { $0.provider == p }) { hidden.remove(p) }
            return false
        }
        var s = sessions.first { $0.id == h.sessionID }
            ?? AgentSession(id: h.sessionID, provider: h.provider, project: Self.project(h.cwd), state: .ready)
        if !h.cwd.isEmpty { s.project = Self.project(h.cwd) }
        if !h.host.isEmpty { s.host = h.host }
        if !h.transcript.isEmpty { s.transcript = h.transcript }
        let before = s.state
        switch h.event {
        case "UserPromptSubmit":
            s.state = .working; s.need = nil; s.step = ""
        case "PreToolUse", "PermissionRequest":
            if h.tool == "AskUserQuestion" {
                s.state = .needs; s.need = .question(text: h.detail, options: h.options)
            } else if h.event == "PermissionRequest" {
                s.state = .needs; s.need = .permission(tool: h.tool, detail: h.detail)
            } else {
                s.state = .working; s.need = nil; s.step = h.tool
            }
        case "PostToolUse":
            // Another tool finishing (they run side by side) doesn't answer the one waiting on you.
            if let need = s.need, need.tool != h.tool { break }
            s.state = .working; s.need = nil
        case "StopFailure":
            s.state = .error; s.need = nil
            s.step = h.kind == "rate_limit" || h.kind == "billing_error" ? "Usage limit" : "Stopped by an error"
        case "Notification":
            // Claude Code waits out a usage limit in the session and carries on by itself.
            switch h.kind {
            case "quota_auto_resume_fired": s.state = .working; s.step = ""
            case "quota_auto_resume_stale", "quota_auto_resume_disabled": s.state = .error; s.step = "Usage limit"
            default: break   // waiting for input, a permission: those arrive through their own events
            }
        case "Stop":
            if s.state != .error { s.state = .done; s.need = nil; s.step = "" }
        default:
            break   // SessionStart and anything new: the session is known, nothing changes
        }
        s.serial = nextSerial
        nextSerial += 1
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        return s.state == .needs && before != .needs
    }

    /// The session was answered from the notch (Allow, Deny): back to work.
    public mutating func answered(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].state = .working
        sessions[i].need = nil
    }

    /// Its card was opened: a finished session is read.
    public mutating func read(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].state == .done else { return }
        sessions[i].state = .ready
    }

    public mutating func setHidden(_ p: AgentProvider, _ on: Bool) {
        if on { hidden.insert(p) } else { hidden.remove(p) }
    }

    /// Most urgent first: needs you, error, done, working, ready; then the newest.
    public func urgent(_ p: AgentProvider? = nil) -> AgentSession? {
        sessions.filter { (p == nil || $0.provider == p) && $0.id != viewing }.min { a, b in
            (Self.rank(a.state), -a.serial) < (Self.rank(b.state), -b.serial)
        }
    }

    public func sessions(_ p: AgentProvider) -> [AgentSession] { sessions.filter { $0.provider == p && $0.id != viewing } }

    /// Something to see or do: anything but a read session waiting for you.
    public func active(_ p: AgentProvider) -> Bool {
        // The Ask conversation keeps its ball while it lives, read or not: it's where you type.
        p == .ask ? !sessions(p).isEmpty : sessions(p).contains { $0.state != .ready }
    }

    public func needsYou(_ p: AgentProvider) -> Bool { sessions(p).contains { $0.state == .needs } }

    /// Off the island for now: hidden, unless one of its sessions needs you.
    public func isHidden(_ p: AgentProvider) -> Bool { hidden.contains(p) && !needsYou(p) }

    private static func rank(_ s: AgentState) -> Int {
        switch s { case .needs: 0; case .error: 1; case .done: 2; case .working: 3; case .ready: 4 }
    }

    /// The app a provider's sessions usually run in (its question waits in the ball while it's in front).
    public static func app(_ p: AgentProvider) -> String {
        switch p {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        case .ask: ""   // the notch itself
        }
    }

    /// The app a session runs in: the one its hook named, else its provider's usual app.
    public static func app(of s: AgentSession) -> String { s.host.isEmpty ? app(s.provider) : s.host }

    static func project(_ cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Session" : name
    }
}
