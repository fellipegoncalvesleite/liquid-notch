import Darwin
import Foundation

/// The notch's end of the agent hooks (docs/superpowers/specs/2026-11-06-agents-design.md): a Unix socket the hook
/// script writes one line to, `provider<TAB>event<TAB>host<TAB>json` (host: the bundle ID of the app the session runs
/// in, from `__CFBundleIdentifier`, empty when unknown). Every event but an approval is fire-and-forget (the
/// connection is closed as soon as the line is read); an approval's connection stays open until `reply` answers it
/// (one line of JSON, or nothing: the session then asks in its own app as usual).
@MainActor
final class AgentSocket {
    struct Line: Sendable {
        let provider: String
        let event: String
        let host: String
        let raw: Data
        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]) ?? [:] }
        /// The hook waits for an answer: an approval, or Claude asking you a question (answered from the notch through
        /// `updatedInput.answers`, phase 4 of the agents design).
        var waits: Bool {
            event == "PermissionRequest" || (event == "PreToolUse" && provider == "claude" && json["tool_name"] as? String == "AskUserQuestion")
        }
    }

    nonisolated static var path: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liquid Notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agents.sock").path
    }

    /// A line arrived. `reply` is non-nil for an approval: call it once with the answer's JSON (or nil for none).
    var onLine: ((Line, ((String?) -> Void)?) -> Void)?

    private let path: String
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String = AgentSocket.path) { self.path = path }

    func start() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8)
            guard bytes.count < buf.count else { return false }
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
            return true
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard ok, withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }) == 0,
              listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel(); source = nil
        if listener >= 0 { close(listener); listener = -1 }
        unlink(path)
    }

    private func accept() {
        while true {
            let c = Darwin.accept(listener, nil, nil)
            guard c >= 0 else { return }
            read(c)
        }
    }

    /// Reads one line off a connection, off the main thread, with a 2 s limit (a hook never waits on us).
    private func read(_ c: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var nosig: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var data = Data(), buf = [UInt8](repeating: 0, count: 16_384)
            while data.count < 4_000_000 {
                let n = Darwin.read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
                if buf[..<n].contains(10) { break }
            }
            let line = Self.parse(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let line else { close(c); return }
                    if line.waits {
                        var answered = false
                        self.onLine?(line) { answer in
                            guard !answered else { return }
                            answered = true
                            if let answer, let bytes = (answer + "\n").data(using: .utf8) {
                                bytes.withUnsafeBytes { _ = write(c, $0.baseAddress, bytes.count) }
                            }
                            close(c)
                        }
                    } else {
                        close(c)
                        self.onLine?(line, nil)
                    }
                }
            }
        }
    }

    nonisolated static func parse(_ data: Data) -> Line? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = text.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let body = String(parts[3]).data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else { return nil }
        return Line(provider: String(parts[0]), event: String(parts[1]), host: String(parts[2]), raw: body)
    }
}
