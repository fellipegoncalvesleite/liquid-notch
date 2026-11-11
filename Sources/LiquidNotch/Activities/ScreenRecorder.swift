import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Records the main display to a `.mov` (11-06 design): ScreenCaptureKit's stream with a recording output (macOS 15+),
/// Liquid Notch's own windows left out so the island isn't in the video. No sound. Needs the Screen Recording
/// permission, asked in the setup window.
@MainActor
final class ScreenRecorder: NSObject, ScreenRecording {
    enum Failure: Error { case noDisplay, notRecording }

    private var stream: SCStream?
    private var url: URL?
    private var finished: CheckedContinuation<URL, Error>?

    var canRecord: Bool { CGPreflightScreenCaptureAccess() }

    /// The whole display at its pixel size, 60 fps, in the encoder's own 4:2:0 format (BGRA moved about 2.6× the
    /// memory for the same picture) with a short frame queue. The notch was laggy and hard to click while recording
    /// (owner, 11-06): the window server and the encoder were busy enough that pointer moves reached it late.
    static func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 4
        config.showsCursor = true
        config.capturesAudio = false
        return config
    }

    func start(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw Failure.noDisplay }
        let ours = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        let scale = Double(filter.pointPixelScale)
        let config = Self.configuration(width: Int(Double(display.width) * scale), height: Int(Double(display.height) * scale))
        let out = SCRecordingOutputConfiguration()
        out.outputURL = url
        out.outputFileType = .mov
        out.videoCodecType = .hevc
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: out, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        self.url = url
    }

    func stop() async throws -> URL {
        guard let stream else { throw Failure.notRecording }
        return try await withCheckedThrowingContinuation { c in
            finished = c
            Task { try? await stream.stopCapture() }   // the output finishes the file, then says so below
        }
    }

    private func finish(_ error: Error?) {
        guard let c = finished else { return }
        finished = nil
        let url = self.url
        stream = nil
        self.url = nil
        if let error { c.resume(throwing: error) } else if let url { c.resume(returning: url) } else { c.resume(throwing: Failure.notRecording) }
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in self.finish(error) }
    }
}
