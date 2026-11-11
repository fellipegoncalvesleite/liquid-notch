import XCTest
import IslandCore

/// The simulator's arbitration probes (`MEDIA1`, `CTX1`, the reducer side of `ACTS`, `PT7`, `REPLY1`),
/// replayed as event traces on the pure model.
final class IslandTests: XCTestCase {
    private func island(media: Bool = true) -> Island {
        var i = Island()
        if media { i.apply(.startMedia) }
        return i
    }

    // MEDIA1: media shares the island.
    func testOngoingGoesToTheBubbleWhileMediaPlays() {
        var i = island()
        XCTAssertEqual(i.mode, .compact)
        i.apply(.show(.timer))
        XCTAssertEqual(i.arrangement.ears, .media)
        XCTAssertEqual(i.arrangement.balls, [.activity])
        XCTAssertEqual(i.mode, .duo)
        let g = i.groups(.duo)
        XCTAssertTrue(g.musicEars)
        XCTAssertEqual(g.bubble, .activity)
        XCTAssertFalse(g.activityEars)
    }

    // Since 11-06 a transient takes the ears and whoever it displaced waits in a ball (it no longer hides everyone).
    func testTransientBorrowsTheEarsAndHandsBack() {
        var i = island()
        i.apply(.show(.timer))
        let timer = i.activity!.serial
        let fx = i.apply(.show(.airpods))
        XCTAssertEqual(i.activity?.id, .airpods)
        XCTAssertEqual(i.background.map(\.id), [.timer])
        XCTAssertEqual(i.arrangement.ears, .activity)
        XCTAssertEqual(i.arrangement.balls, [.media, .background(timer)])
        XCTAssertTrue(i.groups(i.mode).activityEars)
        XCTAssertFalse(i.groups(i.mode).musicEars)
        XCTAssertTrue(fx.contains { if case .armTransient(_, 5) = $0 { true } else { false } })
        i.apply(.endActivity)
        XCTAssertEqual(i.activity?.id, .timer)
        XCTAssertEqual(i.mode, .duo)
        XCTAssertTrue(i.background.isEmpty)
    }

    func testLiveCallTakesTheEarsAndMediaMovesToTheBubble() {
        var i = island()
        i.apply(.show(.call, opened: false))
        XCTAssertEqual(i.arrangement.ears, .activity)
        XCTAssertEqual(i.arrangement.balls, [.media])
        XCTAssertEqual(i.mode, .duo)
        XCTAssertEqual(i.groups(.duo).bubble, .media)
        // Clicking the bubble opens media's card.
        i.apply(.open(.media))
        XCTAssertEqual(i.mode, .card)
        XCTAssertEqual(i.cardOwner, .media)
        let g = i.groups(.card)
        XCTAssertTrue(g.player)
        XCTAssertFalse(g.activityCard)
        XCTAssertEqual(g.bubble, .activity)
        XCTAssertEqual(i.cardSize(player: CardSize(width: 372, height: 148, radius: 34)).height, 148)
    }

    func testAlertOpensItselfAndHandsBackTheCall() {
        var i = island()
        i.apply(.show(.recording))
        i.apply(.show(.incoming))
        XCTAssertTrue(i.opened)
        XCTAssertTrue(i.holdsOpen)          // PT7: stays open until its buttons, the notch or a click outside
        XCTAssertEqual(i.mode, .card)
        XCTAssertEqual(i.background.map(\.id), [.recording])
        i.apply(.endActivity)
        XCTAssertEqual(i.activity?.id, .recording)
        XCTAssertFalse(i.opened)
    }

    func testNotificationOverTheOpenPlayerHandsItBack() {
        var i = island()
        i.apply(.open(.media))
        i.apply(.pointer(onLiquid: true))
        i.apply(.show(.messages))
        XCTAssertEqual(i.activity?.resume, true)
        i.apply(.endActivity)
        XCTAssertTrue(i.opened)
        XCTAssertEqual(i.mode, .card)
        XCTAssertEqual(i.cardOwner, .media)
    }

    func testTransientExpiryWaitsWhileItsCardIsOpen() {
        var i = island()
        i.apply(.show(.charging))
        let serial = i.activity!.serial
        i.apply(.open(.activity))
        i.apply(.transientExpired(serial: serial))
        XCTAssertEqual(i.activity?.id, .charging)
        let fx = i.apply(.close)
        XCTAssertEqual(fx, [.armTransient(serial: serial, seconds: 2)])
        i.apply(.transientExpired(serial: serial))
        XCTAssertNil(i.activity)
        XCTAssertEqual(i.mode, .compact)
    }

    // ACTS: every activity alone has ears, then its own card; ending hands back to music.
    func testEveryActivityHasEarsAndItsOwnCard() {
        for id in ActivityID.allCases {
            var i = island(media: false)
            i.apply(.show(id, opened: false))
            XCTAssertEqual(i.mode, .compact, "\(id)")
            XCTAssertTrue(i.groups(.compact).activityEars, "\(id)")
            i.apply(.open(.activity))
            XCTAssertEqual(i.mode, .card, "\(id)")
            XCTAssertTrue(i.groups(.card).activityCard, "\(id)")
            XCTAssertEqual(i.cardSize(player: CardSize(width: 1, height: 1, radius: 1)), ActivitySpec[id].card)
            i.apply(.startMedia)
            i.apply(.endActivity)
            XCTAssertEqual(i.mode, .compact)
            XCTAssertTrue(i.groups(.compact).musicEars)
        }
    }

    // CTX1: where you are on the Mac.
    func testContextRules() {
        var i = island()
        i.apply(.context(DesktopContext(fullscreen: true)))
        XCTAssertEqual(i.mode, .idle)
        i.apply(.context(DesktopContext(menuOpen: true)))
        XCTAssertEqual(i.mode, .idle)
        i.apply(.context(DesktopContext()))
        XCTAssertEqual(i.mode, .compact)

        // Typing: nothing opens by itself; the liquid nudges.
        i.apply(.context(DesktopContext(typing: true)))
        let fx = i.apply(.show(.incoming))
        XCTAssertFalse(i.opened)
        XCTAssertEqual(i.activity?.id, .incoming)
        XCTAssertTrue(fx.contains(.nudge))
        i.apply(.endActivity)

        // Presenting: transients stay off, and showing an alert is redacted (the view reads `presenting`).
        i.apply(.context(DesktopContext(sharing: true)))
        i.apply(.show(.airpods))
        XCTAssertNil(i.activity)
        XCTAssertTrue(i.context.presenting)
        i.apply(.context(DesktopContext(frontmostApp: BundleID.keynote)))
        XCTAssertTrue(i.context.presenting)

        // Going into presenting ends a transient that is showing.
        i.apply(.context(DesktopContext()))
        i.apply(.show(.messages))
        i.apply(.context(DesktopContext(sharing: true)))
        XCTAssertNil(i.activity)

        // The activity's own app in front takes that party off the island.
        i.apply(.context(DesktopContext(frontmostApp: BundleID.music)))
        XCTAssertEqual(i.mode, .idle)
        i.apply(.show(.timer))
        XCTAssertEqual(i.arrangement.ears, .activity)
        XCTAssertEqual(i.mode, .compact)
        i.apply(.endActivity)
        i.apply(.context(DesktopContext(frontmostApp: BundleID.safari)))
        i.apply(.show(.download))
        XCTAssertEqual(i.arrangement.ears, .media)
        XCTAssertTrue(i.arrangement.balls.isEmpty)
    }

    func testAlertStillShowsOverFullscreen() {
        var i = island()
        i.apply(.context(DesktopContext(fullscreen: true)))
        i.apply(.show(.incoming))
        XCTAssertEqual(i.mode, .card)
    }

    func testMenuClosesAnOpenCard() {
        var i = island()
        i.apply(.open(.media))
        i.apply(.context(DesktopContext(menuOpen: true)))
        XCTAssertFalse(i.opened)
        i.apply(.context(DesktopContext()))
        XCTAssertEqual(i.mode, .compact)
    }

    func testHUDTakesOverAndHandsBack() {
        var i = island()
        i.apply(.show(.timer))
        i.apply(.hud(.volume))
        XCTAssertEqual(i.mode, .hud)
        XCTAssertTrue(i.groups(.hud).hud)
        XCTAssertFalse(i.groups(.hud).musicEars)
        i.apply(.hudEnded)
        XCTAssertEqual(i.mode, .duo)
    }

    func testStoppingMediaDropsAnAlertInFlight() {
        var i = island()
        i.apply(.hud(.volume))
        i.apply(.stopMedia)
        XCTAssertEqual(i.mode, .idle)
    }

    func testTakeoverSqueezeOnlyFromTheEars() {
        var i = island(media: false)
        XCTAssertFalse(i.apply(.show(.timer)).contains(.takeover))   // from nothing it pours instead
        XCTAssertTrue(i.apply(.show(.charging)).contains(.takeover))
    }

    // BUB1: a call while recording keeps the recording; answering it keeps the call in the ears and the recording
    // in a ball; hanging up hands the ears back to the recording.
    func testCallWhileRecordingKeepsTheRecording() {
        var i = island()
        i.apply(.show(.recording))
        let rec = i.activity!.serial
        i.apply(.show(.incoming, opened: false))
        XCTAssertEqual(i.activity?.id, .incoming)
        XCTAssertEqual(i.arrangement.balls, [.background(rec), .media])
        i.apply(.show(.call, opened: false))
        XCTAssertEqual(i.activity?.id, .call)
        XCTAssertEqual(i.background.map(\.id), [.recording])
        i.apply(.endActivity)
        XCTAssertEqual(i.activity?.id, .recording)
        XCTAssertEqual(i.arrangement.balls, [.media])
    }

    // Round 2: two balls at most, the rest of what deserves one in the +N ball; places are kept.
    func testTwoBallsThenMoreAndPlacesAreKept() {
        var i = island()
        i.apply(.show(.recording))
        i.apply(.show(.timer))
        i.apply(.show(.camera))
        let a = i.arrangement
        XCTAssertEqual(a.ears, .activity)
        XCTAssertEqual(a.balls.count, 3)
        XCTAssertEqual(a.balls.last, .more)
        XCTAssertEqual(a.overflow.count, 1)
        XCTAssertEqual(i.mode, .duo)
        let places = i.balls(.duo)
        XCTAssertEqual(places[2], .more)
        // The party in the left place stays there when the right one leaves; the one from the +N ball takes the right.
        let left = places[1]!
        if let s = i.instance(places[0]!)?.serial { i.apply(.end(serial: s)) } else { i.apply(.stopMedia) }
        XCTAssertEqual(i.balls(i.mode)[1], left)
        XCTAssertNotNil(i.balls(i.mode)[0])
        XCTAssertNil(i.balls(i.mode)[2])
        // With one ball left it sits right.
        if let s = i.instance(i.balls(i.mode)[0]!)?.serial { i.apply(.end(serial: s)) } else { i.apply(.stopMedia) }
        XCTAssertEqual(i.balls(i.mode)[0], left)
        XCTAssertNil(i.balls(i.mode)[1])
    }

    // A paused song and a download get no ball; they're in the list.
    func testNoBallForAPausedSongOrADownload() {
        var i = island()
        i.apply(.show(.call, opened: false))
        i.apply(.playback(false))
        i.apply(.show(.download))
        let a = i.arrangement
        XCTAssertTrue(a.balls.isEmpty)
        XCTAssertEqual(a.quiet.count, 2)
        XCTAssertEqual(i.mode, .compact)
        i.apply(.open(.more))
        XCTAssertEqual(i.cardOwner, .more)
        XCTAssertTrue(i.groups(.card).moreList)
        XCTAssertEqual(i.cardSize(player: CardSize(width: 1, height: 1, radius: 1)).height, 32 + 2 * 44)
    }

    // The list holds everything not in a ball while it's open, even one the ears' party pushed out of its ball.
    func testTheListHoldsWhatTheEarsPushedOut() {
        var i = island()
        i.apply(.show(.recording))
        i.apply(.show(.call, opened: false))
        i.apply(.show(.timer))
        i.apply(.show(.camera))
        i.apply(.hide(.media))
        i.apply(.open(.more))
        let inBalls = Set(i.balls(.card).compactMap { $0 })
        let everyone = Set(i.arrangement.all.filter { !i.arrangement.hidden.contains($0) })
        XCTAssertEqual(inBalls.subtracting([.more]).union(i.listParties), everyone)
        XCTAssertEqual(i.arrangement.hidden, [.media])
    }

    // A ball's own hover (owner, 11-06): it peeks while the ears stay as they are; never while a card is open; opening
    // a card or leaving ends it; the +N ball only swells (its list opens on a press).
    func testABallPeeksOnItsOwn() {
        var i = island()
        i.apply(.show(.timer))
        XCTAssertEqual(i.mode, .duo)
        i.apply(.hover)
        i.apply(.peekBall(.activity))
        XCTAssertEqual(i.peekBall, .activity)
        XCTAssertFalse(i.hovered, "the ears' hover gives way")
        XCTAssertEqual(i.mode, .duo)
        XCTAssertEqual(i.groups(.duo).peekPlace, 0)
        XCTAssertNil(i.groups(.compact).peekPlace)
        i.apply(.unhover)
        XCTAssertNil(i.peekBall)
        i.apply(.peekBall(.activity))
        i.apply(.open(.activity))
        XCTAssertNil(i.peekBall)
        XCTAssertEqual(i.cardOwner, .activity)
        i.apply(.peekBall(.media))
        XCTAssertNil(i.peekBall, "not while a card is open")
        i.apply(.close)

        var j = island()
        j.apply(.show(.recording))
        j.apply(.show(.call, opened: false))
        j.apply(.show(.timer))
        j.apply(.show(.camera))
        XCTAssertEqual(j.arrangement.balls.last, .more)
        j.apply(.peekBall(.more))
        XCTAssertNil(j.groups(j.mode).peekPlace)
    }

    // Claude or Codex in the ears previews on hover, like a song (sim `wantedMode`, owner 11-06: "when claude is on the
    // top bar, hovering should still do something"); an activity in the ears doesn't. A ball's own hover still wins.
    func testAgentsInTheEarsPreviewOnHover() {
        var i = island(media: false)
        i.apply(.agent(AgentHook(provider: .claude, event: "UserPromptSubmit", sessionID: "c1", cwd: "/x/liquid-notch")))
        XCTAssertEqual(i.arrangement.ears, .agents(.claude))
        XCTAssertEqual(i.mode, .compact)
        XCTAssertNil(i.groups(.compact).agentsPeek)
        i.apply(.hover)
        XCTAssertEqual(i.mode, .peek)
        let g = i.groups(.peek)
        XCTAssertEqual(g.agentsEars, .claude, "the ball and the word stay in the ears")
        XCTAssertEqual(g.agentsPeek, .claude)
        XCTAssertFalse(g.peek, "not the song's row")
        i.apply(.unhover)
        XCTAssertEqual(i.mode, .compact)

        // It asks to run something while a song plays: Claude keeps the ears, the song waits in a ball, the preview
        // keeps the ball and isn't the song's.
        i.apply(.startMedia)
        i.apply(.agent(AgentHook(provider: .claude, event: "PermissionRequest", sessionID: "c1", cwd: "/x/liquid-notch",
                                 tool: "Bash", detail: "swift test")))
        XCTAssertEqual(i.arrangement.ears, .agents(.claude))
        i.apply(.hover)
        XCTAssertEqual(i.mode, .peek)
        XCTAssertEqual(i.groups(.peek).balls[0], .media)
        XCTAssertFalse(i.groups(.peek).peek)
        XCTAssertFalse(i.groups(.peek).musicEars)
        i.apply(.peekBall(.media))
        XCTAssertEqual(i.mode, .duo, "the ball's own hover, not the ears'")
        XCTAssertNil(i.groups(.duo).agentsPeek)
        i.apply(.open(.agents(.claude)))
        XCTAssertEqual(i.mode, .card)
        XCTAssertNil(i.groups(.card).agentsPeek)
        i.apply(.close)

        var j = island(media: false)
        j.apply(.show(.timer))
        XCTAssertEqual(j.arrangement.ears, .activity)
        j.apply(.hover)
        XCTAssertEqual(j.mode, .compact, "an activity in the ears doesn't preview (as in the sim)")
    }

    // A session that needs you shows only its question on hover (owner, 11-06: "if i hover, only the question"): a small
    // card; a press grows it into the chat; answering or leaving closes it; with nothing to ask it doesn't open.
    func testAQuestionOpensOnHover() {
        let player = CardSize(width: 372, height: 168, radius: 34)
        var i = island(media: false)
        i.apply(.agent(AgentHook(provider: .claude, event: "PermissionRequest", sessionID: "c1", cwd: "/x/liquid-notch",
                                 tool: "Bash", detail: "swift test")))
        XCTAssertEqual(i.arrangement.ears, .agents(.claude))
        i.apply(.openQuestion(.agents(.claude)))
        XCTAssertEqual(i.mode, .card)
        XCTAssertTrue(i.questionOnly)
        XCTAssertEqual(i.groups(.card).agentsCard, .claude)
        XCTAssertTrue(i.groups(.card).agentsQuestion)
        XCTAssertEqual(i.cardSize(player: player), Island.agentsQuestionCard(.permission(tool: "Bash", detail: "swift test")))
        XCTAssertEqual(i.cardSize(player: player).width, Island.agentsCard(nil).width, "the chat grows from it downwards")

        i.apply(.showCard(.agents(.claude)))   // a press: the chat, the question inside it
        XCTAssertTrue(i.opened)
        XCTAssertFalse(i.questionOnly)
        XCTAssertFalse(i.groups(.card).agentsQuestion)
        XCTAssertEqual(i.cardSize(player: player), Island.agentsCard(nil))
        i.apply(.close)

        i.apply(.openQuestion(.agents(.claude)))
        i.apply(.unhover)
        XCTAssertFalse(i.opened)
        XCTAssertFalse(i.questionOnly, "leaving closes it")

        i.apply(.openQuestion(.agents(.claude)))
        i.apply(.agentAnswered("c1"))
        XCTAssertFalse(i.opened, "answered: nothing left to show")
        XCTAssertFalse(i.questionOnly)
        i.apply(.openQuestion(.agents(.claude)))
        XCTAssertFalse(i.opened, "a working session has no question")
    }

    // MENU1: Hide takes a party off the island for this occurrence; the next takes its place; Show brings it back.
    // Alerts and transients can't be hidden; a hidden song comes back when the track changes.
    func testHideAndShow() {
        var i = island()
        i.apply(.show(.timer))
        XCTAssertEqual(i.arrangement.balls, [.activity])
        i.apply(.hide(.activity))
        XCTAssertTrue(i.arrangement.balls.isEmpty)
        XCTAssertEqual(i.arrangement.hidden, [.activity])
        XCTAssertEqual(i.mode, .compact)
        i.apply(.unhide(.activity))
        XCTAssertEqual(i.arrangement.balls, [.activity])
        i.apply(.hide(.media))
        XCTAssertEqual(i.arrangement.ears, .activity)
        i.apply(.trackChanged)
        XCTAssertEqual(i.arrangement.ears, .media)
        i.apply(.show(.incoming, opened: false))
        XCTAssertFalse(i.hideable(.activity))
        i.apply(.hide(.activity))
        XCTAssertEqual(i.activity?.id, .incoming)
        XCTAssertEqual(i.arrangement.ears, .activity)
    }

    // A transient in a ball still leaves on time; ending a ball's activity leaves the ears alone.
    func testEndingABallsActivity() {
        var i = island(media: false)
        i.apply(.show(.call, opened: false))
        i.apply(.show(.timer))
        XCTAssertEqual(i.activity?.id, .call)
        let timer = i.background[0].serial
        XCTAssertEqual(i.arrangement.balls, [.background(timer)])
        i.apply(.open(.background(timer)))
        XCTAssertEqual(i.cardActivity?.id, .timer)
        XCTAssertEqual(i.cardSize(player: CardSize(width: 1, height: 1, radius: 1)), ActivitySpec[.timer].card)
        i.apply(.end(serial: timer))
        XCTAssertFalse(i.opened)
        XCTAssertEqual(i.activity?.id, .call)
        XCTAssertTrue(i.background.isEmpty)
    }

    // MEDIA2 (owner, 11-11: "if I have a video and a music one of them go to the ball"): the song keeps the ears, the
    // second player waits in a ball, leaves while its own app is in front, opens its own card, and goes when it stops.
    func testASecondPlayerWaitsInABall() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.startMedia2("com.google.Chrome"))
        XCTAssertEqual(i.arrangement.ears, .media)
        XCTAssertEqual(i.arrangement.balls, [.media2])
        i.apply(.context(DesktopContext(frontmostApp: "com.google.Chrome")))
        XCTAssertTrue(i.arrangement.balls.isEmpty, "in its own tab it leaves")
        i.apply(.context(DesktopContext()))
        i.apply(.open(.media2))
        XCTAssertEqual(i.cardOwner, .media2)
        XCTAssertTrue(i.groups(.card).player)
        i.apply(.stopMedia2)
        XCTAssertFalse(i.opened)
        XCTAssertTrue(i.arrangement.balls.isEmpty)
    }

    // TAB1 (owner, 11-11: "make the media become a ball if you're not in its tab"): in a browser, a player leaves the
    // island only on its own tab; on another tab of the same browser it stays (here, in a ball beside the song).
    func testAVideoLeavesOnlyOnItsOwnTab() {
        var i = Island()
        i.apply(.startMedia)
        i.apply(.startMedia2("com.google.Chrome"))
        i.media2Title = "JYNXZI INSANE CHESS TOURNAMENT *GOTHAM REACTS*"
        var c = DesktopContext(frontmostApp: "com.google.Chrome")
        c.frontWindowTitle = "(1) JYNXZI INSANE CHESS TOURNAMENT *GOTHAM REACTS* - YouTube - Google Chrome"
        i.apply(.context(c))
        XCTAssertTrue(i.arrangement.balls.isEmpty, "on its own tab it leaves")
        c.frontWindowTitle = "WhatsApp - Google Chrome"
        i.apply(.context(c))
        XCTAssertEqual(i.arrangement.balls, [.media2], "another tab: it's back in its ball")
    }
}
