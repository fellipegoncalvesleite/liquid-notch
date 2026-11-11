// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiquidNotch",
    platforms: [.macOS(.v15)],
    targets: [
        // The island's state model: who holds the ears, the bubble and the card, from the
        // activities and where you are on the Mac. Pure (no AppKit), so it can be unit-tested
        // and event traces replayed.
        .target(
            name: "IslandCore",
            path: "Sources/IslandCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // What's playing: runs the vendored mediaremote-adapter (the app's only private-API use,
        // in Vendor/) and falls back to the players' own notifications. No AppKit.
        .target(
            name: "NowPlaying",
            path: "Sources/NowPlaying",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LiquidNotch",
            dependencies: ["IslandCore", "NowPlaying"],
            path: "Sources/LiquidNotch",
            // The shader is compiled at runtime from source (see LiquidRenderer),
            // so SwiftPM must not try to build it.
            exclude: ["Render/LiquidShape.metal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IslandCoreTests",
            dependencies: ["IslandCore"],
            path: "Tests/IslandCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NowPlayingTests",
            dependencies: ["NowPlaying"],
            path: "Tests/NowPlayingTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LiquidNotchTests",
            dependencies: ["LiquidNotch", "IslandCore"],
            path: "Tests/LiquidNotchTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
