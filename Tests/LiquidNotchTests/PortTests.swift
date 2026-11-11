import IslandCore
import NowPlaying
import XCTest
@testable import LiquidNotch

/// The 11-06 ports from the simulator: football (FB1–FB4), chess (CH1–CH2), the usage limit (LIM1–LIM2) and the
/// player's scrubber (SCRUB1–SCRUB3).
@MainActor
final class PortTests: XCTestCase {
    final class Clock { var t = 0.0 }

    private func director() -> (IslandDirector, ManualScheduler, Clock) {
        let d = IslandDirector(), s = ManualScheduler(), c = Clock()
        d.schedule = s.schedule
        d.clock = { c.t }
        d.frontmostApp = { "" }
        return (d, s, c)
    }

    private func step(_ d: IslandDirector, _ c: Clock, _ seconds: Double, by dt: Double = 0.25) {
        var left = seconds
        while left > 0 { let x = min(dt, left); c.t += x; left -= x; d.tick() }
    }

    // FB1: the reminder hands over to the live match a beat after it leaves; the sample's minutes run, goals come from
    // the script with their moment, half time waits, and the final whistle ends the match with a transient.
    func testFB1SampleMatchRunsFromReminderToFullTime() {
        let (d, s, c) = director()
        d.footballButton("pal")
        XCTAssertEqual(d.island.activity?.id, .kickoff)
        s.advance(5)                                    // the reminder's 5 s
        XCTAssertFalse(d.island.running.contains { $0.id == .kickoff })
        XCTAssertFalse(d.island.running.contains { $0.id == .match })
        s.advance(0.9)                                  // a beat later, the whistle
        XCTAssertEqual(d.island.activity?.id, .match)
        step(d, c, 23 * FootballSamples.minute + 0.3)
        XCTAssertEqual(d.football?.score, [1, 0])
        XCTAssertEqual(d.island.activity?.id, .goal, "the goal borrows the ears")
        XCTAssertTrue(d.island.running.contains { $0.id == .match }, "the match waits behind its goal")
        s.advance(3.5)
        XCTAssertEqual(d.island.activity?.id, .match)
        step(d, c, 22 * FootballSamples.minute)         // just past 45': half time holds the clock
        XCTAssertEqual(d.football?.halfTime, true)
        XCTAssertEqual(d.football?.minuteText, "HT")
        let held = d.football?.minute
        step(d, c, 2)
        XCTAssertEqual(d.football?.minute, held, "the clock waits at half time")
        step(d, c, 3)
        XCTAssertEqual(d.football?.halfTime, false)
        step(d, c, 50 * FootballSamples.minute)
        XCTAssertFalse(d.island.running.contains { $0.id == .match }, "full time ends the match")
        XCTAssertTrue(d.island.running.contains { $0.id == .fulltime })
        XCTAssertEqual(d.footballFinal.score, [3, 1])
    }

    // FB2: ESPN's events: teams, kickoff, venue; the scoreboard's status, clock, score and goals.
    func testFB2ParsesESPN() throws {
        let json = """
        {"id":"401882816","date":"2026-11-08T20:00Z","competitions":[{"venue":{"fullName":"Metropolitano"},
         "status":{"displayClock":"67'","period":2,"type":{"name":"STATUS_SECOND_HALF","state":"in"}},
         "competitors":[{"homeAway":"home","score":"1","team":{"id":"1068","abbreviation":"ATM","shortDisplayName":"Atlético","color":"cb3524"}},
                        {"homeAway":"away","score":"2","team":{"id":"83","abbreviation":"BAR","shortDisplayName":"Barcelona","color":"a50044"}}],
         "details":[{"scoringPlay":true,"clock":{"displayValue":"12'"},"team":{"id":"83"}},
                    {"scoringPlay":false,"clock":{"displayValue":"30'"},"team":{"id":"1068"}},
                    {"scoringPlay":true,"clock":{"displayValue":"55'"},"team":{"id":"1068"}},
                    {"scoringPlay":true,"clock":{"displayValue":"64'"},"team":{"id":"83"}}]}]}
        """
        let e = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let m = try XCTUnwrap(FootballWatcher.match(e, league: "esp.1"))
        XCTAssertEqual(m.eventID, "401882816")
        XCTAssertEqual(m.home.abbr, "ATM")
        XCTAssertEqual(m.away.id, 83)
        XCTAssertEqual(m.away.colorHex, "#a50044")
        XCTAssertEqual(m.competition, "LaLiga")
        XCTAssertEqual(m.score, [1, 2])
        XCTAssertEqual(m.minuteText, "67'")
        XCTAssertTrue(m.started)
        XCTAssertFalse(m.finished)
        XCTAssertEqual(m.goals, [.init(minute: 12, side: 1), .init(minute: 55, side: 0), .init(minute: 64, side: 1)])
        XCTAssertEqual(m.last, "Goal · Barcelona 64'")
    }

    // FB3: live updates: the match shows when it starts, a new goal gets its moment, the final whistle ends it.
    func testFB3LiveUpdates() {
        let (d, s, _) = director()
        var m = FootballSamples.match("bar", now: Date()).match
        m.eventID = "1"; m.started = true; m.minute = 3
        d.footballUpdated(m)
        XCTAssertEqual(d.island.activity?.id, .match)
        XCTAssertFalse(d.isSample(d.island.activity!))
        m.score = [0, 1]; m.goals = [.init(minute: 12, side: 1)]
        d.footballUpdated(m)
        XCTAssertEqual(d.island.activity?.id, .goal)
        XCTAssertEqual(d.footballGoal.side, 1)
        s.advance(3.5)
        m.finished = true
        d.footballUpdated(m)
        XCTAssertFalse(d.island.running.contains { $0.id == .match })
        XCTAssertEqual(d.island.activity?.id, .fulltime)
    }

    // FB4: the debug panel's team buttons toggle, like the sim's strip.
    // FB5 (bug 11-11, "kickoffs show 12 hours late"): a 21:30 kickoff in São Paulo is 00:30 UTC the next day. It reads
    // 21:30 on a 24-hour clock and 9:30 PM on a 12-hour one, never a bare "09:30"; the scoreboard asks for the days around it.
    func testFB5KickoffInSaoPaulo() throws {
        let kickoff = try XCTUnwrap(DateFormatter.espnDate("2026-11-12T00:30Z"))
        let m = FootballMatch(competition: "Brasileirão", venue: "", kickoff: kickoff,
                              home: FootballSamples.palmeiras, away: FootballSamples.flamengo, ours: 0)
        let sp = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        XCTAssertEqual(m.kickoffText(timeZone: sp, locale: Locale(identifier: "pt_BR")), "21:30")
        let twelve = m.kickoffText(timeZone: sp, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(twelve.hasPrefix("9:30") && twelve.hasSuffix("PM"), twelve)
        let enBR = m.kickoffText(timeZone: sp, locale: Locale(identifier: "en_BR"))
        XCTAssertTrue(enBR == "21:30" || (enBR.hasPrefix("9:30") && enBR.hasSuffix("PM")), enBR)
        XCTAssertEqual(FootballWatcher.scoreboardDates(around: [kickoff]), "20261111-20261113")
    }

    // FB6 (bug 11-11): what's due is read from the wall clock, so a check that comes late (after the Mac slept) never shows
    // a reminder after kickoff, and stops watching 3 hours after it.
    func testFB6DueByTheWallClock() throws {
        let k = try XCTUnwrap(DateFormatter.espnDate("2026-11-12T00:30Z"))
        let m = FootballMatch(competition: "", venue: "", kickoff: k, home: FootballSamples.palmeiras, away: FootballSamples.flamengo, ours: 0)
        XCTAssertFalse(FootballWatcher.due(m, now: k.addingTimeInterval(-16 * 60)).remind)
        XCTAssertTrue(FootballWatcher.due(m, now: k.addingTimeInterval(-15 * 60)).remind)
        XCTAssertTrue(FootballWatcher.due(m, now: k.addingTimeInterval(-19 * 60)).watch)
        let late = FootballWatcher.due(m, now: k.addingTimeInterval(12 * 3600))   // the old timer, 12 hours of sleep later
        XCTAssertFalse(late.remind)
        XCTAssertFalse(late.watch)
        XCTAssertEqual(FootballWatcher.nextCheck([m], now: k.addingTimeInterval(-3600)), k.addingTimeInterval(-20 * 60))
        XCTAssertEqual(FootballWatcher.nextCheck([m], now: k.addingTimeInterval(-18 * 60)), k.addingTimeInterval(-15 * 60))
        XCTAssertNil(FootballWatcher.nextCheck([m], now: k))
    }

    // FB7 (v1): teams come from Setup, not the code. ESPN's search gives clubs (players and other sports dropped); picks
    // round-trip through UserDefaults; none by default; a schedule event names its own league.
    func testFB7TeamsFromSetup() throws {
        let search: [String: Any] = ["items": [
            ["id": "2029", "type": "team", "sport": "soccer", "displayName": "Palmeiras", "abbreviation": "PAL", "color": "417505"],
            ["id": "9", "type": "team", "sport": "basketball", "displayName": "Palmeiras Basquete"],
            ["id": "156811", "type": "player", "sport": "soccer", "displayName": "Someone"],
        ]]
        let found = FootballSearch.parse(search)
        XCTAssertEqual(found, [FootballTeam(id: 2029, abbr: "PAL", name: "Palmeiras", colorHex: "#417505")])
        let d = try XCTUnwrap(UserDefaults(suiteName: "fb7-\(UUID().uuidString)"))
        XCTAssertEqual(FootballTeams.load(d), [], "no teams by default")
        FootballTeams.save(found, d)
        XCTAssertEqual(FootballTeams.load(d), found)
        XCTAssertEqual(FootballWatcher.leagueSlug(["league": ["slug": "conmebol.libertadores"]]), "conmebol.libertadores")
        XCTAssertNil(FootballWatcher.leagueSlug([:]))
    }

    // FB8 (v1, owner: "put the most famous sports there"): NFL, NBA, MLB and NHL teams from the search (college left out),
    // ESPN's own status line and the period bar for a live NBA game, and who scored from the score alone.
    func testFB8OtherSports() throws {
        let search: [String: Any] = ["items": [
            ["id": "13", "type": "team", "sport": "basketball", "league": "nba", "displayName": "Los Angeles Lakers", "abbreviation": "LAL",
             "logos": [["href": "https://a.espncdn.com/i/teamlogos/nba/500/lal.png"]]],
            ["id": "2385", "type": "team", "sport": "basketball", "league": "mens-college-basketball", "displayName": "Mercyhurst Lakers"],
            ["id": "12", "type": "team", "sport": "football", "league": "nfl", "displayName": "Kansas City Chiefs"],
        ]]
        let teams = FootballSearch.parse(search)
        XCTAssertEqual(teams.map(\.key), ["nba-13", "nfl-12"])
        XCTAssertEqual(CrestStore.url(teams[0])?.absoluteString, "https://a.espncdn.com/combiner/i?img=/i/teamlogos/nba/500/lal.png&w=96&h=96")
        let live: [String: Any] = [
            "id": "401", "date": "2026-11-12T01:00Z",
            "competitions": [[
                "status": ["clock": 252.0, "displayClock": "4:12", "period": 3,
                           "type": ["state": "in", "name": "STATUS_IN_PROGRESS", "shortDetail": "4:12 - 3rd"]],
                "competitors": [
                    ["homeAway": "home", "score": "88", "team": ["id": "13", "abbreviation": "LAL", "displayName": "Lakers"]],
                    ["homeAway": "away", "score": "85", "team": ["id": "15", "abbreviation": "MIL", "displayName": "Bucks"]],
                ],
            ]],
        ]
        let m = try XCTUnwrap(FootballWatcher.match(live, league: Sport.nba.path, sport: .nba))
        XCTAssertEqual(m.sport, .nba)
        XCTAssertEqual(m.competition, "NBA")
        XCTAssertEqual(m.minuteText, "4:12 - 3rd")
        XCTAssertEqual(m.score, [88, 85])
        XCTAssertEqual(m.progress, (2 + (1 - 252.0 / 720)) / 4, accuracy: 0.001)
        XCTAssertEqual(FootballWatcher.scoreboardPath(m.league), "basketball/nba")
        XCTAssertEqual(FootballWatcher.scoreboardPath("bra.1"), "soccer/bra.1")
        XCTAssertNil(Sport.nba.scoreWord, "no alert per basket")
        XCTAssertEqual(IslandDirector.scoringSide(before: [14, 7], after: [14, 14]), 1)
        XCTAssertEqual(IslandDirector.scoringSide(before: [3, 2], after: [4, 2]), 0)
        XCTAssertNil(IslandDirector.scoringSide(before: [1, 1], after: [1, 1]))
    }

    func testFB4TeamButtonsToggle() {
        let (d, _, _) = director()
        d.footballButton("pal")
        XCTAssertTrue(d.footballRunning("pal"))
        d.footballButton("bar")
        XCTAssertTrue(d.footballRunning("bar"))
        XCTAssertFalse(d.footballRunning("pal"))
        d.footballButton("bar")
        XCTAssertFalse(d.island.running.contains { [.kickoff, .match].contains($0.id) })
    }

    // CH1: the sample game's positions: the last move's squares, its SAN and the moved piece.
    func testCH1Positions() {
        let b = ChessSample.board(0)
        XCTAssertEqual(b[ChessSample.square("e4")], "P")
        XCTAssertNil(b[ChessSample.square("e2")])
        XCTAssertEqual(b[ChessSample.square("c5")], "p")
        let n = ChessSample.now(3)
        XCTAssertEqual(n.san, "Nf6")
        XCTAssertEqual(n.piece, "n")
        XCTAssertEqual(n.from, ChessSample.square("g8"))
        XCTAssertEqual(n.to, ChessSample.square("f6"))
        XCTAssertEqual(ChessSample.board(2)[ChessSample.square("d4")], "p", "cxd4 took the pawn")
        XCTAssertEqual(ChessSample.glyph("N"), "♞\u{FE0E}")
    }

    // CH2: your clock runs while it shows; Open game ends it and the next move arrives 4 s later.
    func testCH2ClockAndOpenGame() {
        let (d, s, c) = director()
        d.show(.chess, opened: false)
        XCTAssertEqual(d.island.activity?.id, .chess)
        step(d, c, 10)
        XCTAssertEqual(d.chessClock, ChessSample.now(0).myClock - 10, accuracy: 0.01)
        d.chessOpen(d.island.activity!)
        XCTAssertNil(d.island.activity)
        s.advance(4)
        XCTAssertEqual(d.island.activity?.id, .chess)
        XCTAssertEqual(d.chessStep, 1)
        XCTAssertEqual(d.chessClock, ChessSample.now(1).myClock)
    }

    // LIM1: the reset time is read from the hook's text when it says one.
    func testLIM1ResetTime() {
        XCTAssertEqual(IslandDirector.resetTime(in: ["message": "Claude usage limit reached. Your limit will reset at 6pm (America/Sao_Paulo)."]), "6pm")
        XCTAssertEqual(IslandDirector.resetTime(in: ["error": ["text": "resets 18:00"]]), "18:00")
        XCTAssertNil(IslandDirector.resetTime(in: ["error": "rate_limit"]))
    }

    // LIM2: a usage limit shows the red transient; its auto-resume the green one.
    func testLIM2LimitAndBack() {
        let (d, s, _) = director()
        func hook(_ event: String, _ extra: String) {
            let json = #"{"session_id":"c1","cwd":"/tmp/x"\#(extra)}"#
            d.agentHook(AgentSocket.Line(provider: "claude", event: event, host: "", raw: Data(json.utf8)), reply: nil)
        }
        hook("UserPromptSubmit", "")
        hook("StopFailure", #","error":"rate_limit","error_message":"Your limit will reset at 7pm""#)
        XCTAssertEqual(d.island.activity?.id, .agentLimit)
        XCTAssertEqual(d.limit.resets, "7pm")
        s.advance(5)
        hook("Notification", #","notification_type":"quota_auto_resume_fired""#)
        XCTAssertEqual(d.island.activity?.id, .agentBack)
        XCTAssertEqual(d.limit.provider, .claude)
    }

    // SCRUB1: seeking the sample moves its elapsed time at once.
    func testSCRUB1SeekTheSample() {
        let (d, _, _) = director()
        d.startMusic()
        d.seek(to: 64)
        XCTAssertEqual(d.elapsed, 64, accuracy: 0.01)
        d.seek(to: -5)
        XCTAssertEqual(d.elapsed, 0, accuracy: 0.01, "clamped to the song")
    }

    // SCRUB2: the real player gets one seek, and the bar holds the new place while its reports catch up.
    func testSCRUB2RealSeekHolds() {
        let (d, _, _) = director()
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        d.date = { now }
        var seeks: [Double] = []
        d.sendSeek = { seeks.append($0) }
        d.nowPlayingChanged(NowPlaying(title: "Song", artist: "A", playing: true, duration: 200, elapsed: 30, timestamp: now))
        d.seek(to: 120)
        XCTAssertEqual(seeks, [120])
        now += 0.5
        XCTAssertEqual(d.elapsed, 120.5, accuracy: 0.01, "the old report (30.5 s) doesn't snap it back")
        now += 1.5
        XCTAssertEqual(d.elapsed, 32, accuracy: 0.01, "after 1.5 s the player's word wins again")
    }

    // SCRUB3: holding the bar never closes the card; letting go off the card starts the linger.
    func testSCRUB3HoldingKeepsTheCard() {
        let (d, s, _) = director()
        d.startMusic()
        d.pointerDown(at: .zero, hit: .ears)
        d.pointerUp(at: .zero, hit: .ears, corridor: false)
        XCTAssertTrue(d.island.opened)
        d.scrub(true)
        d.pointerMoved(hit: nil, corridor: false, buttonDown: true)
        s.advance(5)
        XCTAssertTrue(d.island.opened, "holding is using it")
        d.scrub(false)
        s.advance(Tuning().closeDelay + 0.1)
        XCTAssertFalse(d.island.opened)
    }

    // DELIGHT1: the Konami code runs the rainbow and hands the colour back; scrubbing over the island giggles.
    func testDELIGHT1KonamiAndTickle() {
        let dl = Delights()
        var auras: [String?] = [], kicks: [Double] = [], t = 0.0
        dl.after = { _, f in f() }
        dl.aura = { auras.append($0) }
        dl.kick = { kicks.append($0) }
        dl.now = { t }
        for k in Delights.konami.dropLast() { XCTAssertFalse(dl.key(k)) }
        XCTAssertTrue(dl.key(0))
        XCTAssertEqual(auras.compactMap { $0 }, Delights.rainbowColors)
        XCTAssertNil(auras.last!, "the island's own colour comes back")
        for (i, x) in [0.0, 10, 0, 10, 0, 10].enumerated() { t = Double(i) * 0.1; dl.pointer(x: x, over: true, pressed: false) }
        XCTAssertEqual(kicks, [60, -50, 60])
    }

    // TINT1: the bloom takes the wallpaper's hue, light and soft; a grey or black wallpaper gets the sim's periwinkle.
    func testTINT1WallpaperTint() {
        XCTAssertEqual(WallpaperTint.tint(average: SIMD3(0.05, 0.05, 0.05)), WallpaperTint.neutral)
        let blue = OKLab.fromSRGB(SRGB.parse(WallpaperTint.tint(average: SIMD3(0.1, 0.3, 0.8)))!)
        XCTAssertEqual(blue.x, 0.74, accuracy: 0.02)
        XCTAssertLessThan(blue.z, 0, "a blue wallpaper gives a blue tint")
        let orange = OKLab.fromSRGB(SRGB.parse(WallpaperTint.tint(average: SIMD3(0.9, 0.5, 0.1)))!)
        XCTAssertGreaterThan(orange.z, 0, "an orange one an orange tint")
    }

    // CTX2: typing makes a little room (6 pt narrower, dimmer) in the ears; a menu softens the springs for 0.9 s.
    func testCTX2TypingMakesRoom() {
        var c = TargetContext()
        let t0 = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: Tuning(), context: c).resting(.compact)
        c.typing = true
        let t1 = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: Tuning(), context: c).resting(.compact)
        XCTAssertEqual(t1.mainHalfWidth, t0.mainHalfWidth - 6, accuracy: 0.001)
        XCTAssertLessThan(t1.glowIntensity, t0.glowIntensity)
        let idle0 = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: Tuning(), context: TargetContext()).resting(.card)
        let idle1 = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: Tuning(), context: c).resting(.card)
        XCTAssertEqual(idle0, idle1, "only the ears make room")
        // The drain: softened springs reach less far in the same time than the bouncy ones.
        let tuning = Tuning(), t = ShapeTargets(notchHalfWidth: 104, notchHeight: 37.5, tuning: tuning, context: TargetContext())
        func reach(soft: Bool) -> Double {
            let a = ShapeAnimator(initial: t.resting(.compact), configs: tuning.springs, dynamics: tuning.dynamics)
            a.snap(to: t.resting(.compact))
            if soft { a.soften(for: 0.9) }
            a.setTargets(t.resting(.idle), then: [])
            a.advance(0.1)
            return a.current.mainHalfWidth
        }
        XCTAssertGreaterThan(reach(soft: true), reach(soft: false) + 1, "the soft drain is slower")
    }

    // VINYL1: clicking the cover takes the record out; clicking again puts it back, and so does closing the player.
    func testVINYL1TheRecord() {
        let (d, _, _) = director()
        d.startMusic()
        d.pointerDown(at: .zero, hit: .ears)
        d.pointerUp(at: .zero, hit: .ears, corridor: false)
        XCTAssertTrue(d.groups.player)
        d.toggleVinyl()
        XCTAssertTrue(d.vinylOut)
        d.toggleVinyl()
        XCTAssertFalse(d.vinylOut)
        d.toggleVinyl()
        d.closeAsk()   // any close
        XCTAssertFalse(d.vinylOut, "it goes back in with the player")
    }

    // FOCUS1: a double-click's second press beside the notch grows the player into the focused view (it stays open);
    // on the notch itself it adds the tools.
    func testFOCUS1DoubleClickSplit() {
        let (d, _, _) = director()
        var real = 0.0
        d.realTime = { real }
        d.fetchLyrics = { _, _, _, _ in nil }
        d.startMusic()
        d.pointerDown(at: SIMD2(FrameModel.cx - 180, 18), hit: .ears)
        XCTAssertEqual(d.island.cardOwner, .media)
        real = 0.2
        d.pointerDown(at: SIMD2(FrameModel.cx - 180, 18), hit: nil)
        XCTAssertTrue(d.island.mediaFocus)
        XCTAssertTrue(d.groups.playerFocus)
        XCTAssertEqual(d.island.cardSize(player: CardSize(width: 372, height: 168, radius: 40)), Island.focusCard)
        XCTAssertTrue(d.island.holdsOpen, "it stays while you read")
        d.closeAsk()
        XCTAssertFalse(d.island.mediaFocus)
        real = 5
        d.pointerDown(at: SIMD2(FrameModel.cx - 180, 18), hit: .ears)
        real = 5.2
        d.pointerDown(at: SIMD2(FrameModel.cx, 18), hit: .ears)
        XCTAssertTrue(d.groups.tray, "on the notch: the tools")
        XCTAssertFalse(d.island.mediaFocus)
    }

    // LYR1: LRC lines with their times, several stamps on one line, the line being sung.
    func testLYR1ParseLyrics() {
        let lines = LyricsSource.parse("[00:01.50] first\n[00:04.00][00:20.00] chorus\n[00:08.25]\n")
        XCTAssertEqual(lines.map(\.time), [1.5, 4, 8.25, 20])
        XCTAssertEqual(lines.map(\.text), ["first", "chorus", "", "chorus"])
        let l = Lyrics(key: "k", lines: lines, plain: [])
        XCTAssertNil(l.current(at: 0.5))
        XCTAssertEqual(l.current(at: 4.1), 1)
        XCTAssertEqual(l.current(at: 30), 3)
    }

    // LYR2: LRCLIB keeps everyone's syncs, and its exact match can be a late one (11-07, Drake's "Jungle": 0.5-0.9 s
    // behind four syncs that agreed within 0.05 s; the owner saw the lyrics late). The one most others agree with wins,
    // copies counted once; only the song's own length (±2 s) counts; a different version's timings are never used.
    func testLYR2ConsensusTiming() {
        func entry(_ shift: Double, _ duration: Double?, jitter: [Double] = []) -> LyricsEntry {
            let texts = ["rock me", "put a bib", "just like a baby", "the things you do", "these days"]
            return LyricsEntry(duration: duration, lines: texts.enumerated().map { i, t in
                LyricLine(time: Double(i) * 5 + 10 + shift + (i < jitter.count ? jitter[i] : 0), text: t)
            }, plain: [])
        }
        let late = entry(0.8, 320)
        let agreeing = [entry(0, 320), entry(0.03, 320.4, jitter: [0.01]), entry(-0.02, 321, jitter: [0, 0.02])]
        // The late one first (it's the exact match) and copied three more times.
        let picked = LyricsSource.best([late, late, late, late] + agreeing, duration: 320.4)
        XCTAssertEqual(picked?.lines.first?.time ?? 0, 10, accuracy: 0.05)
        // A version of another length is skipped, even when it's the only sync: its words stay, without timings.
        let other = LyricsSource.best([entry(-3, 280)], duration: 320.4)
        XCTAssertEqual(other?.lines, [])
        XCTAssertEqual(other?.plain.first, "rock me")
        // Unknown length: everything counts.
        XCTAssertEqual(LyricsSource.best([entry(0, 280)], duration: nil)?.lines.count, 5)
        XCTAssertNil(LyricsSource.best([], duration: 320))
    }

    // LYR3: a player's clock steps back a little after a seek or a skip (Spotify re-reports ~1.2 s later, when the sound
    // really resumes): the line holds instead of flicking back; a real seek back moves at once.
    func testLYR3LineHoldsThroughSmallCorrections() {
        let l = Lyrics(key: "k", lines: [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b"), LyricLine(time: 30, text: "c")], plain: [])
        XCTAssertEqual(l.line(from: 1, at: 19.2), 1, "1.2 s back: holds")
        XCTAssertEqual(l.line(from: 1, at: 12), 0, "8 s back: a seek")
        XCTAssertEqual(l.line(from: 0, at: 21), 1)
        XCTAssertEqual(l.line(from: nil, at: 21), 1)
        XCTAssertEqual(l.line(from: 2, at: 31), 2)
    }

    // CLOCK1 (owner, 11-07: "still very delayed"): Spotify reports a seek, a skip or a resume at once and again ~1.1 s
    // later with the same elapsed and a newer timestamp (seen in every seek of the owner's log). The repeat only re-stamps
    // it; following it put the lyrics ~1.1 s behind the music. A stale first report (a resume stamped with the pause's
    // time) is still replaced by the next one.
    func testCLOCK1RestampedReportsKeepTheClock() {
        let (d, _, _) = director()
        let t0 = Date(timeIntervalSince1970: 1000)
        var now = t0
        d.date = { now }
        func report(_ elapsed: Double, at stamp: Date, playing: Bool = true) -> NowPlaying {
            NowPlaying(title: "Jungle", artist: "Drake", bundleID: "com.spotify.client", playing: playing, duration: 320,
                       elapsed: elapsed, timestamp: stamp)
        }
        // A seek to 104.21, received 0.13 s after it happened; its repeat 1.1 s later.
        now = t0.addingTimeInterval(0.13)
        d.nowPlayingChanged(report(104.21, at: t0))
        now = t0.addingTimeInterval(1.24)
        d.nowPlayingChanged(report(104.21, at: t0.addingTimeInterval(1.11)))
        now = t0.addingTimeInterval(5)
        XCTAssertEqual(d.elapsed, 109.21, accuracy: 0.01, "the first report's clock")
        // A resume stamped with the pause's time (stale on arrival) gives way to the fresh one after it.
        let t1 = t0.addingTimeInterval(100)
        now = t1
        d.nowPlayingChanged(report(150, at: t1, playing: false))
        now = t1.addingTimeInterval(2)
        d.nowPlayingChanged(report(150, at: t1))               // playing, but stamped 2 s ago
        now = t1.addingTimeInterval(2.13)
        d.nowPlayingChanged(report(150, at: t1.addingTimeInterval(2)))
        now = t1.addingTimeInterval(2.7)
        d.nowPlayingChanged(report(150, at: t1.addingTimeInterval(2.55)))   // its repeat
        now = t1.addingTimeInterval(4)
        XCTAssertEqual(d.elapsed, 152, accuracy: 0.01)
        // A real move (another elapsed) always takes over.
        d.nowPlayingChanged(report(30, at: now))
        XCTAssertEqual(d.elapsed, 30, accuracy: 0.01)
    }

    // FOCUS2 (owner, 11-07: "if I click something then try to open the lyrics, it doesn't, I have to close and open it …
    // sometimes I click on the music card and it doesn't open"): one click on the open player's card opens the lyrics; a
    // drag (the rubber band) doesn't.
    func testFOCUS2ClickOnTheOpenPlayer() {
        let (d, _, _) = director()
        var real = 0.0
        d.realTime = { real }
        d.fetchLyrics = { _, _, _, _ in nil }
        d.startMusic()
        d.pointerDown(at: SIMD2(FrameModel.cx - 180, 18), hit: .ears)
        d.pointerUp(at: SIMD2(FrameModel.cx - 180, 18), hit: .ears, corridor: false)
        real = 3   // later than a double-click
        XCTAssertEqual(d.island.cardOwner, .media)
        XCTAssertFalse(d.island.mediaFocus, "the click that opened the player is its own")
        d.pointerDown(at: SIMD2(FrameModel.cx + 90, 80), hit: .card)
        d.pointerDragged(to: SIMD2(FrameModel.cx + 90, 100))
        d.pointerUp(at: SIMD2(FrameModel.cx + 90, 100), hit: .card, corridor: false)
        XCTAssertFalse(d.island.mediaFocus, "a drag isn't a click")
        d.pointerDown(at: SIMD2(FrameModel.cx + 90, 80), hit: .card)
        d.pointerUp(at: SIMD2(FrameModel.cx + 90, 80), hit: .card, corridor: false)
        XCTAssertTrue(d.island.mediaFocus, "one click on the card opens the lyrics")
    }
}
