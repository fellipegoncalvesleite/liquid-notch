import CoreServices
import Foundation

/// Where the adapter lives: the framework perl loads and the script that loads it.
public struct AdapterLocation: Sendable, Equatable {
    public var framework: URL
    public var script: URL

    public init(framework: URL, script: URL) {
        self.framework = framework
        self.script = script
    }

    /// In the app bundle (`Contents/Frameworks`, `Contents/Resources`), else in the source tree
    /// (`swift run`: `.build/adapter` from `tools/build_adapter.sh`, the script in `Vendor/`).
    public static func find(in bundle: Bundle = .main, sourceRoot: URL?) -> AdapterLocation? {
        let fm = FileManager.default
        if let fw = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
           let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
           fm.fileExists(atPath: fw.appendingPathComponent("MediaRemoteAdapter").path) {
            return AdapterLocation(framework: fw, script: script)
        }
        guard let root = sourceRoot else { return nil }
        let fw = root.appendingPathComponent(".build/adapter/MediaRemoteAdapter.framework")
        let script = root.appendingPathComponent("Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl")
        guard fm.fileExists(atPath: fw.appendingPathComponent("MediaRemoteAdapter").path),
              fm.fileExists(atPath: script.path) else { return nil }
        return AdapterLocation(framework: fw, script: script)
    }
}

/// Keeps track of what's playing. The adapter (MediaRemote through `/usr/bin/perl`) is the
/// source while it runs; when it can't, Music's and Spotify's distributed notifications take
/// over, with AppleScript for their controls and position where Automation is already allowed
/// (this never asks: permissions are asked up front, in the setup window).
@MainActor
public final class NowPlayingMonitor {
    /// Automation answers per player app (kept a minute) and the checks in flight (`ifAutomationAllowed`).
    private var automationCache: [String: (allowed: Bool, at: Date)] = [:]
    private var automationChecking: Set<String> = []
    public enum Source: String, Sendable {
        case adapter, notifications, none
    }

    public private(set) var source: Source = .none
    public private(set) var current: NowPlaying?
    /// Fired when what's playing changes (nil: nothing).
    public var onChange: ((NowPlaying?) -> Void)?
    /// Fired when the source changes (debug readout).
    public var onSource: ((Source) -> Void)?

    private let adapter: AdapterLocation?
    private var process: Process?
    /// Our end of the adapter's lifeline: closing it (or our process ending) stops the adapter.
    private var lifeline: Pipe?
    private var stream = AdapterStream()
    private var buffer = Data()
    private var failures = 0
    private var restartTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var fromNotifications: NowPlaying?
    /// What the adapter reports: macOS's single Now Playing item (the player that played last).
    private var fromAdapter: NowPlaying?
    private var running = false
    /// A second player playing at the same time (owner, 11-11: a video and a song, one of them in a ball). macOS reports
    /// one player at a time; Spotify and Music also announce themselves, so when both play the song is the main one and
    /// the other is the second.
    public private(set) var second: NowPlaying?
    public var onSecond: ((NowPlaying?) -> Void)?

    /// The main player and the second: the reported one, unless it's paused while Spotify or Music plays (then that
    /// one); both playing, the song is the main one.
    nonisolated public static func split(primary: NowPlaying?, alternate: NowPlaying?) -> (main: NowPlaying?, second: NowPlaying?) {
        guard let a = alternate, a.playing, let p = primary, a.bundleID != p.bundleID else { return (primary, nil) }
        if !p.playing { return (a, nil) }
        return p.isMusic || !a.isMusic ? (p, a) : (a, p)
    }

    private func republish() {
        guard source == .adapter else { publish(fromNotifications); publishSecond(nil); return }
        let s = Self.split(primary: fromAdapter, alternate: fromNotifications)
        publish(s.main)
        publishSecond(s.second)
    }

    private func publishSecond(_ np: NowPlaying?) {
        guard np != second else { return }
        second = np
        onSecond?(np)
    }

    /// A command to one player by its app: the adapter's own through the adapter, Spotify or Music by AppleScript.
    public func send(_ command: MediaCommand, to bundle: String) {
        if source == .adapter, bundle == fromAdapter?.bundleID, let adapter {
            run("/usr/bin/perl", [adapter.script.path, adapter.framework.path, "send", String(command.rawValue)])
            return
        }
        guard let script = PlayerNotifications.script(command, bundleID: bundle) else { return }
        ifAutomationAllowed(bundle) { [weak self] in self?.run("/usr/bin/osascript", ["-e", script]) }
    }

    /// The shown player is the adapter's own (so its commands go through the adapter).
    private var showingAdapter: Bool { source == .adapter && current?.bundleID == fromAdapter?.bundleID }

    public init(adapter: AdapterLocation?) {
        self.adapter = adapter
    }

    public func start() {
        guard !running else { return }
        running = true
        let center = DistributedNotificationCenter.default()
        for name in PlayerNotifications.names {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] n in
                let info = n.userInfo ?? [:]
                let parsed = PlayerNotifications.parse(name: n.name.rawValue, userInfo: info)
                MainActor.assumeIsolated { self?.received(notification: parsed) }
            })
        }
        setSource(.notifications)
        launchAdapter()
    }

    public func stop() {
        running = false
        restartTask?.cancel()
        restartTask = nil
        process?.terminationHandler = nil
        cutLifeline()
        process = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }

    /// Play/pause, next, previous: through the adapter, else AppleScript to the player (if allowed).
    public func send(_ command: MediaCommand) {
        if showingAdapter, let adapter {
            run("/usr/bin/perl", [adapter.script.path, adapter.framework.path, "send", String(command.rawValue)])
            return
        }
        guard let bundle = current?.bundleID, let script = PlayerNotifications.script(command, bundleID: bundle) else { return }
        ifAutomationAllowed(bundle) { [weak self] in self?.run("/usr/bin/osascript", ["-e", script]) }
    }

    /// Seeks the player to `seconds`: the adapter's `seek <microseconds>`, else AppleScript's `set player position`
    /// to Music or Spotify (only where Automation is already allowed).
    public func seek(to seconds: Double) {
        let s = max(seconds, 0)
        if showingAdapter, let adapter {
            run("/usr/bin/perl", [adapter.script.path, adapter.framework.path, "seek", String(Int64(s * 1_000_000))])
            return
        }
        guard let bundle = current?.bundleID, let script = PlayerNotifications.seekScript(seconds: s, bundleID: bundle) else { return }
        ifAutomationAllowed(bundle) { [weak self] in self?.run("/usr/bin/osascript", ["-e", script]) }
    }

    /// The player's own position (AppleScript's `player position`; Music or Spotify, only where Automation is already
    /// allowed) and the moment it was true (the middle of the script's run): the lyrics' check on the Now Playing clock.
    public func probePosition(_ completion: @escaping @MainActor (Double, Date) -> Void) {
        guard let bundle = current?.bundleID, let script = PlayerNotifications.positionScript(bundleID: bundle) else { return }
        ifAutomationAllowed(bundle) { [weak self] in
            let start = Date()
            self?.run("/usr/bin/osascript", ["-e", script]) { out in
                let middle = start.addingTimeInterval(Date().timeIntervalSince(start) / 2)
                guard let seconds = Double(out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
                else { return }
                completion(seconds, middle)
            }
        }
    }

    /// Runs `then` (on the main actor) only where Automation is already allowed for `bundle`. The check itself
    /// (`AEDeterminePermissionToAutomateTarget`) can wait on the player app indefinitely: it froze the whole island on
    /// 11-07 when it ran on the main thread from a Music notification. So it runs off the main thread, one check per app
    /// at a time, and its answer is kept for a minute.
    private func ifAutomationAllowed(_ bundle: String, then: @escaping @MainActor () -> Void,
                                     otherwise: (@MainActor () -> Void)? = nil) {
        if let known = automationCache[bundle], Date().timeIntervalSince(known.at) < 60 {
            if known.allowed { then() } else { otherwise?() }
            return
        }
        guard !automationChecking.contains(bundle) else { otherwise?(); return }
        automationChecking.insert(bundle)
        Task.detached(priority: .utility) { [weak self] in
            let allowed = Self.automationAllowed(bundle, ask: false)
            await MainActor.run {
                guard let self else { return }
                self.automationChecking.remove(bundle)
                self.automationCache[bundle] = (allowed, Date())
                if allowed { then() } else { otherwise?() }
            }
        }
    }

    /// The playing track's own link (Spotify's `spotify:track:…`, from AppleScript where Automation is allowed), or nil.
    public func trackLink(_ completion: @escaping @MainActor (URL?) -> Void) {
        guard let bundle = current?.bundleID, bundle == PlayerNotifications.spotifyBundle else { completion(nil); return }
        ifAutomationAllowed(bundle, then: { [weak self] in
            self?.run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to id of current track"]) { out in
                let id = out.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(id.hasPrefix("spotify:") ? URL(string: id) : nil)
            }
        }, otherwise: { completion(nil) })
    }

    /// Opens the playing song in its player, behind the same Automation check: Spotify on the track's own link, Music
    /// revealing the current track and coming to the front (v1, 11-11). False when it can't (another player, no
    /// Automation, a script error): the caller brings the app forward instead.
    public func openTrack(link open: @escaping @MainActor (URL) -> Void, _ completion: @escaping @MainActor (Bool) -> Void) {
        guard let bundle = current?.bundleID else { completion(false); return }
        if bundle == PlayerNotifications.spotifyBundle {
            trackLink { link in
                if let link { open(link) }
                completion(link != nil)
            }
            return
        }
        guard let script = Self.revealScript(for: bundle) else { completion(false); return }
        ifAutomationAllowed(bundle, then: { [weak self] in
            self?.run("/usr/bin/osascript", ["-e", script]) { out in
                completion(out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
            }
        }, otherwise: { completion(false) })
    }

    /// Music: reveal the current track in its window and come to the front.
    nonisolated public static func revealScript(for bundle: String) -> String? {
        guard bundle == PlayerNotifications.musicBundle else { return nil }
        return """
            try
                tell application "Music"
                    reveal current track
                    activate
                end tell
                return "ok"
            on error
                return "no"
            end try
            """
    }

    /// Where the Automation permission for one app stands.
    public enum Automation: Sendable, Equatable {
        case allowed
        /// Turned off (in the prompt or in System Settings): only System Settings can turn it back on.
        case denied
        /// Not answered yet: asking shows the system prompt.
        case notAsked
        /// The app isn't running, so the system can't say (or ask).
        case notRunning
    }

    /// The Automation permission for `bundleID`. With `ask`, shows the system prompt if it hasn't
    /// been answered (blocks until it is: call it off the main thread, from the setup window).
    nonisolated public static func automation(_ bundleID: String, ask: Bool) -> Automation {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .notRunning }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .notAsked
        }
    }

    nonisolated public static func automationAllowed(_ bundleID: String, ask: Bool) -> Bool {
        automation(bundleID, ask: ask) == .allowed
    }

    // MARK: - Adapter

    private func launchAdapter() {
        guard running, let adapter else { return }
        let p = Process()
        // perl doesn't notice its parent going away (a paused player gives it nothing to write), so it
        // runs under a small shell that kills it when its stdin closes: when we stop it, quit, or crash.
        // (The watcher reads a copy of stdin on fd 3: a background job's own stdin is /dev/null.)
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"exec 3<&0; "$@" </dev/null & p=$!; (cat <&3 >/dev/null; kill $p 2>/dev/null) & wait $p"#, "sh",
                       "/usr/bin/perl", adapter.script.path, adapter.framework.path, "stream", "--micros",
                       "--debounce=120", "--allow-missing-title"]
        let out = Pipe()
        let life = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = life
        lifeline = life
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.adapterEnded() } }
        }
        stream = AdapterStream()
        buffer = Data()
        do {
            try p.run()
            process = p
        } catch {
            process = nil
            adapterEnded()
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard case .nowPlaying(let np) = stream.consume(line) else { continue }
            failures = 0
            setSource(.adapter)
            fromAdapter = np
            republish()
        }
    }

    /// The adapter stopped: the notifications take over, and it's tried again a little later
    /// (1, 2, 4… up to 60 s).
    private func adapterEnded() {
        process = nil
        cutLifeline()
        guard running else { return }
        failures += 1
        setSource(.notifications)
        fromAdapter = nil
        publish(fromNotifications)
        let wait = min(pow(2, Double(failures - 1)), 60)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.launchAdapter()
        }
    }

    // MARK: - Fallback

    private func received(notification parsed: NowPlaying??) {
        guard let parsed else { return }          // not a player we follow
        var np = parsed
        // A new track or a resume: Music's notification has no position, so ask (if allowed).
        if let n = np, n.identity != fromNotifications?.identity || n.playing != fromNotifications?.playing {
            if n.bundleID == PlayerNotifications.musicBundle { np?.elapsed = 0 }
            fetchPosition(for: n)
        }
        fromNotifications = np
        republish()
    }

    private func fetchPosition(for np: NowPlaying) {
        guard let bundle = np.bundleID, let script = PlayerNotifications.positionScript(bundleID: bundle) else { return }
        ifAutomationAllowed(bundle) { [weak self] in self?.fetchPosition(script, for: np) }
    }

    private func fetchPosition(_ script: String, for np: NowPlaying) {
        run("/usr/bin/osascript", ["-e", script]) { [weak self] output in
            guard let self, let seconds = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")),
                  var current = fromNotifications, current.identity == np.identity else { return }
            current.elapsed = seconds
            current.timestamp = Date()
            fromNotifications = current
            republish()
        }
    }

    // MARK: - Helpers

    private func cutLifeline() {
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
    }

    private func publish(_ np: NowPlaying?) {
        guard np != current else { return }
        current = np
        onChange?(np)
    }

    private func setSource(_ s: Source) {
        guard s != source else { return }
        source = s
        onSource?(s)
    }

    private func run(_ path: String, _ args: [String], completion: (@MainActor (String) -> Void)? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion?(text) } }
        }
        try? p.run()
    }
}
