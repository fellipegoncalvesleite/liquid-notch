import Foundation

/// Reads the adapter's `stream --micros` output: one JSON object per line,
/// `{"type": "data", "diff": Bool, "payload": {…}}`. A diff payload carries only the keys that
/// changed (null = removed) for the same item; a full payload replaces everything. An empty
/// payload means nothing is playing.
public struct AdapterStream {
    public enum Update: Equatable, Sendable {
        /// The state after this line (nil: nothing playing).
        case nowPlaying(NowPlaying?)
        /// Not a data line.
        case ignored
    }

    private var payload: [String: Any] = [:]

    public init() {}

    public mutating func consume(_ line: String) -> Update {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "data" else { return .ignored }
        let incoming = object["payload"] as? [String: Any] ?? [:]
        if object["diff"] as? Bool == true {
            for (k, v) in incoming {
                if v is NSNull { payload.removeValue(forKey: k) } else { payload[k] = v }
            }
        } else {
            payload = incoming
        }
        return .nowPlaying(Self.nowPlaying(payload))
    }

    static func nowPlaying(_ p: [String: Any]) -> NowPlaying? {
        let title = p["title"] as? String ?? ""
        let artist = p["artist"] as? String ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        let micros = { (key: String) -> Double? in (p[key] as? NSNumber).map { $0.doubleValue / 1_000_000 } }
        let timestamp = micros("timestampEpochMicros").map { Date(timeIntervalSince1970: $0) } ?? Date()
        let rate = (p["playbackRate"] as? NSNumber)?.doubleValue ?? 1
        // A web player reports the browser's helper; the parent is the app you see.
        let bundle = p["parentApplicationBundleIdentifier"] as? String ?? p["bundleIdentifier"] as? String
        return NowPlaying(
            title: title.isEmpty ? artist : title,
            artist: title.isEmpty ? "" : artist,
            album: p["album"] as? String ?? "",
            bundleID: bundle,
            playing: (p["playing"] as? Bool) ?? (rate > 0),
            duration: micros("durationMicros").flatMap { $0 > 0 ? $0 : nil },
            elapsed: micros("elapsedTimeMicros") ?? 0,
            timestamp: timestamp,
            rate: rate > 0 ? rate : 1,
            artwork: (p["artworkData"] as? String).flatMap { Data(base64Encoded: $0) },
            kind: kind(p["mediaType"]),
            shuffle: shuffle(p["shuffleMode"]),
            repeatMode: repeatMode(p["repeatMode"]))
    }

    /// MediaRemote's shuffle mode: 1 off, 2 albums, 3 tracks (0 or missing: the player doesn't say).
    static func shuffle(_ value: Any?) -> Bool? {
        guard let n = (value as? NSNumber)?.intValue, n > 0 else { return nil }
        return n > 1
    }

    /// MediaRemote's repeat mode: 1 off, 2 one, 3 all (0 or missing: the player doesn't say).
    static func repeatMode(_ value: Any?) -> NowPlaying.RepeatMode? {
        (value as? NSNumber).flatMap { NowPlaying.RepeatMode(rawValue: $0.intValue) }
    }

    /// MediaRemote's media type: `kMRMediaRemoteNowPlayingInfoTypeAudio` / `…Video` (or MPNowPlayingInfoMediaType's
    /// 1 audio, 2 video); anything else is unknown. Chrome sends none.
    static func kind(_ value: Any?) -> NowPlaying.Kind? {
        if let n = value as? NSNumber { return n.intValue == 1 ? .audio : n.intValue == 2 ? .video : nil }
        guard let s = (value as? String)?.lowercased() else { return nil }
        if s.contains("video") { return .video }
        if s.contains("audio") || s.contains("music") { return .audio }
        return nil
    }
}
