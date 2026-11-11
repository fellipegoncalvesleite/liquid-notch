import AppKit
import os
import Foundation

// Football in the notch (11-06, docs/superpowers/specs/2026-11-06-football-design.md): the reminder before kickoff,
// the live match, a goal, the final whistle. Live data from ESPN's public site API (unofficial: no key, no published
// terms, fine for the owner's own use); crests from ESPN's CDN, loaded at runtime and cached on disk, never bundled.

/// The sports a team can be followed in (v1, 11-11, owner: "put the most famous sports there"): football (soccer) and
/// the four big North American leagues. Each is one ESPN path; the cards are the same, the words and the bar differ.
enum Sport: String, Codable, Sendable, CaseIterable {
    case soccer, nfl, nba, mlb, nhl

    /// ESPN's sport and league as the site API's path ("basketball/nba"); soccer's league varies per match.
    var path: String {
        switch self {
        case .soccer: "soccer"
        case .nfl: "football/nfl"
        case .nba: "basketball/nba"
        case .mlb: "baseball/mlb"
        case .nhl: "hockey/nhl"
        }
    }

    /// The search's `sport` and `league` for a team of this sport (soccer: any league).
    static func of(sport: String, league: String) -> Sport? {
        switch (sport, league) {
        case ("soccer", _): .soccer
        case ("football", "nfl"): .nfl
        case ("basketball", "nba"): .nba
        case ("baseball", "mlb"): .mlb
        case ("hockey", "nhl"): .nhl
        default: nil
        }
    }

    var name: String {
        switch self {
        case .soccer: "Football"
        case .nfl: "NFL"
        case .nba: "NBA"
        case .mlb: "MLB"
        case .nhl: "NHL"
        }
    }

    /// What a score is called in its alert; nil: no alert per score (a basket every half minute would never stop).
    var scoreWord: String? {
        switch self {
        case .soccer, .nhl: "Goal"
        case .nfl: "Score"
        case .mlb: "Run"
        case .nba: nil
        }
    }

    /// The end of the game: soccer's full time, everyone else's final.
    var finalWord: String { self == .soccer ? "Full time" : "Final" }
    var finalShort: String { self == .soccer ? "FT" : "Final" }

    /// Periods and their length in seconds (MLB: nine innings, no clock).
    var periods: Int { switch self { case .soccer: 2; case .nfl, .nba: 4; case .mlb: 9; case .nhl: 3 } }
    var periodSeconds: Double? { switch self { case .soccer: 45 * 60; case .nfl: 15 * 60; case .nba: 12 * 60; case .nhl: 20 * 60; case .mlb: nil } }
}

/// A team as ESPN names it.
struct FootballTeam: Equatable, Codable, Sendable {
    var id: Int
    var abbr: String
    var name: String
    var colorHex: String
    /// nil in what was saved before other sports came (11-11): soccer.
    var sport: Sport?
    /// ESPN's logo, when it gave one.
    var logo: String?

    init(id: Int, abbr: String, name: String, colorHex: String, sport: Sport? = nil, logo: String? = nil) {
        self.id = id; self.abbr = abbr; self.name = name; self.colorHex = colorHex; self.sport = sport; self.logo = logo
    }

    var kind: Sport { sport ?? .soccer }
    /// Ids repeat across sports.
    var key: String { "\(kind.rawValue)-\(id)" }
}

/// One match, sample or live. Side 0 is home, 1 away.
struct FootballMatch: Equatable, Codable, Sendable {
    struct Goal: Equatable, Codable, Sendable {
        var minute: Int
        var side: Int
    }

    /// ESPN's event id ("" for samples) and league slug (for the scoreboard).
    var eventID = ""
    var league = ""
    var competition: String
    var venue: String
    var kickoff: Date
    var home: FootballTeam
    var away: FootballTeam
    /// The side you follow.
    var ours: Int
    var score = [0, 0]
    /// Minutes played (the sample's clock).
    var minute = 0.0
    /// ESPN's clock ("67'", "90'+5'"); nil: from `minute`.
    var clock: String?
    var halfTime = false
    var goals: [Goal] = []
    /// The period (quarter, inning, half) and the clock's seconds left in it, from ESPN (not soccer).
    var period = 0
    var clockLeft: Double?
    /// The card's last line: the venue before kickoff, then the last event.
    var last = ""
    var started = false
    var finished = false
    /// Off the network: the score can't be read.
    var stale = false

    func team(_ side: Int) -> FootballTeam { side == 0 ? home : away }
    var sport: Sport { home.kind }
    var ourTeam: FootballTeam { team(ours) }
    var minuteText: String {
        if sport != .soccer { return clock ?? "" }   // ESPN's own: "Q3 4:12", "Bot 7th", "2nd 10:05"
        return halfTime ? "HT" : clock ?? "\(max(1, Int(minute.rounded(.up))))'"
    }
    var scoreText: String { "\(score[0])–\(score[1])" }
    var kickoffText: String { kickoffText() }
    /// The kickoff in your clock: 12 or 24 hours as your Mac shows time. (Bug 11-11: `.twoDigits(amPM: .omitted)` took
    /// en_BR's 12-hour clock and dropped the AM/PM, so a 21:30 kickoff read "09:30".)
    func kickoffText(timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        style.locale = locale
        return kickoff.formatted(style)
    }
    /// The bar's position, 0…1.
    var progress: Double {
        guard sport != .soccer else { return min(max(minute / 90, 0), 1) }
        guard period > 0 else { return 0 }
        let n = Double(sport.periods), p = Double(min(period, sport.periods))
        let within = sport.periodSeconds.map { len in 1 - min(max((clockLeft ?? len) / len, 0), 1) } ?? 0.5
        return min(max((p - 1 + within) / n, 0), 1)
    }

    /// "in 15 min", "now".
    func untilText(from now: Date) -> String {
        let m = Int((kickoff.timeIntervalSince(now) / 60).rounded(.up))
        return m <= 0 ? "now" : "in \(m) min"
    }
}

/// The sim's samples (`MATCHES`): this week's real fixtures with invented goals. A match minute lasts 1.2 s, so a game
/// fits in two minutes. No player names.
enum FootballSamples {
    static let minute = 1.2
    static let halfTimeHold = 4.0

    static let palmeiras = FootballTeam(id: 2029, abbr: "PAL", name: "Palmeiras", colorHex: "#1F8A43")
    static let flamengo = FootballTeam(id: 819, abbr: "FLA", name: "Flamengo", colorHex: "#C60000")
    static let barcelona = FootballTeam(id: 83, abbr: "BAR", name: "Barcelona", colorHex: "#A50044")
    static let atletico = FootballTeam(id: 1068, abbr: "ATM", name: "Atlético Madrid", colorHex: "#CA3624")

    /// The match and the goals it will have (minute, side).
    static func match(_ key: String, now: Date) -> (match: FootballMatch, script: [FootballMatch.Goal]) {
        let kickoff = now.addingTimeInterval(15 * 60)
        if key == "bar" {
            return (FootballMatch(competition: "LaLiga", venue: "Metropolitano", kickoff: kickoff, home: atletico, away: barcelona,
                                  ours: 1, last: "LaLiga · Metropolitano"),
                    [.init(minute: 12, side: 1), .init(minute: 55, side: 0), .init(minute: 78, side: 1)])
        }
        return (FootballMatch(competition: "Brasileirão", venue: "Allianz Parque", kickoff: kickoff, home: palmeiras, away: flamengo,
                              ours: 0, last: "Brasileirão · Allianz Parque"),
                [.init(minute: 23, side: 0), .init(minute: 41, side: 1), .init(minute: 67, side: 0), .init(minute: 88, side: 0)])
    }
}

// MARK: - Crests

/// Crests from ESPN's CDN, cached in memory and on disk. Until (or unless) one loads, a badge in the team's colour
/// stands in. `offline` keeps the snapshot runner and the tests off the network.
@MainActor @Observable
final class CrestStore {
    static let shared = CrestStore()
    @ObservationIgnored var offline = false
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    func image(_ team: FootballTeam) -> NSImage? {
        if let i = images[team.key] { return i }
        load(team)
        return nil
    }

    private static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.fellipe.liquidnotch/crests", isDirectory: true)
    }

    /// ESPN's logo resized by its own image service; soccer crests by id when no logo came with the team.
    static func url(_ team: FootballTeam) -> URL? {
        let path: String
        if let logo = team.logo, let u = URL(string: logo), u.host?.hasSuffix("espncdn.com") == true { path = u.path }
        else if team.kind == .soccer { path = "/i/teamlogos/soccer/500/\(team.id).png" }
        else { path = "/i/teamlogos/\(team.kind.rawValue)/500/\(team.abbr.lowercased()).png" }
        return URL(string: "https://a.espncdn.com/combiner/i?img=\(path)&w=96&h=96")
    }

    private func load(_ team: FootballTeam) {
        let key = team.key
        guard !loading.contains(key) else { return }
        loading.insert(key)
        // Soccer crests keep their old file name (`<id>.png`), so the cache already there stays good.
        let file = Self.folder.appendingPathComponent(team.kind == .soccer ? "\(team.id).png" : "\(key).png")
        if let i = NSImage(contentsOf: file) { images[key] = i; return }
        guard !offline, let url = Self.url(team) else { return }
        Task { [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return }
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try? data.write(to: file)
            self?.images[key] = image
        }
    }
}

// MARK: - ESPN

/// Watches the followed teams' matches on ESPN's public site API. Polls only around matches, so the app stays at 0% CPU
/// otherwise: the schedules twice a day, the scoreboard every 60 s from 20 minutes before kickoff, every 15 s while
/// live, stopping at full time. The reminder comes 15 minutes before kickoff, from the cached schedule if offline.
@MainActor
final class FootballWatcher {
    var onReminder: ((FootballMatch) -> Void)?
    var onUpdate: ((FootballMatch) -> Void)?

    /// The teams picked in Setup (none by default: football stays off, and off the network, until someone picks one).
    private var follows: [FootballTeam]
    private var followsObserver: NSObjectProtocol?
    private var upcoming: [FootballMatch] = []
    /// The schedule's refresh (checked hourly against the wall clock) and the next reminder or scoreboard check.
    private var refreshTimer: Timer?
    private var nextTimer: Timer?
    private var lastRefresh = Date.distantPast
    private var wakeObserver: NSObjectProtocol?
    private var poll: Timer?
    private var reminded: Set<String> = []
    private var live: [String: FootballMatch] = [:]
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "football")

    init(follows: [FootballTeam]? = nil) { self.follows = follows ?? FootballTeams.load() }

    func start() {
        upcoming = Self.loadCache().filter { m in follows.contains { $0.key == m.home.key || $0.key == m.away.key } }
        followsObserver = NotificationCenter.default.addObserver(forName: FootballTeams.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followsChanged() }
        }
        armMatches()
        Task { await refreshSchedules() }
        // A Timer's clock stops while the Mac sleeps, so nothing here waits on one for long: the refresh checks the wall
        // clock every hour, and waking re-checks everything (bug 11-11: a reminder armed before a night's sleep came
        // about 12 hours late).
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.armMatches()
                self?.refreshIfStale()
            }
        }
    }

    /// Setup's picks changed: matches of teams no longer followed go, and the schedules are read again.
    private func followsChanged() {
        follows = FootballTeams.load()
        upcoming = upcoming.filter { m in follows.contains { $0.key == m.home.key || $0.key == m.away.key } }
        Self.saveCache(upcoming)
        armMatches()
        Task { await refreshSchedules() }
    }

    func stop() {
        if let o = followsObserver { NotificationCenter.default.removeObserver(o); followsObserver = nil }
        refreshTimer?.invalidate(); refreshTimer = nil
        nextTimer?.invalidate(); nextTimer = nil
        poll?.invalidate(); poll = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
    }

    private func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 12 * 3600 { Task { await refreshSchedules() } }
    }

    // MARK: Schedules

    private func refreshSchedules() async {
        var found: [String: FootballMatch] = [:]
        guard !follows.isEmpty else { lastRefresh = Date(); return }
        for f in follows {
            // Soccer: every competition the team plays in, each event tagged with its league (no slugs kept here). The
            // other sports have one league each: its path is the scoreboard's.
            let url = f.kind == .soccer
                ? "https://site.api.espn.com/apis/site/v2/sports/soccer/all/teams/\(f.id)/schedule?fixture=true"
                : "https://site.api.espn.com/apis/site/v2/sports/\(f.kind.path)/teams/\(f.id)/schedule"
            guard let json = await Self.fetch(url), let events = json["events"] as? [[String: Any]] else { continue }
            for e in events {
                guard let league = f.kind == .soccer ? Self.leagueSlug(e) : f.kind.path,
                      var m = Self.match(e, league: league, sport: f.kind),
                      m.kickoff > Date().addingTimeInterval(-3 * 3600), m.kickoff < Date().addingTimeInterval(8 * 86400) else { continue }
                m.ours = m.home.id == f.id ? 0 : 1
                m.home.logo = m.home.logo ?? (m.home.id == f.id ? f.logo : nil)
                m.away.logo = m.away.logo ?? (m.away.id == f.id ? f.logo : nil)
                found[m.eventID] = m
            }
        }
        lastRefresh = Date()
        guard !found.isEmpty else { return }
        upcoming = found.values.sorted { $0.kickoff < $1.kickoff }
        Self.saveCache(upcoming)
        Self.log.info("football: \(self.upcoming.count) upcoming")
        armMatches()
    }

    /// What's due now, by the wall clock: reminders (15 minutes before kickoff, never after it) and the scoreboard (from 20
    /// minutes before to 3 hours after). Then one timer to the next thing due, at most 30 minutes away.
    private func armMatches() {
        nextTimer?.invalidate(); nextTimer = nil
        let now = Date()
        for m in upcoming where !m.finished {
            let due = Self.due(m, now: now)
            if due.remind { remind(m) }
            if due.watch { watch() }
        }
        guard let next = Self.nextCheck(upcoming, now: now) else { return }
        let t = Timer(timeInterval: max(1, min(next.timeIntervalSince(now), 1800)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.armMatches() }
        }
        RunLoop.main.add(t, forMode: .common)
        nextTimer = t
    }

    static func due(_ m: FootballMatch, now: Date) -> (remind: Bool, watch: Bool) {
        let remindAt = m.kickoff.addingTimeInterval(-15 * 60), watchAt = m.kickoff.addingTimeInterval(-20 * 60)
        return (remindAt <= now && now < m.kickoff, !m.finished && watchAt <= now && now < m.kickoff.addingTimeInterval(3 * 3600))
    }

    /// The next reminder or scoreboard start after now.
    static func nextCheck(_ list: [FootballMatch], now: Date) -> Date? {
        list.filter { !$0.finished }
            .flatMap { [$0.kickoff.addingTimeInterval(-20 * 60), $0.kickoff.addingTimeInterval(-15 * 60)] }
            .filter { $0 > now }.min()
    }

    private func remind(_ m: FootballMatch) {
        guard !reminded.contains(m.eventID) else { return }
        reminded.insert(m.eventID)
        onReminder?(m)
    }

    // MARK: Scoreboard

    private func watch() {
        guard poll == nil else { return }
        schedulePoll(after: 0)
    }

    private func schedulePoll(after seconds: Double) {
        poll?.invalidate()
        let t = Timer(timeInterval: max(seconds, 0.01), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.pollScoreboards() } }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func pollScoreboards() async {
        let now = Date()
        let watched = upcoming.filter { !$0.finished && $0.kickoff.addingTimeInterval(-20 * 60) <= now && $0.kickoff.addingTimeInterval(3 * 3600) > now }
        guard !watched.isEmpty else { poll = nil; return }
        var anyLive = false
        for league in Set(watched.map(\.league)) {
            let days = Self.scoreboardDates(around: watched.filter { $0.league == league }.map(\.kickoff))
            let json = await Self.fetch("https://site.api.espn.com/apis/site/v2/sports/\(Self.scoreboardPath(league))/scoreboard?dates=\(days)")
            for var m in watched where m.league == league {
                guard let events = json?["events"] as? [[String: Any]], let e = events.first(where: { ($0["id"] as? String) == m.eventID }) else {
                    if json == nil, m.started { m.stale = true; onUpdate?(m) }
                    continue
                }
                Self.applyStatus(e, to: &m)
                if let i = upcoming.firstIndex(where: { $0.eventID == m.eventID }) { upcoming[i] = m }
                if m.started { anyLive = anyLive || !m.finished; if live[m.eventID] != m { live[m.eventID] = m; onUpdate?(m) } }
            }
        }
        if upcoming.allSatisfy({ $0.finished || $0.kickoff.addingTimeInterval(-20 * 60) > Date() }) && !anyLive { poll = nil; return }
        schedulePoll(after: anyLive ? 15 : 60)
    }

    // MARK: Parsing (static, tested)

    /// The scoreboard's `dates` for these kickoffs: a range from the day before the first to the day after the last (UTC
    /// days). ESPN files a match under its own (US) day, so the UTC day of now missed evening games in Brazil: a 21:30
    /// kickoff in São Paulo is 00:30 the next day in UTC (bug 11-11).
    static func scoreboardDates(around kickoffs: [Date]) -> String {
        guard let first = kickoffs.min(), let last = kickoffs.max() else { return DateFormatter.espnDay.string(from: Date()) }
        let f = DateFormatter.espnDay
        return f.string(from: first.addingTimeInterval(-86_400)) + "-" + f.string(from: last.addingTimeInterval(86_400))
    }

    /// A match's scoreboard: soccer keeps the league's slug ("bra.1"), the others their whole path ("basketball/nba").
    static func scoreboardPath(_ league: String) -> String { league.contains("/") ? league : "soccer/" + league }

    static func match(_ e: [String: Any], league: String, sport: Sport = .soccer) -> FootballMatch? {
        guard let id = e["id"] as? String, let dateText = e["date"] as? String, let date = DateFormatter.espnDate(dateText),
              let c = (e["competitions"] as? [[String: Any]])?.first,
              let teams = c["competitors"] as? [[String: Any]] else { return nil }
        func team(_ side: String) -> FootballTeam? {
            guard let t = teams.first(where: { ($0["homeAway"] as? String) == side })?["team"] as? [String: Any],
                  let tid = Int(t["id"] as? String ?? "") else { return nil }
            let color = (t["color"] as? String).map { "#" + $0 } ?? "#3A3A3C"
            let logo = (t["logos"] as? [[String: Any]])?.first?["href"] as? String ?? t["logo"] as? String
            return FootballTeam(id: tid, abbr: t["abbreviation"] as? String ?? "", name: t["shortDisplayName"] as? String ?? t["displayName"] as? String ?? "",
                                colorHex: color, sport: sport == .soccer ? nil : sport, logo: logo)
        }
        guard let home = team("home"), let away = team("away") else { return nil }
        let leagueName = (e["league"] as? [String: Any])?["shortName"] as? String
            ?? (e["league"] as? [String: Any])?["abbreviation"] as? String
            ?? (e["seasonType"] as? [String: Any])?["name"] as? String ?? ""
        let venue = (c["venue"] as? [String: Any])?["fullName"] as? String ?? ""
        let comp = sport == .soccer ? Self.competitionName(league) ?? leagueName : sport.name
        var m = FootballMatch(eventID: id, league: league, competition: comp, venue: venue, kickoff: date, home: home, away: away,
                              ours: 0, last: venue.isEmpty ? comp : "\(comp) · \(venue)")
        applyStatus(e, to: &m)
        return m
    }

    /// Status, clock, score and goals from a scoreboard (or schedule) event.
    static func applyStatus(_ e: [String: Any], to m: inout FootballMatch) {
        guard let c = (e["competitions"] as? [[String: Any]])?.first else { return }
        let status = (c["status"] as? [String: Any]) ?? (e["status"] as? [String: Any]) ?? [:]
        let type = status["type"] as? [String: Any] ?? [:]
        let state = type["state"] as? String ?? "pre", name = type["name"] as? String ?? ""
        m.stale = false
        m.started = state != "pre"
        m.finished = state == "post"
        m.halfTime = name == "STATUS_HALFTIME"
        if m.sport != .soccer {
            // ESPN's own line ("Q3 4:12", "Bot 7th", "Halftime") and the period for the bar.
            if m.started { m.clock = type["shortDetail"] as? String ?? m.clock }
            m.period = status["period"] as? Int ?? m.period
            m.clockLeft = status["clock"] as? Double
        } else if let clock = status["displayClock"] as? String, m.started {
            m.clock = clock
            m.minute = Double(clock.prefix { $0.isNumber }) ?? m.minute
        }
        for t in c["competitors"] as? [[String: Any]] ?? [] {
            let side = (t["homeAway"] as? String) == "away" ? 1 : 0
            if let s = t["score"] as? String, let v = Int(s) { m.score[side] = v }
            else if let s = (t["score"] as? [String: Any])?["value"] as? Double { m.score[side] = Int(s) }
        }
        guard m.sport == .soccer else { return }   // scores are told apart by the score itself (`IslandDirector.footballUpdated`)
        var goals: [FootballMatch.Goal] = []
        for d in c["details"] as? [[String: Any]] ?? [] where d["scoringPlay"] as? Bool == true && d["shootout"] as? Bool != true {
            let minute = Int(((d["clock"] as? [String: Any])?["displayValue"] as? String ?? "").prefix { $0.isNumber }) ?? 0
            let teamID = Int((d["team"] as? [String: Any])?["id"] as? String ?? "")
            goals.append(.init(minute: minute, side: teamID == m.away.id ? 1 : 0))
        }
        if !goals.isEmpty || m.started { m.goals = goals }
        if m.halfTime { m.last = "Half time" }
        else if let g = goals.last { m.last = "Goal · \(m.team(g.side).name) \(g.minute)'" }
    }

    /// The event's league slug (the scoreboard it lives on).
    static func leagueSlug(_ e: [String: Any]) -> String? {
        (e["league"] as? [String: Any])?["slug"] as? String
    }

    static func competitionName(_ league: String) -> String? {
        ["bra.1": "Brasileirão", "esp.1": "LaLiga", "uefa.champions": "Champions League", "conmebol.libertadores": "Libertadores",
         "bra.copa_do_brazil": "Copa do Brasil", "esp.copa_del_rey": "Copa del Rey"][league]
    }

    private static func fetch(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url), let (data, response) = try? await URLSession.shared.data(from: u),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Liquid Notch/football.json")
    }

    private static func loadCache() -> [FootballMatch] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([FootballMatch].self, from: data))?.filter { $0.kickoff > Date().addingTimeInterval(-3 * 3600) } ?? []
    }

    private static func saveCache(_ list: [FootballMatch]) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: cacheURL) }
    }
}

extension DateFormatter {
    /// ESPN's scoreboard day, yyyyMMdd in the UTC calendar.
    static let espnDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// ESPN's dates: "2026-11-08T20:00Z" (no seconds), sometimes with seconds.
    static func espnDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        g.timeZone = TimeZone(identifier: "UTC")
        g.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return g.date(from: s)
    }
}

// MARK: - Chess

/// Chess (11-06, docs/superpowers/specs/2026-11-06-chess-design.md): the sample game from the sim (`CHESS`). You're
/// White in a Najdorf; each step is your move, the opponent's reply as it arrives, its SAN and both clocks (seconds).
/// The live route (the chess.com page through the browser extension) isn't built: only the sample shows. Fair play:
/// the notch shows the position and the move played, never anything computed about it.
enum ChessSample {
    static let opponent = "Marta Reis"
    static let line: [(mine: String, theirs: String, san: String, myClock: Double, theirClock: Double)] = [
        ("e2e4", "c7c5", "c5", 171, 176), ("g1f3", "d7d6", "d6", 160, 167), ("d2d4", "c5d4", "cxd4", 142, 161),
        ("f3d4", "g8f6", "Nf6", 118, 150), ("b1c3", "a7a6", "a6", 24, 132),
    ]

    /// a8 = 0 … h1 = 63: White at the bottom.
    static func square(_ s: Substring) -> Int {
        let file = Int(s.unicodeScalars.first!.value) - 97, rank = Int(String(s.last!))!
        return (8 - rank) * 8 + file
    }

    /// The position after the opponent's reply in `step`: FEN letters (upper case White), nil for empty squares.
    static func board(_ step: Int) -> [Character?] {
        var b: [Character?] = []
        for ch in "rnbqkbnrpppppppp" { b.append(ch) }
        b += Array(repeating: nil, count: 32)
        for ch in "PPPPPPPPRNBQKBNR" { b.append(ch) }
        for pair in line.prefix(step + 1) {
            for m in [pair.mine, pair.theirs] {
                let from = square(m.prefix(2)), to = square(m.dropFirst(2))
                b[to] = b[from]; b[from] = nil
            }
        }
        return b
    }

    struct Now: Equatable {
        var from: Int
        var to: Int
        var san: String
        var myClock: Double
        var theirClock: Double
        var piece: Character
    }

    static func now(_ step: Int) -> Now {
        let s = line[step % line.count], to = square(s.theirs.dropFirst(2))
        return Now(from: square(s.theirs.prefix(2)), to: to, san: s.san, myClock: s.myClock, theirClock: s.theirClock,
                   piece: board(step % line.count)[to] ?? "p")
    }

    /// The figurine in text presentation (never the emoji).
    static func glyph(_ p: Character) -> String {
        let g: [Character: String] = ["k": "♚", "q": "♛", "r": "♜", "b": "♝", "n": "♞", "p": "♟"]
        return (g[Character(p.lowercased())] ?? "♟") + "\u{FE0E}"
    }
}


// MARK: - The teams you follow (Setup)

/// The teams picked in Setup's Football section, kept in UserDefaults. None by default.
enum FootballTeams {
    static let key = "football.teams"
    static let changed = Notification.Name("LiquidNotchFootballTeamsChanged")

    static func load(_ defaults: UserDefaults = .standard) -> [FootballTeam] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([FootballTeam].self, from: data)) ?? []
    }

    static func save(_ teams: [FootballTeam], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(teams), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func follow(_ t: FootballTeam) { var all = load(); if !all.contains(where: { $0.key == t.key }) { all.append(t); save(all) } }
    static func unfollow(_ key: String) { save(load().filter { $0.key != key }) }
}

/// Team search through ESPN's public search: football clubs and national teams, NFL, NBA, MLB and NHL teams (college and
/// other leagues are left out).
enum FootballSearch {
    static func teams(_ query: String) async -> [FootballTeam] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, var c = URLComponents(string: "https://site.web.api.espn.com/apis/common/v3/search") else { return [] }
        c.queryItems = [.init(name: "query", value: q), .init(name: "type", value: "team"), .init(name: "limit", value: "25")]
        guard let url = c.url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> [FootballTeam] {
        (json["items"] as? [[String: Any]] ?? []).compactMap { i in
            guard (i["type"] as? String) == "team",
                  let sport = Sport.of(sport: i["sport"] as? String ?? "", league: i["league"] as? String ?? ""),
                  let id = Int(i["id"] as? String ?? ""), let name = i["displayName"] as? String else { return nil }
            return FootballTeam(id: id, abbr: i["abbreviation"] as? String ?? "", name: name,
                                colorHex: (i["color"] as? String).map { "#" + $0 } ?? "#3A3A3C",
                                sport: sport == .soccer ? nil : sport,
                                logo: (i["logos"] as? [[String: Any]])?.first?["href"] as? String)
        }
    }
}
