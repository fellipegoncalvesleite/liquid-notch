import Foundation

/// What's playing on the Mac, from MediaRemote (through the adapter) or a player's own notifications.
public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// The app playing it (for a web player, the browser).
    public var bundleID: String?
    public var playing: Bool
    /// Seconds, when the player says.
    public var duration: Double?
    /// Elapsed seconds at `timestamp`. Elapsed time is computed from (base, timestamp, rate),
    /// never by counting ticks.
    public var elapsed: Double
    public var timestamp: Date
    public var rate: Double
    /// Encoded cover art (JPEG or PNG).
    public var artwork: Data?
    /// What the player says it is (MediaRemote's media type), when it says.
    public var kind: Kind?

    public enum Kind: Sendable, Equatable { case audio, video }

    public init(title: String, artist: String = "", album: String = "", bundleID: String? = nil, playing: Bool,
                duration: Double? = nil, elapsed: Double = 0, timestamp: Date = Date(), rate: Double = 1,
                artwork: Data? = nil, kind: Kind? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.bundleID = bundleID
        self.playing = playing
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.rate = rate
        self.artwork = artwork
        self.kind = kind
    }

    /// Music, for what follows the album (the desktop's colours and strip, the strip's beat, the lock screen's art
    /// wallpaper; owner, 11-07, after a movie in Chrome put Chrome's icon on the desktop: "shouldn't happen with anything
    /// that isn't music"): audio, unless it's a podcast or video app's; never video; with no type (Chrome sends none),
    /// only a known music player. A browser never counts without a type: its art can be a page's poster or the
    /// browser's own icon.
    public var isMusic: Bool {
        if let b = bundleID, Self.notMusic.contains(b) { return false }
        switch kind {
        case .video: return false
        case .audio: return true
        case nil: return bundleID.map(Self.musicPlayers.contains) ?? false
        }
    }

    public static let musicPlayers: Set<String> = [
        "com.apple.Music", "com.apple.iTunes", "com.spotify.client", "com.tidal.desktop", "com.deezer.deezer-desktop",
        "com.amazon.music", "com.apple.AppleMusicClassical", "com.colliderli.iina.music", "com.coppertino.Vox",
        "com.qobuz.QobuzDesktop", "com.soundcloud.desktop", "com.pandora.desktop", "fm.last.Scrobbler",
        "com.ytmdesktop.app", "com.github.th-ch.youtube-music", "app.cider.Cider", "sh.cider.electron",
    ]

    /// Apps that report audio that isn't music, or video.
    public static let notMusic: Set<String> = [
        "com.apple.podcasts", "com.apple.TV", "com.apple.QuickTimePlayerX", "com.colliderli.iina", "org.videolan.vlc",
        "com.firecore.infuse", "com.apple.iBooksX", "com.audible.mac", "com.netflix.Netflix", "tv.plex.desktop",
    ]

    /// Browsers report any tab with a sound or video element, titled after the page (Gmail's "Caixa de entrada"
    /// stayed on the island, 11-01). Real web players (YouTube, YouTube Music, Spotify) send an artist or a
    /// cover, so a browser item without either isn't media.
    public var isMedia: Bool {
        guard let b = bundleID, Self.browsers.contains(b) else { return true }
        return !artist.isEmpty || artwork != nil
    }

    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.Opera",
        "com.brave.Browser", "com.vivaldi.Vivaldi",
    ]

    /// The song, for telling a track change from a progress update.
    public var identity: String { [title, artist, album].joined(separator: "\u{1F}") }

    /// Whether this report only re-stamps `earlier`: the same song, still playing at the same rate, the same elapsed
    /// with a later timestamp. Spotify reports a seek, a skip or a resume at once and again ~1.1 s later this way (the
    /// owner's log, 11-07); following the repeat put the lyrics ~1.1 s behind the music.
    public func restamps(_ earlier: NowPlaying) -> Bool {
        identity == earlier.identity && playing && earlier.playing && rate == earlier.rate
            && abs(elapsed - earlier.elapsed) < 0.005 && timestamp > earlier.timestamp
    }

    /// The elapsed time now: advances at `rate` while playing, never past the duration.
    public func elapsed(at now: Date) -> Double {
        var e = elapsed
        if playing { e += now.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        if let d = duration, d > 0 { e = min(e, d) }
        return max(e, 0)
    }
}

/// Transport commands, numbered as MediaRemote's `MRMediaRemoteCommand` (what the adapter's `send` takes).
public enum MediaCommand: Int, Sendable {
    case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5
}
