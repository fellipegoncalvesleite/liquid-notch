import Foundation

/// Replies that reach a session without its window (11-06). Codex takes one with `codex queue --thread <id> --message
/// <text>`, preferably through the ChatGPT app's own CLI (the same version as the app). The Claude app has no such way
/// in yet; the director copies the reply and opens the session there instead.
enum AgentReply {
    static let codexCandidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
    ]

    static var codex: String? { codexCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Queues the text on the thread; true when the CLI took it (it exits 0). Gives up after 15 s.
    static func codexQueue(thread: String, _ text: String) async -> Bool {
        guard let codex else { return false }
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: codex)
            p.arguments = ["queue", "--thread", thread, "--message", text]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            let deadline = Date().addingTimeInterval(15)
            while p.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if p.isRunning { p.terminate(); return false }
            return p.terminationStatus == 0
        }.value
    }
}
