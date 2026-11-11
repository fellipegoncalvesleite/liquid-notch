import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    // Offscreen render of the scripted transitions to PNG contact sheets; no windows.
    let dir = CommandLine.arguments.dropFirst(i + 1).first ?? "snapshots"
    MainActor.assumeIsolated { SnapshotRunner.run(outputDirectory: dir) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
// Updates (1.1): only from a built app, never a bare `swift run` binary, which has no bundle to replace.
if Bundle.main.bundleURL.pathExtension == "app" { MainActor.assumeIsolated { Updates.shared.start() } }
app.delegate = delegate
app.run()
