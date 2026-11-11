import Foundation

/// Synced lyrics for the focused player (owner, 11-07: "double click the music island … a bigger screen with the lyrics").
/// From LRCLIB (lrclib.net: free, no key, community lyrics with timings): the song's title, artist and length go to
/// it, nothing else. Fetched only when the focused view opens, kept per song for the session.
struct LyricLine: Equatable, Sendable {
    let time: Double
    let text: String
}

struct Lyrics: Equatable, Sendable {
    /// The song they belong to ("artist|title").
    let key: String
    /// Timed lines (empty when only plain lyrics exist).
    let lines: [LyricLine]
    /// Plain lyrics, when there are no timings.
    let plain: [String]

    /// How early a line lights up, so it's lit as the voice lands (its glide takes a moment to show). It was 0.25 s; with
    /// the clock right and the output's own delay taken off (`IslandDirector.lyricsElapsed`), the lines ran ahead
    /// (owner, 11-07).
    static let lead = 0.1

    /// The line being sung at `elapsed`.
    func current(at elapsed: Double) -> Int? {
        lines.lastIndex { $0.time <= elapsed + Self.lead }
    }

    /// The line to show at `elapsed` when `shown` is showing: a player's clock steps back a little after a seek or a skip
    /// (Spotify reports the new place at once, then again ~1.2 s later when the sound really resumes; seen 11-07), so a
    /// step back of up to 1.5 s keeps the line instead of flicking back. A real seek back moves at once.
    func line(from shown: Int?, at elapsed: Double) -> Int? {
        let now = current(at: elapsed)
        if let shown, shown < lines.count, (now ?? -1) < shown, lines[shown].time - (elapsed + Self.lead) <= 1.5 { return shown }
        return now
    }
}

/// One LRCLIB entry, parsed.
struct LyricsEntry: Equatable, Sendable {
    let duration: Double?
    let lines: [LyricLine]
    let plain: [String]
}

enum LyricsSource {
    static func key(title: String, artist: String) -> String { "\(artist)|\(title)" }

    /// The exact match and the search together (LRCLIB keeps everyone's syncs), then the one they agree on (`best`).
    static func fetch(title: String, artist: String, album: String, duration: Double?) async -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
            + (album.isEmpty ? [] : [URLQueryItem(name: "album_name", value: album)])
            + (duration.map { [URLQueryItem(name: "duration", value: String(Int($0.rounded())))] } ?? [])
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        async let exact = json(c.url)
        async let found = json(s.url)
        let entries = ((await exact as? [String: Any]).map { [$0] } ?? []) + ((await found as? [[String: Any]]) ?? [])
        guard let e = best(entries.map(entry), duration: duration) else { return nil }
        return Lyrics(key: key(title: title, artist: artist), lines: e.lines, plain: e.lines.isEmpty ? e.plain : [])
    }

    private static func json(_ url: URL?) async -> Any? {
        guard let url, let (data, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func entry(_ j: [String: Any]) -> LyricsEntry {
        let plain = (j["plainLyrics"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return LyricsEntry(duration: (j["duration"] as? NSNumber)?.doubleValue, lines: parse(j["syncedLyrics"] as? String ?? ""),
                           plain: plain == [""] ? [] : plain)
    }

    /// The entry to use. LRCLIB's exact match can be one person's late sync while several others agree (11-07, Drake's
    /// "Jungle": it ran 0.5-0.9 s behind four syncs that agreed within 0.05 s; the owner saw the lyrics late). So: only
    /// syncs of the song's own length (±2 s), identical copies counted once, and the one closest to all the others (least
    /// mean distance; ties go to the one with more copies, then the earlier). With no sync of that length, the words of
    /// the first entry, without timings: another version's timings would be wrong all through.
    static func best(_ entries: [LyricsEntry], duration: Double?) -> LyricsEntry? {
        let fits = entries.filter { e in duration.map { d in e.duration.map { abs($0 - d) <= 2 } ?? true } ?? true }
        var distinct: [(entry: LyricsEntry, copies: Int)] = []
        for e in fits where !e.lines.isEmpty {
            if let i = distinct.firstIndex(where: { $0.entry.lines == e.lines }) { distinct[i].copies += 1 } else { distinct.append((e, 1)) }
        }
        guard !distinct.isEmpty else {
            guard let e = fits.first(where: { !$0.plain.isEmpty }) ?? entries.first(where: { !$0.plain.isEmpty || !$0.lines.isEmpty })
            else { return nil }
            return LyricsEntry(duration: e.duration, lines: [], plain: e.plain.isEmpty ? e.lines.map(\.text) : e.plain)
        }
        let scored = distinct.indices.map { i -> (Int, Double) in
            let others = distinct.indices.filter { $0 != i }.map { distance(distinct[i].entry.lines, distinct[$0].entry.lines) }
            return (i, others.isEmpty ? 0 : others.reduce(0, +) / Double(others.count))
        }
        let pick = scored.min { a, b in
            abs(a.1 - b.1) > 0.01 ? a.1 < b.1 : distinct[a.0].copies != distinct[b.0].copies ? distinct[a.0].copies > distinct[b.0].copies : a.0 < b.0
        }!
        return distinct[pick.0].entry
    }

    /// How far apart two syncs are: the median gap between the lines they share (matched by their words, in order);
    /// 10 s when they share fewer than three.
    static func distance(_ a: [LyricLine], _ b: [LyricLine]) -> Double {
        func words(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var gaps: [Double] = [], from = 0
        for line in a where !words(line.text).isEmpty {
            guard let j = b[from...].firstIndex(where: { words($0.text) == words(line.text) }) else { continue }
            gaps.append(abs(line.time - b[j].time))
            from = j + 1
        }
        guard gaps.count >= 3 else { return 10 }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    /// LRC lines: "[01:23.45] text" (several stamps on one line allowed); blank lines keep their time as a pause.
    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.split(separator: "\n") {
            var line = Substring(raw), stamps: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let stamp = line[line.index(after: line.startIndex)..<close]
                let parts = stamp.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) { stamps.append(m * 60 + s) }
                line = line[line.index(after: close)...]
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append(LyricLine(time: t, text: text)) }
        }
        return out.sorted { $0.time < $1.time }
    }
}
