import AppKit
import OSLog

private let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "activities")

/// File transfers into Downloads, from the NSProgress objects Safari and Finder publish for them
/// (`Progress.addSubscriber(forFileURL:)`). Follows the most recent one; updates at most 4 times a second.
@MainActor
final class TransferWatcher {
    var onStart: ((TransferInfo) -> Void)?
    var onUpdate: ((TransferInfo) -> Void)?
    /// The transfer went away; `finished` tells a completed one from a cancelled one.
    var onEnd: ((TransferInfo, _ finished: Bool) -> Void)?

    private var token: Any?
    private var current: Progress?
    private var observation: NSKeyValueObservation?
    private var info: TransferInfo?
    private var lastPublish = Date.distantPast
    private var lastSample: (date: Date, bytes: Int64)?
    private var speed: Double?

    static let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    func start() {
        token = Progress.addSubscriber(forFileURL: Self.downloads) { [weak self] progress in
            let ref = ProgressRef(progress)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.attach(ref.progress) } }
            return {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.detach(ref.progress) } }
            }
        }
    }

    func pauseOrResume() {
        guard let p = current else { return }
        if p.isPaused { p.resume() } else if p.isPausable { p.pause() }
        refresh(force: true)
    }

    func showInFinder() {
        guard let url = info?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func attach(_ p: Progress) {
        guard p.kind == .file || Self.fileURL(p) != nil else { return }
        current = p
        info = nil
        lastSample = nil
        speed = nil
        observation = p.observe(\.completedUnitCount, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh(force: false) } }
        }
        refresh(force: true)
        if let info {
            log.notice("transfer: started (type \(info.kind, privacy: .public))")
            onStart?(info)
        }
    }

    private func detach(_ p: Progress) {
        guard p === current, var last = info else { return }
        let finished = p.isFinished || p.completedUnitCount >= p.totalUnitCount && p.totalUnitCount > 0
        last.finished = finished
        if finished, let url = last.url, url.pathExtension == "download" {
            last.url = url.deletingPathExtension()
        }
        log.notice("transfer: ended (finished \(finished, privacy: .public), type \(last.kind, privacy: .public))")
        observation = nil
        current = nil
        info = nil
        onEnd?(last, finished)
    }

    /// The file the progress is for. A subscriber's copy carries it in `userInfo` in a form `fileURL`
    /// doesn't return (seen on macOS 27), so read the key directly.
    private static func fileURL(_ p: Progress) -> URL? {
        if let u = p.fileURL { return u }
        let raw = p.userInfo[.fileURLKey]
        if let u = raw as? URL { return u }
        if let u = raw as? NSURL { return u as URL }
        if let path = raw as? String { return URL(fileURLWithPath: path) }
        return nil
    }

    private func refresh(force: Bool) {
        guard let p = current else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastPublish) < 0.25 { return }
        lastPublish = now
        // Speed: the publisher's own throughput, else a smoothed measure of our own.
        if let prev = lastSample, now.timeIntervalSince(prev.date) > 0.2 {
            let measured = Double(p.completedUnitCount - prev.bytes) / now.timeIntervalSince(prev.date)
            if measured >= 0 { speed = speed.map { $0 * 0.7 + measured * 0.3 } ?? measured }
            lastSample = (now, p.completedUnitCount)
        } else if lastSample == nil {
            lastSample = (now, p.completedUnitCount)
        }
        let bps = p.throughput.map(Double.init) ?? speed
        let left = p.estimatedTimeRemaining ?? bps.flatMap { b in
            b > 0 && p.totalUnitCount > 0 ? Double(p.totalUnitCount - p.completedUnitCount) / b : nil
        }
        let url = Self.fileURL(p)
        var name = url?.lastPathComponent ?? "Download"
        if name.hasSuffix(".download") { name = String(name.dropLast(".download".count)) }
        let next = TransferInfo(name: name, totalBytes: max(p.totalUnitCount, 0), doneBytes: max(p.completedUnitCount, 0),
                                bytesPerSecond: bps, secondsLeft: left, paused: p.isPaused,
                                finished: p.isFinished, url: url)
        let started = info == nil
        info = next
        if !started { onUpdate?(next) }
    }
}

/// Carries a Progress across the publishing handler's queue hop (it's thread-safe).
private struct ProgressRef: @unchecked Sendable {
    let progress: Progress
    init(_ p: Progress) { progress = p }
}
