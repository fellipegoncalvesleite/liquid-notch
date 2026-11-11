import AppKit
import CoreMedia
import OSLog
import ScreenCaptureKit

/// Watching a video in the island (owner, 11-11: "if it's a video, click on its card and you can watch it from the
/// island"): a live mirror of the video in its browser window, through ScreenCaptureKit (the Screen Recording permission
/// Record already asks for). The video keeps playing in its tab, with its own sound; only the picture comes here.
///
/// Where the video sits in the window isn't known, so the first half second is watched small and the part that moves is
/// taken as the video (16:9 around it); then the stream crops to it at full resolution. Nothing moving (paused): the
/// whole window. The browser only paints the tab in front of its window: on another tab the mirror says so.
@MainActor @Observable
final class VideoMirror {
    enum State: Equatable { case idle, finding, showing, needsPermission, notFound, otherTab }
    private(set) var state: State = .idle
    /// The video's shape once found (width over height), for the view's fit.
    private(set) var aspect = 16.0 / 9
    /// Frames land here (the view hosts this layer).
    @ObservationIgnored let layer: CALayer = {
        let l = CALayer()
        l.contentsGravity = .resizeAspect
        l.backgroundColor = NSColor.black.cgColor
        return l
    }()

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: Output?
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "video")

    func start(app: String, title: String) {
        stop()
        guard CGPreflightScreenCaptureAccess() else { state = .needsPermission; return }
        state = .finding
        task = Task { [weak self] in await self?.run(app: app, title: title) }
    }

    func stop() {
        task?.cancel(); task = nil
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil; output = nil
        layer.contents = nil
        state = .idle
    }

    private func run(app: String, title: String) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            state = .notFound; return
        }
        let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == app && $0.frame.width > 200 && $0.windowLayer == 0 }
        let key = String(title.prefix(40))
        let window = windows.first { ($0.title ?? "").localizedCaseInsensitiveContains(key) }
        guard let window = window ?? windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            state = .notFound; return
        }
        if !key.isEmpty, !(window.title ?? "").localizedCaseInsensitiveContains(key) {
            Self.log.notice("video: its tab isn't the one in front of its window")
            state = .otherTab
            return
        }
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 4
        // Small first, to find the part that moves.
        let small = 480.0, k = small / window.frame.width
        config.width = Int(small); config.height = Int(window.frame.height * k)
        let out = Output(cells: (32, 18))
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
        } catch {
            Self.log.notice("video: capture failed (\(error.localizedDescription, privacy: .public))")
            state = .notFound; return
        }
        self.stream = stream; self.output = out
        out.onFrame = { [weak self] surface in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(surface) } }
        }
        try? await Task.sleep(for: .milliseconds(550))
        guard !Task.isCancelled else { return }
        // The moving part, in the window's points, made 16:9 around its middle.
        let found = out.movingBox().map { box -> CGRect in
            let r = CGRect(x: box.minX * window.frame.width, y: box.minY * window.frame.height,
                           width: box.width * window.frame.width, height: box.height * window.frame.height)
            return Self.sixteenNine(around: r, within: CGRect(origin: .zero, size: window.frame.size))
        }
        let crop = found ?? CGRect(origin: .zero, size: window.frame.size)
        Self.log.notice("video: \(found == nil ? "nothing moving, the whole window" : "found the video", privacy: .public) \(Int(crop.width))×\(Int(crop.height))")
        let full = SCStreamConfiguration()
        full.pixelFormat = kCVPixelFormatType_32BGRA
        full.showsCursor = false
        full.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        full.queueDepth = 4
        full.sourceRect = crop
        full.width = Int(min(crop.width * scale, 1280)); full.height = Int(Double(full.width) * crop.height / crop.width)
        out.finding = false
        try? await stream.updateConfiguration(full)
        aspect = crop.width / max(crop.height, 1)
        state = .showing
    }

    private func show(_ surface: IOSurface) {
        guard state == .showing || state == .finding else { return }
        if state == .finding { return }            // the small frames only feed the search
        layer.contents = surface
    }

    /// A 16:9 rectangle covering `r`, centred on it, kept inside `bounds`.
    nonisolated static func sixteenNine(around r: CGRect, within bounds: CGRect) -> CGRect {
        var w = r.width, h = r.height
        if w / max(h, 1) > 16.0 / 9 { h = w * 9 / 16 } else { w = h * 16 / 9 }
        w = min(w, bounds.width); h = min(h, bounds.height)
        var x = r.midX - w / 2, y = r.midY - h / 2
        x = min(max(x, bounds.minX), bounds.maxX - w); y = min(max(y, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Receives frames; while finding, adds up how much each cell of a coarse grid changes from frame to frame.
    final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
        var onFrame: ((IOSurface) -> Void)?
        var finding = true
        private let cells: (Int, Int)
        private var last: [Double]?
        private var motion: [Double]
        private let lock = NSLock()

        init(cells: (Int, Int)) { self.cells = cells; motion = Array(repeating: 0, count: cells.0 * cells.1) }

        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sample) else { return }
            if finding { measure(pb) }
            if let s = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() { onFrame?(s as IOSurface) }
        }

        private func measure(_ pb: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
            let p = base.assumingMemoryBound(to: UInt8.self)
            var lum = Array(repeating: 0.0, count: cells.0 * cells.1)
            for cy in 0..<cells.1 {
                for cx in 0..<cells.0 {
                    // A few samples per cell are enough to see change.
                    var sum = 0.0
                    for sy in 0..<3 { for sx in 0..<3 {
                        let x = min(w - 1, (cx * 3 + sx) * w / (cells.0 * 3)), y = min(h - 1, (cy * 3 + sy) * h / (cells.1 * 3))
                        let o = y * row + x * 4
                        sum += Double(p[o]) + Double(p[o + 1]) * 2 + Double(p[o + 2])
                    } }
                    lum[cy * cells.0 + cx] = sum
                }
            }
            lock.lock(); defer { lock.unlock() }
            if let last { for i in lum.indices { motion[i] += abs(lum[i] - last[i]) } }
            last = lum
        }

        /// The changing cells' bounding box, as fractions of the window (top-left origin); nil if nothing moves.
        func movingBox() -> CGRect? {
            lock.lock(); let m = motion; lock.unlock()
            guard let top = m.max(), top > 0 else { return nil }
            var minX = cells.0, minY = cells.1, maxX = -1, maxY = -1, count = 0
            for cy in 0..<cells.1 { for cx in 0..<cells.0 where m[cy * cells.0 + cx] > top * 0.2 {
                minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy); count += 1
            } }
            guard count >= 4 else { return nil }      // a blinking caret or a spinner isn't a video
            return CGRect(x: Double(minX) / Double(cells.0), y: Double(minY) / Double(cells.1),
                          width: Double(maxX - minX + 1) / Double(cells.0), height: Double(maxY - minY + 1) / Double(cells.1))
        }
    }
}
