import CoreServices
import Foundation
import IslandCore

/// One line of a session's chat in the card: what you said, what the agent said, or a run of tools folded into one line.
enum AgentChatItem: Equatable, Sendable {
    case you(String)
    case agent(String)
    /// A summary (`Ran 3 commands · edited 2 files`) and each tool on its own line.
    case tools(String, [String])
}

/// Reads a session's transcript, the tail only: Claude Code's session JSONL (`~/.claude/projects/…`, the desktop app's
/// Code tab included) and Codex's rollout (`~/.codex/sessions/…`). Text is kept as written; tool runs are folded.
enum AgentTranscript {
    /// The last `limit` items of a transcript (oldest first). Reads more of a long file when its tail is all tool output.
    static func read(_ url: URL, provider: AgentProvider, limit: Int = 12) -> [AgentChatItem] {
        var bytes = 1_500_000
        while true {
            guard let (lines, whole) = tail(url, bytes: bytes) else { return [] }
            let items = provider == .claude ? parseClaude(lines) : parseCodex(lines)
            if items.count >= 3 || whole || bytes >= 12_000_000 { return Array(items.suffix(limit)) }
            bytes *= 4
        }
    }

    /// The file's last `bytes`, as lines (a cut first line is dropped). `whole` when that was the entire file.
    static func tail(_ url: URL, bytes: Int) -> ([Substring], Bool)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return (lines, start == 0)
    }

    // MARK: Claude Code

    static func parseClaude(_ lines: [Substring]) -> [AgentChatItem] {
        var out = Fold()
        for line in lines where line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
            guard let d = json(line), d["isSidechain"] as? Bool != true, d["isMeta"] as? Bool != true,
                  let message = d["message"] as? [String: Any] else { continue }
            let content = message["content"]
            switch d["type"] as? String {
            case "user":
                if let text = content as? String { out.you(cleanUser(text)); continue }
                let blocks = content as? [[String: Any]] ?? []
                guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
                out.you(cleanUser(blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")))
            case "assistant":
                for b in content as? [[String: Any]] ?? [] {
                    switch b["type"] as? String {
                    case "text": out.agent(b["text"] as? String ?? "")
                    case "tool_use": out.tool(claudeTool(b["name"] as? String ?? "", b["input"] as? [String: Any] ?? [:]))
                    default: break   // thinking
                    }
                }
            default: break
            }
        }
        return out.done()
    }

    /// A user turn as typed: system reminders and wrapped command output dropped.
    static func cleanUser(_ text: String) -> String {
        var t = text
        while let open = t.range(of: "<system-reminder>"), let close = t.range(of: "</system-reminder>", range: open.upperBound..<t.endIndex) {
            t.removeSubrange(open.lowerBound..<close.upperBound)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<") ? "" : t   // <command-name>, <local-command-stdout>, caveats
    }

    static func claudeTool(_ name: String, _ input: [String: Any]) -> Tool {
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        switch name {
        case "Bash": return Tool(.command, "$ " + firstLine(input["command"] as? String ?? ""))
        case "Edit", "MultiEdit", "NotebookEdit": return Tool(.edit, "Edited \(file)")
        case "Write": return Tool(.edit, "Wrote \(file)")
        case "Read": return Tool(.read, "Read \(file)")
        case "Grep", "Glob": return Tool(.search, "Searched \(input["pattern"] as? String ?? "")")
        case "WebSearch": return Tool(.search, "Searched the web for \(input["query"] as? String ?? "")")
        case "WebFetch": return Tool(.search, "Fetched \(URL(string: input["url"] as? String ?? "")?.host() ?? "a page")")
        case "Task", "Agent": return Tool(.other, "Ran an agent: \(input["description"] as? String ?? "")")
        default:
            let short = name.hasPrefix("mcp__") ? String(name.split(separator: "_").last ?? "") : name
            return Tool(.other, "Used \(short)")
        }
    }

    // MARK: Codex

    /// Codex's rollouts: newer ones log each finished item (`item_completed`); older ones log `user_message` and
    /// `agent_message` events, with tools as response items.
    static func parseCodex(_ lines: [Substring]) -> [AgentChatItem] {
        var out = Fold()
        let items = lines.contains { $0.contains("\"item_completed\"") }
        for line in lines {
            if items {
                guard line.contains("\"item_completed\""), let d = json(line), let p = d["payload"] as? [String: Any],
                      let item = p["item"] as? [String: Any] else { continue }
                let texts = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                switch item["type"] as? String {
                case "UserMessage": out.you(cleanCodexUser(texts))
                case "AgentMessage": out.agent(texts)
                case "CommandExecution":
                    let cmd = item["command"] as? [String] ?? []
                    out.tool(Tool(.command, "$ " + firstLine(cmd.last ?? "")))
                case "FileChange": out.tool(Tool(.edit, "Edited files"))
                case "McpToolCall":
                    let args = item["arguments"] as? [String: Any] ?? [:]
                    out.tool(Tool(.other, args["title"] as? String ?? "Used \(item["tool"] as? String ?? "a tool")"))
                case "Extension": out.tool(Tool(.search, (item["kind"] as? String) == "web.search" ? "Searched the web" : "Used an extension"))
                case "ImageView": out.tool(Tool(.read, "Looked at an image"))
                default: break   // reasoning, compaction
                }
            } else {
                guard let d = json(line), let p = d["payload"] as? [String: Any] else { continue }
                switch (d["type"] as? String, p["type"] as? String) {
                case ("event_msg", "user_message"): out.you(cleanCodexUser(p["message"] as? String ?? ""))
                case ("event_msg", "agent_message"): out.agent(p["message"] as? String ?? "")
                case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
                    let name = p["name"] as? String ?? "shell"
                    out.tool(name == "shell" || name == "exec_command" || name == "local_shell"
                             ? Tool(.command, "Ran a command") : Tool(.other, "Used \(name)"))
                default: break
                }
            }
        }
        return out.done()
    }

    /// A Codex turn as typed: attachments' preamble and environment blocks dropped.
    static func cleanCodexUser(_ text: String) -> String {
        var t = text
        if let r = t.range(of: "## My request for Codex:") { t = String(t[r.upperBound...]) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<") ? "" : t
    }

    // MARK: Folding

    struct Tool {
        enum Kind { case command, edit, read, search, other }
        let kind: Kind
        let line: String
        init(_ kind: Kind, _ line: String) { self.kind = kind; self.line = line }
    }

    /// Builds the list, folding each run of tools between two messages into one line.
    struct Fold {
        private var items: [AgentChatItem] = []
        private var run: [Tool] = []

        mutating func you(_ t: String) { text(.you(t), t) }
        mutating func agent(_ t: String) {
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            flush()
            if case .agent(let prev)? = items.last { items[items.count - 1] = .agent(prev + "\n\n" + t) } else { items.append(.agent(t)) }
        }
        mutating func tool(_ t: Tool) { run.append(t) }
        mutating func done() -> [AgentChatItem] { flush(); return items }

        private mutating func text(_ item: AgentChatItem, _ t: String) {
            guard !t.isEmpty else { return }
            flush()
            items.append(item)
        }

        private mutating func flush() {
            guard !run.isEmpty else { return }
            items.append(.tools(AgentTranscript.summary(run), run.map(\.line)))
            run = []
        }
    }

    /// `Ran 3 commands · edited 2 files · read 4 files`; one tool reads as itself.
    static func summary(_ run: [Tool]) -> String {
        if run.count == 1 { return run[0].line.hasPrefix("$ ") ? "Ran " + run[0].line.dropFirst(2) : run[0].line }
        func n(_ k: Tool.Kind) -> Int { run.filter { $0.kind == k }.count }
        func phrase(_ c: Int, _ verb: String, _ one: String, _ many: String) -> String? { c == 0 ? nil : "\(verb) \(c) \(c == 1 ? one : many)" }
        let parts = [phrase(n(.command), "ran", "command", "commands"), phrase(n(.edit), "edited", "file", "files"),
                     phrase(n(.read), "read", "file", "files"), phrase(n(.search), "searched", "time", "times"),
                     phrase(n(.other), "used", "tool", "tools")].compactMap { $0 }
        let s = parts.joined(separator: " · ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private static func firstLine(_ s: String) -> String {
        String(s.split(separator: "\n", omittingEmptySubsequences: true).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

/// Where a session lives and how to open it (11-06). The Claude app keeps a record per Code session
/// (`claude-code-sessions/<account>/<org>/local_<id>.json`, with `cliSessionId` and `title`) and opens one with
/// `claude://code/continue?session=local_<id>`. Codex names its threads in `~/.codex/session_index.jsonl` and opens one
/// with `codex://threads/<id>`.
struct AgentDirectory: Sendable {
    struct ClaudeRecord: Equatable, Sendable {
        let localID: String
        let title: String
    }

    var claudeSessions: URL
    var codexHome: URL

    static let live: AgentDirectory = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AgentDirectory(claudeSessions: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
                              codexHome: home.appendingPathComponent(".codex"))
    }()

    /// The Claude app's record of a Code session, by its Claude Code session ID: the newest files first (a live
    /// session's record is the one being written), checking only each file's start for the ID.
    /// The Claude Code session the Claude app shows right now: the record focused last (`lastFocusedAt`, which the app
    /// updates as you switch sessions), as its CLI id (the hooks' `session_id`). Records run to a megabyte each and
    /// there are hundreds: only files that changed are read again (`FocusedSessionCache`).
    /// With `title` (what the app's window shows, read over Accessibility the moment you switch), the session with that
    /// title, the most recently focused if two share it; else the record focused last (the app writes that ~3 s late).
    func focusedClaudeSession(title: String? = nil, cache: FocusedSessionCache = .shared) -> String? {
        var best: FocusedSessionCache.Record?, titled: FocusedSessionCache.Record?
        for r in cache.records(in: claudeSessions) {
            if r.focusedAt > (best?.focusedAt ?? -1) { best = r }
            if let title, r.title == title, r.focusedAt > (titled?.focusedAt ?? -1) { titled = r }
        }
        return (titled ?? best)?.id
    }

    func claudeRecord(cliID: String) -> ClaudeRecord? {
        guard !cliID.isEmpty, let e = FileManager.default.enumerator(at: claudeSessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            files.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }) {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? h.read(upToCount: 4096)) ?? Data()
            try? h.close()
            guard String(decoding: head, as: UTF8.self).contains(cliID),
                  let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
                  d["cliSessionId"] as? String == cliID, let local = d["sessionId"] as? String else { continue }
            return ClaudeRecord(localID: local, title: d["title"] as? String ?? "")
        }
        return nil
    }

    /// A Codex thread's name, the latest one given.
    func codexName(id: String) -> String? {
        guard let text = try? String(contentsOf: codexHome.appendingPathComponent("session_index.jsonl"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains(id) {
            if let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], d["id"] as? String == id {
                return d["thread_name"] as? String
            }
        }
        return nil
    }

    /// A Codex thread's rollout when the hook didn't say: `sessions/<y>/<m>/<d>/rollout-…-<id>.jsonl`, newest days first.
    func codexTranscript(id: String) -> URL? {
        let fm = FileManager.default, root = codexHome.appendingPathComponent("sessions")
        func dirs(_ u: URL) -> [URL] { ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path > $1.path } }
        for y in dirs(root) { for m in dirs(y) { for d in dirs(m) {
            if let f = dirs(d).first(where: { $0.lastPathComponent.hasSuffix("-\(id).jsonl") }) { return f }
        } } }
        return nil
    }

    /// The link that opens this very session in its app, when its app has one.
    static func link(_ s: AgentSession, claude: ClaudeRecord?) -> URL? {
        switch s.provider {
        case .claude:
            guard Agents.app(of: s) == Agents.app(.claude), let claude else { return nil }
            return URL(string: "claude://code/continue?session=\(claude.localID)")
        case .codex:
            guard Agents.app(of: s) == Agents.app(.codex) else { return nil }
            return URL(string: "codex://threads/\(s.id)")
        case .ask:
            return nil   // the notch's own conversation lives here
        }
    }
}

/// What each Claude session record says, by path, so the viewed-session read (four times a second while the Claude app
/// is in front) parses a record only when it changed. While `watch` follows the folder, FSEvents names the records that
/// changed and a read touches only those: listing ~275 records and reading each one's modification time four times a
/// second was 5-7% CPU (11-07). Unwatched, every read lists the folder and re-parses only files whose time moved.
final class FocusedSessionCache: @unchecked Sendable {
    struct Record: Sendable {
        let id: String
        let focusedAt: Double
        let title: String
    }

    static let shared = FocusedSessionCache()

    /// Guards the watch's state below; never held over file reads, since `watch` is called on the main thread.
    private let lock = NSLock()
    /// One read at a time; guards `files`.
    private let reading = NSLock()
    /// Every `local_*.json` under the root by real path: its modification time and what it says (nil: no session in it).
    private var files: [String: (mtime: Date, record: Record?)] = [:]
    private var stream: FSEventStreamRef?
    private var watchedRoot: String?
    /// Paths FSEvents named since the last read.
    private var changed: Set<String> = []
    /// List the whole folder on the next read: just started watching, or FSEvents lost track.
    private var stale = true
    private var listingCount = 0
    private let queue = DispatchQueue(label: "com.fellipe.liquidnotch.claude-sessions", qos: .utility)

    /// How many times the folder was listed in full (tests).
    var listings: Int { lock.withLock { listingCount } }

    deinit { if let stream { Self.stop(stream) } }

    /// Follows `root` with FSEvents (nil stops); the first read after either lists the folder again.
    func watch(_ root: URL?) {
        lock.lock()
        guard root?.path != watchedRoot else { lock.unlock(); return }
        let old = stream
        stream = nil; watchedRoot = nil; stale = true; changed.removeAll()
        if let root {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let cache = Unmanaged<FocusedSessionCache>.fromOpaque(info).takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                cache.noted(list, Array(UnsafeBufferPointer(start: flags, count: count)))
            }
            if let s = FSEventStreamCreate(nil, callback, &context, [Self.realPath(root)] as CFArray,
                                           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, FSEventStreamCreateFlags(flags)) {
                FSEventStreamSetDispatchQueue(s, queue)
                if FSEventStreamStart(s) { stream = s; watchedRoot = root.path } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
            }
        }
        lock.unlock()
        if let old { Self.stop(old) }
    }

    /// Every session record under `root`, read from memory where nothing changed.
    func records(in root: URL) -> [Record] {
        reading.lock(); defer { reading.unlock() }
        // Events that land while this read runs are kept for the next one.
        let (full, paths): (Bool, Set<String>) = lock.withLock {
            let watched = root.path == watchedRoot, full = stale || !watched
            if watched { stale = false }
            if full { listingCount += 1 }
            defer { changed.removeAll() }
            return (full, changed)
        }
        if full { list(root) } else { for path in paths { refresh(path) } }
        return files.values.compactMap(\.record)
    }

    private func noted(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        // Dropped events name nothing, and a folder moved or removed takes its records with it unnamed. (The Claude app
        // writes `local_<id>.json.tmp` and renames it over the record: file events only.)
        let lost = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped
        let moved = kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved
        lock.withLock {
            for (path, flag) in zip(paths, flags.map(Int.init)) {
                if flag & lost != 0 || (flag & kFSEventStreamEventFlagItemIsDir != 0 && flag & moved != 0) { stale = true }
                else { changed.insert(path) }
            }
        }
    }

    private func list(_ root: URL) {
        var seen: [String: (mtime: Date, record: Record?)] = [:]
        let real = URL(fileURLWithPath: Self.realPath(root), isDirectory: true)
        if let e = FileManager.default.enumerator(at: real, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in e where Self.isRecord(url) {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                seen[url.path] = Self.read(url, mtime, files[url.path])
            }
        }
        files = seen
    }

    private func refresh(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard Self.isRecord(url), let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              v.isRegularFile == true, let mtime = v.contentModificationDate else { files[path] = nil; return }
        files[path] = Self.read(url, mtime, files[path])
    }

    private static func read(_ url: URL, _ mtime: Date, _ old: (mtime: Date, record: Record?)?) -> (mtime: Date, record: Record?) {
        if let old, old.mtime == mtime { return old }
        guard let data = try? Data(contentsOf: url), let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = j["cliSessionId"] as? String, let at = (j["lastFocusedAt"] as? NSNumber)?.doubleValue else { return (mtime, nil) }
        return (mtime, Record(id: id, focusedAt: at, title: j["title"] as? String ?? ""))
    }

    private static func isRecord(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" }

    /// FSEvents names files by their real path (a temporary folder's `/var` is `/private/var`), so records are keyed by it.
    private static func realPath(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.path }
        defer { free(p) }
        return String(cString: p)
    }

    private static func stop(_ s: FSEventStreamRef) {
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
    }
}

