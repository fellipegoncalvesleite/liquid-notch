import Foundation
import IslandCore

extension AgentHook {
    /// A hook line from the socket: Claude Code's and Codex's inputs share their fields (`session_id`, `cwd`,
    /// `tool_name`, `tool_input`); Claude Code adds `notification_type` and StopFailure's `error`.
    init?(_ line: AgentSocket.Line) {
        guard let provider = AgentProvider(rawValue: line.provider) else { return nil }
        let j = line.json
        guard let session = j["session_id"] as? String, !session.isEmpty else { return nil }
        let tool = j["tool_name"] as? String ?? ""
        let input = j["tool_input"] as? [String: Any] ?? [:]
        var detail = ["command", "file_path", "path", "url", "pattern", "description"].lazy
            .compactMap { input[$0] as? String }.first ?? ""
        var options: [String] = []
        if tool == "AskUserQuestion", let q = (input["questions"] as? [[String: Any]])?.first {
            detail = q["question"] as? String ?? ""
            options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        }
        self.init(provider: provider, event: line.event, sessionID: session, cwd: j["cwd"] as? String ?? "",
                  host: line.host, tool: tool, detail: String(detail.prefix(400)), options: options,
                  kind: j["notification_type"] as? String ?? j["error"] as? String ?? "")
        transcript = j["transcript_path"] as? String ?? ""
    }

    /// The answer to a question (Claude's AskUserQuestion) from its PreToolUse hook: the tool runs with your pick filled in,
    /// `updatedInput.answers` mapping the question's text to the chosen option's label.
    static func answer(input: [String: Any], question: String, option: String) -> String {
        var updated = input
        var answers = updated["answers"] as? [String: Any] ?? [:]
        answers[question] = option
        updated["answers"] = answers
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                                         "updatedInput": updated]]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The answer an approval hook prints: allow or deny, the shape Claude Code and Codex both read.
    static func decision(allow: Bool) -> String {
        let decision: [String: Any] = allow ? ["behavior": "allow"]
            : ["behavior": "deny", "message": "Denied from Liquid Notch."]
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
