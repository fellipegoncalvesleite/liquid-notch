import CoreGraphics
import Foundation
import XCTest
@testable import NowPlaying

final class NowPlayingTests: XCTestCase {
    private let full = """
    {"type":"data","diff":false,"payload":{"title":"Night Ferry","artist":"The Low Tides","album":"Harbour",\
    "bundleIdentifier":"com.apple.Music","playing":true,"durationMicros":251000000,"elapsedTimeMicros":12500000,\
    "timestampEpochMicros":1790000000000000,"playbackRate":1,"processIdentifier":42}}
    """

    func testFullPayload() throws {
        var s = AdapterStream()
        guard case .nowPlaying(let np?) = s.consume(full) else { return XCTFail("no state") }
        XCTAssertEqual(np.title, "Night Ferry")
        XCTAssertEqual(np.artist, "The Low Tides")
        XCTAssertEqual(np.bundleID, "com.apple.Music")
        XCTAssertTrue(np.playing)
        XCTAssertEqual(np.duration, 251)
        XCTAssertEqual(np.elapsed, 12.5)
        XCTAssertEqual(np.timestamp.timeIntervalSince1970, 1_790_000_000, accuracy: 1e-6)
    }

    func testDiffMergesIntoTheSameItem() {
        var s = AdapterStream()
        _ = s.consume(full)
        let pause = #"{"type":"data","diff":true,"payload":{"playing":false,"elapsedTimeMicros":20000000}}"#
        guard case .nowPlaying(let np?) = s.consume(pause) else { return XCTFail("no state") }
        XCTAssertFalse(np.playing)
        XCTAssertEqual(np.elapsed, 20)
        XCTAssertEqual(np.title, "Night Ferry")           // kept from the full payload
        let drop = #"{"type":"data","diff":true,"payload":{"album":null}}"#
        guard case .nowPlaying(let np2?) = s.consume(drop) else { return XCTFail("no state") }
        XCTAssertEqual(np2.album, "")
    }

    func testEmptyPayloadIsNothingPlaying() {
        var s = AdapterStream()
        _ = s.consume(full)
        XCTAssertEqual(s.consume(#"{"type":"data","diff":false,"payload":{}}"#), .nowPlaying(nil))
        XCTAssertEqual(s.consume("not json"), .ignored)
        XCTAssertEqual(s.consume(#"{"type":"error"}"#), .ignored)
    }

    func testWebPlayerReportsTheBrowser() {
        var s = AdapterStream()
        let line = #"{"type":"data","diff":false,"payload":{"title":"Clip","playing":true,"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari"}}"#
        guard case .nowPlaying(let np?) = s.consume(line) else { return XCTFail("no state") }
        XCTAssertEqual(np.bundleID, "com.apple.Safari")
    }

    func testArtworkDecodes() {
        var s = AdapterStream()
        let b64 = Data([1, 2, 3]).base64EncodedString()
        let line = #"{"type":"data","diff":false,"payload":{"title":"A","playing":true,"artworkData":"\#(b64)"}}"#
        guard case .nowPlaying(let np?) = s.consume(line) else { return XCTFail("no state") }
        XCTAssertEqual(np.artwork, Data([1, 2, 3]))
    }

    // Elapsed time follows (base, timestamp, rate), stops while paused, never passes the end.
    func testElapsedFromTimestamp() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var np = NowPlaying(title: "A", playing: true, duration: 100, elapsed: 10, timestamp: t0, rate: 1)
        XCTAssertEqual(np.elapsed(at: t0.addingTimeInterval(5)), 15, accuracy: 1e-9)
        np.rate = 2
        XCTAssertEqual(np.elapsed(at: t0.addingTimeInterval(5)), 20, accuracy: 1e-9)
        XCTAssertEqual(np.elapsed(at: t0.addingTimeInterval(500)), 100, accuracy: 1e-9)
        np.playing = false
        XCTAssertEqual(np.elapsed(at: t0.addingTimeInterval(5)), 10, accuracy: 1e-9)
    }

    func testMusicAndSpotifyNotifications() {
        let now = Date(timeIntervalSince1970: 50)
        let music = PlayerNotifications.parse(name: PlayerNotifications.music, userInfo: [
            "Name": "Glass Harbor", "Artist": "Mirela Sun", "Album": "Tides", "Player State": "Playing",
            "Total Time": 204_000,
        ], now: now)
        XCTAssertEqual(music??.title, "Glass Harbor")
        XCTAssertEqual(music??.duration, 204)
        XCTAssertEqual(music??.bundleID, "com.apple.Music")
        XCTAssertEqual(music??.playing, true)

        let spotify = PlayerNotifications.parse(name: PlayerNotifications.spotify, userInfo: [
            "Name": "Paper Moons", "Artist": "Ana Vell", "Player State": "Paused", "Duration": 188_000,
            "Playback Position": 33.5,
        ], now: now)
        XCTAssertEqual(spotify??.elapsed, 33.5)
        XCTAssertEqual(spotify??.playing, false)

        let stopped = PlayerNotifications.parse(name: PlayerNotifications.music, userInfo: ["Player State": "Stopped"])
        XCTAssertTrue(stopped.map { $0 == nil } ?? false, "a stopped player is .some(nil)")
        XCTAssertTrue(PlayerNotifications.parse(name: "com.example.other", userInfo: [:]) == nil)
    }

    func testScripts() {
        XCTAssertEqual(PlayerNotifications.script(.togglePlayPause, bundleID: "com.apple.Music"),
                       "tell application \"Music\" to playpause")
        XCTAssertEqual(PlayerNotifications.script(.next, bundleID: "com.spotify.client"),
                       "tell application \"Spotify\" to next track")
        XCTAssertNil(PlayerNotifications.script(.next, bundleID: "com.apple.Safari"))
    }

    // The bars take the cover's vivid colour, lifted for black; a grey cover gives none.
    func testAlbumColor() throws {
        func image(_ fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
            let n = 32
            var px = [UInt8](repeating: 255, count: n * n * 4)
            for y in 0..<n { for x in 0..<n {
                let (r, g, b) = fill(x, y)
                let i = (y * n + x) * 4
                px[i] = r; px[i + 1] = g; px[i + 2] = b
            } }
            let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        // Mostly dark grey with a red half: red wins, lifted to 0.85+.
        let red = AlbumColor.hex(from: image { x, _ in x < 16 ? (200, 30, 30) : (40, 40, 40) })
        XCTAssertNotNil(red)
        let v = UInt32(red!.dropFirst(), radix: 16)!
        XCTAssertGreaterThanOrEqual(Double((v >> 16) & 0xFF) / 255, 0.84)
        XCTAssertLessThan(Double((v >> 8) & 0xFF) / 255, 0.3)
        XCTAssertNil(AlbumColor.hex(from: image { _, _ in (128, 128, 128) }))
    }

    // A browser tab titled after the page, with no artist or cover, isn't media; a web player is.
    func testBrowserPagesAreNotMedia() {
        XCTAssertFalse(NowPlaying(title: "Caixa de entrada", bundleID: "com.google.Chrome", playing: false).isMedia)
        XCTAssertTrue(NowPlaying(title: "Song", artist: "Band", bundleID: "com.google.Chrome", playing: true).isMedia)
        XCTAssertTrue(NowPlaying(title: "Song", bundleID: "com.google.Chrome", playing: true, artwork: Data([1])).isMedia)
        XCTAssertTrue(NowPlaying(title: "Podcast", bundleID: "com.apple.Podcasts", playing: true).isMedia)
    }

    // MUSIC1 (owner, 11-07, after a movie in Chrome put Chrome's icon on the desktop: "shouldn't happen with anything
    // that isn't music"): audio is music, video never; with no type only a known music player; a browser never counts
    // without a type, and podcast or video apps never do.
    func testMUSIC1OnlyMusicFollowsTheAlbum() {
        func np(_ bundle: String?, _ kind: NowPlaying.Kind?, art: Bool = true) -> NowPlaying {
            NowPlaying(title: "T", artist: "A", bundleID: bundle, playing: true, artwork: art ? Data([1]) : nil, kind: kind)
        }
        XCTAssertFalse(np("com.google.Chrome", nil).isMusic, "a movie in Chrome (no type, the page's art)")
        XCTAssertFalse(np("com.google.Chrome", .video).isMusic)
        XCTAssertTrue(np("com.google.Chrome", .audio).isMusic, "a web player that says audio")
        XCTAssertTrue(np("com.spotify.client", nil).isMusic)
        XCTAssertTrue(np("com.apple.Music", nil).isMusic)
        XCTAssertFalse(np("com.apple.Music", .video).isMusic, "a music video")
        XCTAssertFalse(np("com.apple.podcasts", .audio).isMusic)
        XCTAssertFalse(np("com.apple.TV", nil).isMusic)
        XCTAssertFalse(np(nil, nil).isMusic)
    }

    // MUSIC2: the adapter's media type is read (MediaRemote's string or MPNowPlayingInfoMediaType's number) and kept
    // through diffs.
    func testMUSIC2TheMediaTypeIsRead() {
        XCTAssertEqual(AdapterStream.kind("kMRMediaRemoteNowPlayingInfoTypeAudio"), .audio)
        XCTAssertEqual(AdapterStream.kind("kMRMediaRemoteNowPlayingInfoTypeVideo"), .video)
        XCTAssertEqual(AdapterStream.kind(NSNumber(value: 1)), .audio)
        XCTAssertEqual(AdapterStream.kind(NSNumber(value: 2)), .video)
        XCTAssertNil(AdapterStream.kind(nil))
        var s = AdapterStream()
        _ = s.consume("""
        {"type":"data","diff":false,"payload":{"title":"Clip","bundleIdentifier":"com.google.Chrome","playing":true,\
        "mediaType":"kMRMediaRemoteNowPlayingInfoTypeVideo"}}
        """)
        guard case .nowPlaying(let np?) = s.consume(#"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":5000000}}"#)
        else { return XCTFail("no state") }
        XCTAssertEqual(np.kind, .video)
        XCTAssertFalse(np.isMusic)
    }

    // MUSIC-OPEN (v1, 11-11): the focused player's button reveals Music's current track and brings Music forward; other
    // players get no script (Spotify opens its track link, the rest just come to the front).
    func testMusicOpensTheSong() throws {
        let script = try XCTUnwrap(NowPlayingMonitor.revealScript(for: PlayerNotifications.musicBundle))
        XCTAssertTrue(script.contains("reveal current track"))
        XCTAssertTrue(script.contains("activate"))
        XCTAssertNil(NowPlayingMonitor.revealScript(for: PlayerNotifications.spotifyBundle))
        XCTAssertNil(NowPlayingMonitor.revealScript(for: "com.google.Chrome"))
    }

    // MEDIA2 (11-11): a song and a video at once: the song is the main player, the video the second (it waits in a
    // ball; while its own tab is in front it leaves). A paused reported player gives way to the one playing.
    func testASongAndAVideoAtOnce() {
        let video = NowPlaying(title: "Chess", bundleID: "com.google.Chrome", playing: true, kind: .video)
        let song = NowPlaying(title: "Song", artist: "Artist", bundleID: "com.spotify.client", playing: true, kind: .audio)
        var s = NowPlayingMonitor.split(primary: video, alternate: song)
        XCTAssertEqual(s.main?.title, "Song"); XCTAssertEqual(s.second?.title, "Chess")
        var paused = video; paused.playing = false
        s = NowPlayingMonitor.split(primary: paused, alternate: song)
        XCTAssertEqual(s.main?.title, "Song"); XCTAssertNil(s.second)
        var stopped = song; stopped.playing = false
        s = NowPlayingMonitor.split(primary: video, alternate: stopped)
        XCTAssertEqual(s.main?.title, "Chess"); XCTAssertNil(s.second)
        XCTAssertNil(NowPlayingMonitor.split(primary: nil, alternate: song).main, "the adapter says nothing plays")
    }

    // MARK: Shuffle and repeat

    func testShuffleAndRepeatFromTheStream() {
        var s = AdapterStream()
        _ = s.consume(full)
        let modes = #"{"type":"data","diff":true,"payload":{"shuffleMode":3,"repeatMode":2}}"#
        guard case .nowPlaying(let np?) = s.consume(modes) else { return XCTFail("no state") }
        XCTAssertEqual(np.shuffle, true)
        XCTAssertEqual(np.repeatMode, .one)
        let off = #"{"type":"data","diff":true,"payload":{"shuffleMode":1,"repeatMode":1}}"#
        guard case .nowPlaying(let np2?) = s.consume(off) else { return XCTFail("no state") }
        XCTAssertEqual(np2.shuffle, false)
        XCTAssertEqual(np2.repeatMode, .off)
    }

    func testModesMissingAreUnknown() {
        var s = AdapterStream()
        guard case .nowPlaying(let np?) = s.consume(full) else { return XCTFail("no state") }
        XCTAssertNil(np.shuffle)
        XCTAssertNil(np.repeatMode)
    }

    func testRepeatCyclesLikeMusic() {
        XCTAssertEqual(NowPlaying.RepeatMode.off.next, .all)
        XCTAssertEqual(NowPlaying.RepeatMode.all.next, .one)
        XCTAssertEqual(NowPlaying.RepeatMode.one.next, .off)
    }

    func testModesScriptsAndParsing() {
        XCTAssertEqual(PlayerNotifications.shuffleScript(true, bundleID: "com.spotify.client"),
                       "tell application \"Spotify\" to set shuffling to true")
        XCTAssertEqual(PlayerNotifications.repeatScript(.one, bundleID: "com.apple.Music"),
                       "tell application \"Music\" to set song repeat to one")
        XCTAssertEqual(PlayerNotifications.repeatScript(.one, bundleID: "com.spotify.client"),
                       "tell application \"Spotify\" to set repeating to true")
        XCTAssertNil(PlayerNotifications.shuffleScript(true, bundleID: "com.google.Chrome"))
        let music = PlayerNotifications.parseModes("true,all\n")
        XCTAssertEqual(music.shuffle, true); XCTAssertEqual(music.repeatMode, .all)
        let spotify = PlayerNotifications.parseModes("false,false")
        XCTAssertEqual(spotify.shuffle, false); XCTAssertEqual(spotify.repeatMode, .off)
        XCTAssertNil(PlayerNotifications.parseModes("").shuffle)
    }
}
