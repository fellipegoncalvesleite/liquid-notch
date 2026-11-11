import AppKit
import Foundation
import IslandCore
import os
@preconcurrency import ScreenCaptureKit

/// Quick ask (agents phase 3, docs/superpowers/specs/2026-11-06-quick-ask-native-design.md): questions the notch asks on
/// the owner's own plans (no API keys). Claude: one long-lived `claude -p` per session over stream-json, stopped after 15
/// minutes idle (Aide's `Brain`). ChatGPT: one `codex exec` per question, resuming its thread (Aide's `CodexBrain`).
@MainActor
final class QuickAsk {
    enum Event: Equatable {
        /// Text as it arrives (Claude streams deltas; Codex sends each message whole).
        case delta(String)
        /// A tool started (web search, a fetch).
        case tool(String)
        case done(error: String?)
    }

    /// The working folder: hooks from here are the notch's own questions (Codex's hooks fire for `codex exec`).
    nonisolated static var workspace: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Liquid Notch/Ask", isDirectory: true)
    }

    nonisolated static let systemPrompt = """
        You answer quick questions asked from the Mac's notch (Liquid Notch). When a screenshot of the screen comes with \
        the question, it was taken the moment the question was asked: use it. Be brief and direct: one to four short \
        sentences unless more is asked for, plain text, light Markdown at most. No preamble.
        """

    static var claudeExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var onEvent: ((String, Event) -> Void)?
    private var claude: [String: ClaudeProcess] = [:]
    private var codex: [String: CodexRun] = [:]

    /// Asks `text` in session `id` (a new one, or a follow-up), with the screen's frame when given.
    func ask(_ id: String, provider: AgentProvider, text: String, image: Data?) {
        try? FileManager.default.createDirectory(at: Self.workspace, withIntermediateDirectories: true)
        let emit: (Event) -> Void = { [weak self] e in self?.onEvent?(id, e) }
        switch provider {
        case .claude, .ask:
            let p = claude[id] ?? ClaudeProcess(emit: emit)
            claude[id] = p
            p.ask(text, image: image)
        case .codex:
            let c = codex[id] ?? CodexRun(emit: emit)
            codex[id] = c
            c.ask(text, image: image)
        }
    }

    /// The session left the island: its process goes too.
    func end(_ id: String) {
        claude.removeValue(forKey: id)?.stop()
        codex.removeValue(forKey: id)?.stop()
    }

    func stopAll() {
        for id in Array(claude.keys) + Array(codex.keys) { end(id) }
    }
}

// MARK: - Claude

@MainActor
private final class ClaudeProcess {
    private let emit: (QuickAsk.Event) -> Void
    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var idle: Timer?
    private var sawText = false
    private var needsBreak = false
    private var outstanding = 0
    private var generation = 0
    private var sessionID: String?
    nonisolated private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "ask")

    init(emit: @escaping (QuickAsk.Event) -> Void) { self.emit = emit }

    func ask(_ text: String, image: Data?) {
        if proc?.isRunning != true { start() }
        guard proc?.isRunning == true else { return }
        idle?.invalidate()
        outstanding += 1
        sawText = false
        var content: [[String: Any]] = []
        if let image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]])
        }
        content.append(["type": "text", "text": text])
        write(["type": "user", "message": ["role": "user", "content": content]])
    }

    func stop() {
        idle?.invalidate()
        try? stdin?.close()
        stdin = nil
        let p = proc
        proc = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
    }

    private func start() {
        guard let exe = QuickAsk.claudeExecutable else {
            emit(.done(error: "Can't find the claude command on this Mac (install Claude Code to ask Claude)."))
            return
        }
        let p = Process()
        p.executableURL = exe
        p.currentDirectoryURL = QuickAsk.workspace
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--model", "sonnet", "--setting-sources", "", "--strict-mcp-config",
                    "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch", "WebFetch",
                    "--system-prompt", QuickAsk.systemPrompt]
        if let sessionID { args += ["--resume", sessionID] }
        p.arguments = args
        p.environment = Self.environment
        let i = Pipe(), o = Pipe(), e = Pipe()
        generation += 1
        let gen = generation
        p.standardInput = i
        p.standardOutput = o
        p.standardError = e
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.generation == gen { self?.consume(d) } } }
        }
        e.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            Self.log.debug("claude stderr: \(String(decoding: d.prefix(400), as: UTF8.self), privacy: .public)")
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(proc, gen) } }
        }
        do {
            try p.run()
            proc = p
            stdin = i.fileHandleForWriting
        } catch {
            emit(.done(error: "Couldn't start claude: \(error.localizedDescription)"))
        }
    }

    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        return env
    }

    private func write(_ obj: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            for e in Self.parse(Data(line), sawText: &sawText, needsBreak: &needsBreak, session: &sessionID) { handle(e) }
        }
    }

    private func handle(_ e: QuickAsk.Event) {
        if case .done = e {
            outstanding = max(0, outstanding - 1)
            guard outstanding == 0 else { return }
            armIdle()
        }
        emit(e)
    }

    private func armIdle() {
        idle?.invalidate()
        let t = Timer(timeInterval: 15 * 60, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        RunLoop.main.add(t, forMode: .common)
        idle = t
    }

    private func exited(_ p: Process, _ gen: Int) {
        guard gen == generation else { return }
        proc = nil
        if outstanding > 0 {
            outstanding = 0
            emit(.done(error: "Claude stopped unexpectedly."))
        }
    }

    /// One stream-json line → events (tested): the session id, text deltas (a paragraph break between text blocks),
    /// tool starts, the result.
    nonisolated static func parse(_ line: Data, sawText: inout Bool, needsBreak: inout Bool, session: inout String?) -> [QuickAsk.Event] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String { session = sid }
        case "stream_event":
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return [] }
            guard let ev = obj["event"] as? [String: Any], let evType = ev["type"] as? String else { return [] }
            if evType == "content_block_start", let block = ev["content_block"] as? [String: Any] {
                if block["type"] as? String == "tool_use", let name = block["name"] as? String { return [.tool(name)] }
                if block["type"] as? String == "text", sawText { needsBreak = true }
            } else if evType == "content_block_delta", let delta = ev["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta", var text = delta["text"] as? String {
                if needsBreak { text = "\n\n" + text; needsBreak = false }
                sawText = true
                return [.delta(text)]
            }
        case "result":
            let isError = obj["is_error"] as? Bool ?? false, subtype = obj["subtype"] as? String ?? ""
            return [.done(error: isError || subtype.hasPrefix("error") ? (obj["result"] as? String ?? subtype) : nil)]
        default: break
        }
        return []
    }
}

// MARK: - Codex

@MainActor
private final class CodexRun {
    private let emit: (QuickAsk.Event) -> Void
    private var proc: Process?
    private var thread: String?
    private var buffer = Data()
    private var sent = false
    private var finished = true
    private var generation = 0

    init(emit: @escaping (QuickAsk.Event) -> Void) { self.emit = emit }

    func ask(_ text: String, image: Data?) {
        guard let exe = AgentReply.codex else {
            emit(.done(error: "Can't find Codex on this Mac (it comes with the ChatGPT app)."))
            return
        }
        if proc?.isRunning == true { proc?.terminate() }
        sent = false; finished = false; buffer.removeAll()
        generation += 1
        let gen = generation
        var args = ["exec"]
        if let thread { args += ["resume", thread] }
        args += ["--json", "--skip-git-repo-check", "-s", "read-only"]
        if let image {
            let url = QuickAsk.workspace.appendingPathComponent("screen-\(gen).jpg")
            try? image.write(to: url, options: .atomic)
            args += ["-i", url.path]
        }
        args.append("-")   // the prompt on stdin
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = QuickAsk.workspace
        p.environment = ClaudeProcess.environment
        let i = Pipe(), o = Pipe()
        p.standardInput = i
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.generation == gen { self?.consume(d) } } }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.generation == gen { self?.exited() } } }
        }
        do {
            try p.run()
            proc = p
            let preface = thread == nil ? QuickAsk.systemPrompt + "\n\n" : ""
            try i.fileHandleForWriting.write(contentsOf: Data((preface + text).utf8))
            try i.fileHandleForWriting.close()
        } catch {
            finish(error: "Couldn't start Codex: \(error.localizedDescription)")
        }
    }

    func stop() {
        generation += 1
        if proc?.isRunning == true { proc?.terminate() }
        proc = nil
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            for e in Self.parse(Data(line), sent: &sent, thread: &thread) {
                if case .done(let err) = e { finish(error: err) } else { emit(e) }
            }
        }
    }

    private func exited() {
        proc = nil
        if !finished { finish(error: "Codex stopped unexpectedly.") }
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        emit(.done(error: error))
    }

    /// One `codex exec --json` line → events (tested).
    nonisolated static func parse(_ line: Data, sent: inout Bool, thread: inout String?) -> [QuickAsk.Event] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { return [] }
        let item = obj["item"] as? [String: Any]
        switch type {
        case "thread.started": thread = obj["thread_id"] as? String
        case "item.started":
            switch item?["type"] as? String {
            case "web_search": return [.tool("WebSearch")]
            case "command_execution": return [.tool("Bash")]
            default: break
            }
        case "item.completed":
            if item?["type"] as? String == "agent_message", let text = item?["text"] as? String, !text.isEmpty {
                defer { sent = true }
                return [.delta(sent ? "\n\n" + text : text)]
            }
        case "turn.completed": return [.done(error: nil)]
        case "turn.failed", "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? obj["message"] as? String
            return [.done(error: msg ?? "Codex couldn't finish that.")]
        default: break
        }
        return []
    }
}

/// Tests reach the parsers through these.
enum QuickAskParsing {
    static func claude(_ lines: [String]) -> [QuickAsk.Event] {
        var saw = false, brk = false, sid: String?
        return lines.flatMap { ClaudeProcess.parse(Data($0.utf8), sawText: &saw, needsBreak: &brk, session: &sid) }
    }

    static func codex(_ lines: [String]) -> (events: [QuickAsk.Event], thread: String?) {
        var sent = false, thread: String?
        let events = lines.flatMap { CodexRun.parse(Data($0.utf8), sent: &sent, thread: &thread) }
        return (events, thread)
    }
}

// MARK: - The screen, one frame

/// The screen at the moment the ask card opened: one frame of the main display, Liquid Notch's own windows left out,
/// 1600 px wide at most, as JPEG for the question. Never continuous, and never shown (owner, 11-07).
struct ScreenFrame: Sendable {
    let jpeg: Data

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    static func capture() async -> ScreenFrame? {
        guard allowed,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { return nil }
        let ours = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1600 / Double(display.width), 1) * Double(filter.pointPixelScale)
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return ScreenFrame(jpeg: jpeg)
    }
}
