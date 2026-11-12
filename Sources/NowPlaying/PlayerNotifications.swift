import Foundation

/// The fallback when the adapter can't run: Music and Spotify post their state as distributed
/// notifications (no permission needed). Music's carries no position; Spotify's does.
public enum PlayerNotifications {
    public static let music = "com.apple.Music.playerInfo"
    public static let spotify = "com.spotify.client.PlaybackStateChanged"
    public static let names = [music, spotify]

    public static let musicBundle = "com.apple.Music"
    public static let spotifyBundle = "com.spotify.client"

    /// The state a notification describes: `.some(nil)` when the player stopped, nil when it isn't one of ours.
    public static func parse(name: String, userInfo: [AnyHashable: Any], now: Date = Date()) -> NowPlaying?? {
        let bundle: String
        switch name {
        case music: bundle = musicBundle
        case spotify: bundle = spotifyBundle
        default: return nil
        }
        let state = userInfo["Player State"] as? String ?? ""
        guard state == "Playing" || state == "Paused" else { return .some(nil) }
        let title = userInfo["Name"] as? String ?? ""
        guard !title.isEmpty else { return .some(nil) }
        let ms = (userInfo[name == music ? "Total Time" : "Duration"] as? NSNumber)?.doubleValue
        let position = (userInfo["Playback Position"] as? NSNumber)?.doubleValue
        return .some(NowPlaying(
            title: title,
            artist: userInfo["Artist"] as? String ?? "",
            album: userInfo["Album"] as? String ?? "",
            bundleID: bundle,
            playing: state == "Playing",
            duration: ms.flatMap { $0 > 0 ? $0 / 1000 : nil },
            elapsed: position ?? 0,
            timestamp: now))
    }

    /// AppleScript for a command, for players that take it (needs the Automation permission).
    public static func script(_ command: MediaCommand, bundleID: String) -> String? {
        let app: String
        switch bundleID {
        case musicBundle: app = "Music"
        case spotifyBundle: app = "Spotify"
        default: return nil
        }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        return "tell application \"\(app)\" to \(verb)"
    }

    /// AppleScript that moves the player to `seconds`.
    public static func seekScript(seconds: Double, bundleID: String) -> String? {
        let app: String
        switch bundleID {
        case musicBundle: app = "Music"
        case spotifyBundle: app = "Spotify"
        default: return nil
        }
        return "tell application \"\(app)\" to set player position to \(String(format: "%.2f", seconds))"
    }

    /// AppleScript that turns shuffle on or off.
    public static func shuffleScript(_ on: Bool, bundleID: String) -> String? {
        switch bundleID {
        case musicBundle: "tell application \"Music\" to set shuffle enabled to \(on)"
        case spotifyBundle: "tell application \"Spotify\" to set shuffling to \(on)"
        default: nil
        }
    }

    /// AppleScript that sets the repeat mode. Spotify's is on or off (its "one" isn't scriptable): one and all both
    /// turn it on.
    public static func repeatScript(_ mode: NowPlaying.RepeatMode, bundleID: String) -> String? {
        switch bundleID {
        case musicBundle:
            let m = switch mode { case .off: "off"; case .one: "one"; case .all: "all" }
            return "tell application \"Music\" to set song repeat to \(m)"
        case spotifyBundle: return "tell application \"Spotify\" to set repeating to \(mode != .off)"
        default: return nil
        }
    }

    /// AppleScript that answers "shuffle,repeat" (`true,all`, Spotify's repeat as `true`/`false`).
    public static func modesScript(bundleID: String) -> String? {
        switch bundleID {
        case musicBundle: "tell application \"Music\" to (shuffle enabled as text) & \",\" & (song repeat as text)"
        case spotifyBundle: "tell application \"Spotify\" to (shuffling as text) & \",\" & (repeating as text)"
        default: nil
        }
    }

    /// Reads `modesScript`'s answer.
    public static func parseModes(_ out: String) -> (shuffle: Bool?, repeatMode: NowPlaying.RepeatMode?) {
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: ",").map(String.init)
        guard parts.count == 2 else { return (nil, nil) }
        let shuffle: Bool? = parts[0] == "true" ? true : parts[0] == "false" ? false : nil
        let repeatMode: NowPlaying.RepeatMode? = switch parts[1] {
        case "off", "false": .off
        case "one": .one
        case "all", "true": .all
        default: nil
        }
        return (shuffle, repeatMode)
    }

    /// AppleScript that answers the player's position in seconds.
    public static func positionScript(bundleID: String) -> String? {
        switch bundleID {
        case musicBundle: "tell application \"Music\" to player position"
        case spotifyBundle: "tell application \"Spotify\" to player position"
        default: nil
        }
    }
}
