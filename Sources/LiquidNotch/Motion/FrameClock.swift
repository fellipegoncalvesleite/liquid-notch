import AppKit
import QuartzCore

/// Drives the animator from the display's vsync, and only while something moves.
///
/// The link is paused the moment the animator reports rest, so a still notch costs
/// no CPU at all; any retarget calls `wake()` to start it again.
@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let tick: (Double) -> Bool

    /// Multiplies real time. Below 1 is slow motion, for judging the droplet.
    var timeScale: Double = 1

    /// `tick` receives the elapsed seconds and returns whether to keep running.
    init(tick: @escaping (Double) -> Bool) {
        self.tick = tick
    }

    /// Attaches to the display `view` is on. Call again after the view changes screens.
    func attach(to view: NSView) {
        link?.invalidate()
        let l = view.displayLink(target: self, selector: #selector(onFrame(_:)))
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = nil
    }

    func wake() {
        guard let link, link.isPaused else { return }
        lastTimestamp = nil
        link.isPaused = false
    }

    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        // Step to the time this frame will be shown, not the time we were called.
        let now = link.targetTimestamp
        let dt = lastTimestamp.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = now
        // A long stall (sleep, debugger) must not teleport the springs.
        let step = min(max(dt, 0), 1.0 / 30.0) * timeScale
        if !tick(step) {
            link.isPaused = true
            lastTimestamp = nil
        }
    }
}
