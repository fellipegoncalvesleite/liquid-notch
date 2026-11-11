import Foundation
import IslandCore

/// A sample track. P1 runs on these so the presentation can be built and felt before
/// the real Now Playing feed exists (P2).
struct FakeTrack: Equatable, Sendable {
    let title: String
    let artist: String
    /// Drives the bars, the pulse and (album glow) the aura, the way the album colour will in P2.
    let colorHex: String
    let length: Double
    /// Cover art drawn as a gradient with one highlight dot.
    let gradient: [String]
    let dotHex: String
    let dotAt: SIMD2<Double>
    let dotSize: Double

    static let samples: [FakeTrack] = [
        FakeTrack(title: "Glass Harbor", artist: "Mirela Sun", colorHex: "#FF7A3D", length: 204,
                  gradient: ["#FF7A3D", "#A3245A", "#2B2D6E"], dotHex: "#FFD08A", dotAt: SIMD2(0.7, 0.3), dotSize: 0.36),
        FakeTrack(title: "Night Ferry", artist: "The Low Tides", colorHex: "#3DD6C6", length: 251,
                  gradient: ["#3DD6C6", "#136F86", "#0F2233"], dotHex: "#E8FFFB", dotAt: SIMD2(0.3, 0.65), dotSize: 0.18),
        FakeTrack(title: "Paper Moons", artist: "Ana Vell", colorHex: "#FF4FA3", length: 188,
                  gradient: ["#FFB3D6", "#7C5CFF"], dotHex: "#3A1240", dotAt: SIMD2(0.5, 0.5), dotSize: 0.44),
    ]
}

/// The live part of each sample activity. Clocks advance from elapsed time (`advance(dt)`),
/// never from the number of ticks, so a burst of ticks in one instant adds nothing (`CLK1`).
struct SampleState: Sendable {
    var callSeconds = 0.0
    var muted = false
    var speaker = false
    var timerLeft = 60.0
    var timerPaused = false
    var timerDone = false
    var recordSeconds = 0.0
    var recordPaused = false
    var meetingLeft = 300.0
    var download = 0.04
    var downloadSpeed = 42.0
    var downloadPaused = false
    var downloadDone = false
    /// Focus is read-only: on or off (the Mac can't say which Focus, nor set one).
    var focusOn = true
    /// The timer's length, from the menu bar's Timer menu.
    var timerTotal = 60.0
    var cameraSeconds = 0.0
    var lowLevel = 20

    static let downloadGB = 3.4

    /// Starts one showing fresh (each showing of a sample starts from the beginning).
    mutating func reset(_ id: ActivityID) {
        switch id {
        case .call: callSeconds = 0; muted = false; speaker = false
        case .timer: timerLeft = timerTotal; timerPaused = false; timerDone = false
        case .camera: cameraSeconds = 0
        case .recording: recordSeconds = 0; recordPaused = false
        case .meeting: meetingLeft = 300
        case .download: download = 0.04; downloadPaused = false; downloadDone = false
        default: break
        }
    }

    /// Advances the activity on the island by `dt` seconds of (possibly slowed) time.
    mutating func advance(_ id: ActivityID, _ dt: Double, random: () -> Double) {
        switch id {
        case .call: callSeconds += dt
        case .camera: cameraSeconds += dt
        case .timer: if !timerPaused { timerLeft = max(0, timerLeft - dt) }
        case .recording: if !recordPaused { recordSeconds += dt }
        case .meeting: meetingLeft = max(0, meetingLeft - dt)
        case .download:
            // MB/s, a little jittery; 6× real time so it finishes in a demo.
            downloadSpeed = downloadPaused || download >= 1 ? 0 : 38 + random() * 9
            download = min(1, download + downloadSpeed * dt / (Self.downloadGB * 1024) * 6)
        default: break
        }
    }


    /// Activities whose content changes with time (they need the ticker).
    static func ticks(_ id: ActivityID) -> Bool {
        switch id {
        case .call, .timer, .recording, .meeting, .download, .camera, .recordCountdown, .match, .chess: true
        default: false
        }
    }
}

/// Clock text, "m:ss".
func clockText(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

// MARK: - Live data (P4)

/// The Mac's battery and power adapter (IOKit power sources).
struct PowerInfo: Equatable, Sendable {
    var level: Int
    var charging: Bool
    var onAdapter: Bool
    var watts: Int?
    /// Minutes until full, when macOS has worked it out.
    var minutesToFull: Int?
    /// Minutes until empty, on battery.
    var minutesToEmpty: Int? = nil

    /// The low-battery card's line: "Low Battery · about 1 h 10 min left".
    var lowStatus: String {
        guard let m = minutesToEmpty, m > 0 else { return "Low Battery" }
        return m >= 60 ? "Low Battery · about \(m / 60) h \(m % 60) min left" : "Low Battery · about \(m) min left"
    }

    /// The card's status line.
    var status: String {
        if charging, let m = minutesToFull, m > 0 {
            return m >= 60 ? "Charging · full in \(m / 60) h \(m % 60) min" : "Charging · full in \(m) min"
        }
        if charging { return "Charging" }
        if onAdapter { return level >= 100 ? "Fully charged" : "On power adapter · not charging" }
        return "On battery"
    }

    var adapter: String? { watts.map { "\($0) W power adapter" } }
}

/// The next calendar event, from EventKit.
struct MeetingInfo: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var joinURL: URL?
    /// Up to three attendees' initials, and how many more there are.
    var initials: [String]
    var more: Int

    /// The first video-call link in the event's URL, notes or location.
    static func joinLink(in texts: [String?]) -> URL? {
        let pattern = #"https://[^\s<>"']*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|facetime\.apple\.com|webex\.com|whereby\.com)[^\s<>"']*"#
        for text in texts.compactMap({ $0 }) {
            if let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }

    /// "MC" from "Marina Costa", "J" from "joe@example.com".
    static func initials(_ name: String) -> String {
        let base = name.split(separator: "@").first.map(String.init) ?? name
        let parts = base.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" }).prefix(2)
        return parts.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}

/// Connected AirPods and their battery (IOBluetooth's private getters, the way AirPane reads them).
struct PodsInfo: Equatable, Sendable {
    var name: String
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// One battery for both buds (some models report only this).
    var single: Int?

    /// The buds' level: the lower of the two, or the single one.
    var buds: Int? {
        switch (left, right) {
        case let (l?, r?): min(l, r)
        case let (l?, nil): l
        case let (nil, r?): r
        default: single
        }
    }
}

/// A file transfer into Downloads (Safari downloads, Finder copies), from the NSProgress it publishes.
struct TransferInfo: Equatable, Sendable {
    var name: String
    var totalBytes: Int64
    var doneBytes: Int64
    var bytesPerSecond: Double?
    var secondsLeft: Double?
    var paused = false
    var finished = false
    var url: URL?

    var fraction: Double { totalBytes > 0 ? min(Double(doneBytes) / Double(totalBytes), 1) : 0 }

    /// The file's extension for the icon ("ZIP"), at most four letters.
    var kind: String { String((name as NSString).pathExtension.uppercased().prefix(4)) }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// "1.1 GB of 3.4 GB · 42 MB/s", "3.4 GB · in Downloads", "… · paused".
    var progressLine: String {
        if finished { return "\(Self.bytes(totalBytes)) · in Downloads" }
        let of = totalBytes > 0 ? "\(Self.bytes(doneBytes)) of \(Self.bytes(totalBytes))" : Self.bytes(doneBytes)
        if paused { return of + " · paused" }
        if let s = bytesPerSecond, s > 0 { return of + " · \(Self.bytes(Int64(s)))/s" }
        return of
    }

    /// "About 1 min left", "15 s left", "Finished".
    var timeLeft: String {
        if finished { return "Finished" }
        if paused { return "Paused" }
        guard let left = secondsLeft, left.isFinite, left > 0 else { return "Working it out…" }
        if left > 50 { return left >= 3600 ? "About \(Int(left / 3600)) h left" : "About \(Int((left / 60).rounded(.up))) min left" }
        return "\(max(5, Int((left / 5).rounded(.up)) * 5)) s left"
    }
}
