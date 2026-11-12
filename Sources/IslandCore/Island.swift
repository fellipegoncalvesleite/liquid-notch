/// What the presentation layer turns into a shape.
public enum PresentationMode: String, CaseIterable, Sendable {
    /// Invisible: the liquid sits inside the hardware notch.
    case idle
    /// Ears beside the notch (media: art left, bars right; or an activity's closed view).
    case compact
    /// Hover preview: the ears swell and grow a lip under the notch.
    case peek
    /// The old attached player. Debug only now: opening shows the card.
    case expanded
    /// More than one party: the ears plus balls beside them (two at most, and a small +N ball).
    case duo
    /// Volume or brightness briefly takes over the ears.
    case hud
    /// A droplet with no content. Debug only, for judging the drip.
    case split
    /// An open card below the notch.
    case card
}

/// Who sits in a place on the island (`docs/superpowers/specs/2026-11-06-many-bubbles-design.md`).
public enum Party: Hashable, Sendable {
    case media
    /// A second player playing at the same time (a video beside a song; owner, 11-11): it waits in a ball, with its own
    /// preview and player card.
    case media2
    /// The best visible activity (`Island.activity`): the one that can hold the ears.
    case activity
    /// Another activity still running, by its showing's serial (`Island.background`).
    case background(Int)
    /// The small ball that holds what deserves a ball but has no room (+N); its card is the list.
    case more
    /// A provider's agent sessions (Claude, Codex): one ball each.
    case agents(AgentProvider)
}

public enum HUDKind: Sendable, Equatable {
    case volume, brightness
}

/// Where you are on the Mac: the debug panel's controls, or the `ContextMonitor` (P3).
public struct DesktopContext: Equatable, Sendable {
    public var frontmostApp: String
    /// A fullscreen window is frontmost (video or app): the island hides; alerts and the HUD still show.
    public var fullscreen: Bool
    /// A menu is open under the menu bar: the ears pull back so they never cover it.
    public var menuOpen: Bool
    /// Typed within the last moments: nothing opens its card by itself.
    public var typing: Bool
    /// Sharing the screen.
    public var sharing: Bool
    /// The screen is locked or asleep.
    public var locked: Bool
    /// The lock screen is up (`com.apple.screenIsLocked` to `…Unlocked`): the island shows there (11-07 design).
    public var lockScreen: Bool
    /// The agent session you're looking at in its app (the Claude app in front, on that session): it leaves the island;
    /// the others stay, so you can answer them from the notch (owner, 11-07).
    public var viewedSession: String?
    /// Something is using the microphone or a camera (for calls and the filming indicator, P4).
    public var micInUse: Bool
    public var cameraInUse: Bool
    /// A Focus is on (nil: not readable).
    public var focusOn: Bool?
    /// Which one, and its symbol, when macOS's Focus database is readable (Full Disk Access); nil otherwise.
    public var focusName: String?
    public var focusSymbol: String?
    /// The front window's title while a browser is in front (its active tab): a player in that browser leaves the
    /// island only while you're on its own tab (owner, 11-11).
    public var frontWindowTitle: String?
    /// The frontmost app's front window is on screen on the island's display (11-11). False when it's on another
    /// display, or when the app has no window on screen (minimized, hidden): you aren't looking at it from here. Only
    /// where a player plays reads it (`inOwnPlace`); what's playing never depends on windows or displays.
    public var frontOnIslandScreen = true

    public init(frontmostApp: String = BundleID.finder, fullscreen: Bool = false, menuOpen: Bool = false,
                typing: Bool = false, sharing: Bool = false, locked: Bool = false, micInUse: Bool = false,
                cameraInUse: Bool = false, focusOn: Bool? = nil, lockScreen: Bool = false, viewedSession: String? = nil) {
        self.frontmostApp = frontmostApp
        self.fullscreen = fullscreen
        self.menuOpen = menuOpen
        self.typing = typing
        self.sharing = sharing
        self.locked = locked
        self.micInUse = micInUse
        self.cameraInUse = cameraInUse
        self.focusOn = focusOn
        self.lockScreen = lockScreen
        self.viewedSession = viewedSession
    }

    /// You're at `app`: it's in front and its front window is mostly on the island's display (11-11). On the other
    /// display, or minimized, you aren't. Everything that leaves the island because you're in its own app asks this.
    public func at(_ app: String) -> Bool { frontmostApp == app && frontOnIslandScreen }

    /// The app you're at shows this activity itself (`AppRules.hosts`).
    public func hosts(_ id: ActivityID) -> Bool { at(frontmostApp) && AppRules.hosts(frontmostApp, id) }

    /// Sharing the screen or a presenting app in front: transients stay off, names and texts are redacted.
    public var presenting: Bool { sharing || AppRules.presenting.contains(frontmostApp) }
}

/// One showing of an activity. `serial` tells showings apart (entrance animations, timers).
public struct ActivityInstance: Equatable, Sendable {
    public var id: ActivityID
    public var serial: Int
    /// The player was open when this arrived: hand it back when this leaves.
    public var resume: Bool
    /// Hidden from the island's menu, until it ends.
    public var hidden = false
    /// Worth no ball for now (a meeting more than 5 minutes away). The director says so.
    public var quiet = false

    public var spec: ActivitySpec { ActivitySpec[id] }
}

/// The priority queue (sim `arrange()`, round 2): who holds the ears, who gets a ball, and what waits off the island.
public struct Arrangement: Equatable, Sendable {
    public var ears: Party?
    /// The balls, best first: two at most, then `.more` when `overflow` isn't empty.
    public var balls: [Party] = []
    /// Worth a ball, no room: in the +N ball's list.
    public var overflow: [Party] = []
    /// Never a ball (a paused song, a download, a far meeting): in the list and the menu.
    public var quiet: [Party] = []
    /// Hidden from the menu, for this occurrence.
    public var hidden: [Party] = []
    /// Everything running, ranked, hidden ones included.
    public var all: [Party] = []

    /// The first ball (the one beside the right ear).
    public var bubble: Party? { balls.first }
}

/// Which content groups show, for a mode.
public struct ContentGroups: Equatable, Sendable {
    /// Media's art and bars (in the ears, travelling into the player card).
    public var musicEars = false
    public var peek = false
    /// The player's text and controls (card or expanded).
    public var player = false
    /// The focused view of a video: the video itself, mirrored from its tab (owner, 11-11).
    public var videoFocus = false
    /// The focused player (double-click on the music, owner 11-07): big cover, synced lyrics, controls.
    public var playerFocus = false
    public var hud = false
    /// The activity's closed view in the ears.
    public var activityEars = false
    public var activityCard = false
    /// The tray's tools (with the player beside them when `player` is on too).
    public var tray = false
    /// Who each place shows: 0 right of the ears, 1 left, 2 the +N ball.
    public var balls: [Party?] = [nil, nil, nil]
    /// The +N ball's list is open.
    public var moreList = false
    /// An agent provider holds the ears, or its card is open.
    public var agentsEars: AgentProvider?
    public var agentsCard: AgentProvider?
    /// The agents' card shows only the question (opened by a hover).
    public var agentsQuestion = false
    /// The quick-ask card is open, asking this provider (agents phase 3).
    public var agentsAsk: AgentProvider?
    /// The ears' hover preview when a provider holds them: its session's row in the lip (sim `agPeek`).
    public var agentsPeek: AgentProvider?
    /// The place of the ball under the pointer, showing its peek (its party is `balls[peekPlace]`); the ears stay as
    /// they are.
    public var peekPlace: Int?
    /// Who the first ball's glyph shows.
    public var bubble: Party? { balls[0] }

    public init() {}
}

public enum IslandEvent: Sendable, Equatable {
    case startMedia
    case stopMedia
    /// A second player plays (its app), or stopped.
    case startMedia2(String)
    case stopMedia2
    /// Put an activity on the island. `opened` forces its card open or shut (nil: its own rule).
    case show(ActivityID, opened: Bool? = nil)
    /// Ends the best activity.
    case endActivity
    /// Ends this showing, wherever it is (the ears, a ball, off the island).
    case end(serial: Int)
    /// From the island's menu: off the island for this occurrence, or back.
    case hide(Party)
    case unhide(Party)
    /// Media paused or playing (a paused song gets no ball); the song changed (a hidden song comes back).
    case playback(Bool)
    case trackChanged
    /// Worth a ball or not, for a showing (a meeting more than 5 minutes away isn't).
    case quiet(serial: Int, Bool)
    /// An agent hook call; a session answered from the notch; a session's card was read.
    case agent(AgentHook)
    case agentAnswered(String)
    case agentRead(String)
    /// A transient's time ran out (ignored if that showing has gone or its card is open).
    case transientExpired(serial: Int)
    /// The pointer arrived on the liquid: the hover preview.
    case hover
    /// The pointer left and the linger ran out.
    case unhover
    /// The pointer is on a ball (nil: off it): the ball's own hover, its peek; the ears stay as they are (owner, 11-06).
    case peekBall(Party?)
    /// A press opened a card for this party.
    case open(Party)
    /// The pointer arrived on a provider whose session needs you: its card opens on the question alone (owner, 11-06:
    /// "if i hover, only the question"); a press grows it into the chat (`showCard`).
    case openQuestion(Party)
    /// Quick ask (agents phase 3): the card opens on a field that asks this provider, on the empty notch too, or the open
    /// chat turns into it in place (its `+`).
    case openAsk(AgentProvider)
    /// Open this party's card now, open or not (from the island's menu or the +N list).
    case showCard(Party)
    /// The tray: on the empty notch, its tools; with media, the player's card with the tools beside it (a second
    /// click on the player, owner 11-01: one click for the music, two for the music and the tools).
    /// Over an activity, Claude or Codex in the ears, the tools open and it waits in a ball (owner, 11-11).
    case openTray
    /// Your day, large (a click on the event card or its ball's peek): the tools at the lyrics player's size, on the day.
    case openDay
    /// The day's page left (Back): the tools go back to their own size.
    case closeDay
    /// Double-click on the music (owner, 11-07): the player grows into the focused view with the lyrics.
    case focusMedia
    case close
    case context(DesktopContext)
    case hud(HUDKind)
    case hudEnded
    case pointer(onLiquid: Bool)
}

/// What the shell should do after an event, besides following the new mode.
public enum IslandEffect: Sendable, Equatable {
    /// End this showing after `seconds`, unless its card is open then.
    case armTransient(serial: Int, seconds: Double)
    /// An alert arrived while typing: the liquid nudges instead of opening.
    case nudge
    /// An activity took over the ears from the ears: a squeeze of the liquid.
    case takeover
    /// Names and texts changed privacy: re-render the activity's content.
    case redact
}

/// The island's state and its reducer, ported from the simulator's `showAct`, `endActivity`,
/// `arrange`, `bubbleSlots`, `wantedMode`, `cardOwner` and `setContent`.
public struct Island: Equatable, Sendable {
    public var mediaOn = false
    /// The app media plays from: while it's frontmost, media leaves the island.
    public var mediaApp = BundleID.music
    /// Playing or paused (a paused song holds the ears if it's first, but never gets a ball).
    public private(set) var mediaPlaying = true
    /// Hidden from the menu until the song changes or stops.
    public private(set) var mediaHidden = false
    /// The second player (`Party.media2`): there only while it plays.
    public private(set) var media2On = false
    public private(set) var media2App = ""
    public private(set) var media2Hidden = false
    /// The players' titles, to tell their own browser tab from the others.
    public var mediaTitle = ""
    public var media2Title = ""
    /// The best visible activity: the one that can hold the ears.
    public var activity: ActivityInstance?
    /// The other activities still running, best first. Nothing running is dropped (11-06).
    public private(set) var background: [ActivityInstance] = []
    /// Claude and Codex sessions (phase 2 of the agents design).
    public private(set) var agents = Agents()
    public var opened = false
    public var hovered = false
    /// The ball under the pointer, peeking (never while a card is open).
    public private(set) var peekBall: Party?
    /// Whose card was asked for (ears or bubble).
    public var cardFor: Party?
    /// The open card shows only what a session asks (opened by a hover, `.openQuestion`).
    public private(set) var questionOnly = false
    public var hud: HUDKind?
    public var context = DesktopContext()
    public var pointerOnLiquid = false
    /// The empty notch's tray is open (with media on, the tray is the player's card instead).
    public private(set) var trayOpen = false
    /// The quick-ask card is open, asking this provider.
    public private(set) var askOpen: AgentProvider?
    /// The player's card shows the tray's tools beside it.
    public private(set) var playerTools = false
    /// The tools are showing your day at the large size (`openDay`).
    public private(set) var dayLarge = false
    /// The tray is open over whatever holds the ears (an activity, Claude or Codex), which waits in a ball meanwhile: the
    /// card is the tray's (sim `notesOver`).
    public private(set) var trayOver = false
    /// The player's card is the focused view (lyrics), until the card closes.
    public private(set) var mediaFocus = false
    /// The focused view is a video (the director says, from the player's kind): its card is `videoCard`.
    public var focusVideo = false
    private var nextSerial = 1
    /// Who keeps which place (0 right, 1 left), so nothing jumps sides when another party leaves.
    private var placeKeys: [PlaceKey?] = [nil, nil]
    private enum PlaceKey: Hashable, Sendable { case media, media2, activity(Int), agents(AgentProvider) }

    /// The tools column beside the player in the tray (design 2026-11-01-idle-tray).
    public static let trayColumn = 300.0

    public init() {}

    public var live: Bool {
        mediaOn || activity != nil || trayOpen || askOpen != nil || AgentProvider.allCases.contains { agents.active($0) }
    }

    /// A press on the empty notch would open the tray now.
    /// Asks what the notch shows, not `live`: a session or activity that's running but hidden (its own app is in front)
    /// leaves the notch looking empty, and a press there must still open the tools.
    public var canOpenEmptyTray: Bool {
        arrangement.ears == nil && askOpen == nil && !trayOpen && hud == nil && !context.menuOpen && !context.fullscreen && !context.locked
    }

    // MARK: - Reducer

    @discardableResult
    public mutating func apply(_ event: IslandEvent) -> [IslandEffect] {
        let before = self
        var effects: [IslandEffect] = []
        switch event {
        case .startMedia:
            mediaOn = true
        case .stopMedia:
            guard mediaOn else { break }
            mediaOn = false
            mediaHidden = false
            hovered = false
            opened = false
            hud = nil                      // an alert in flight must not reopen the island
        case .startMedia2(let app):
            if !media2On || media2App != app { media2Hidden = false }
            media2On = true; media2App = app
        case .stopMedia2:
            guard media2On else { break }
            media2On = false; media2Hidden = false
            if cardFor == .media2 { cardFor = nil; opened = false; hovered = false }
            if peekBall == .media2 { peekBall = nil }
        case .show(let id, let open):
            effects += show(id, open: open)
        case .endActivity:
            if let a = activity { end(a.serial) }
        case .end(let serial):
            end(serial)
        case .transientExpired(let serial):
            // Never while its own card is open (closing it gives it two more seconds).
            if let p = party(serial: serial), !(opened && cardOwner == p) { end(serial) }
        case .hide(let p):
            hide(p, true)
        case .unhide(let p):
            hide(p, false)
        case .playback(let on):
            mediaPlaying = on
        case .trackChanged:
            mediaHidden = false
        case .quiet(let serial, let q):
            if activity?.serial == serial { activity?.quiet = q }
            if let i = background.firstIndex(where: { $0.serial == serial }) { background[i].quiet = q }
        case .agent(let h):
            agents.apply(h)
            if agents.sessions.isEmpty, case .agents = cardFor, opened { opened = false; hovered = false; cardFor = nil }
            closeAnsweredQuestion()
        case .agentAnswered(let id):
            agents.answered(id)
            closeAnsweredQuestion()
        case .agentRead(let id):
            agents.read(id)
        case .hover:
            if live { hovered = true }
            // A notification in the ears opens to be read (it was a banner); a click then opens it in its app.
            if live, !opened, activityHoldsEars, activity?.id == .notice, mode != .idle {
                cardFor = .activity; opened = true
            }
        case .unhover, .close:
            hovered = false
            opened = false
            peekBall = nil
        case .peekBall(let party):
            peekBall = opened ? nil : party
            if party != nil { hovered = false }   // the ball's hover, not the ears'

        case .open(let party):
            guard live, !opened else { break }
            cardFor = party
            opened = true
            hovered = true
            peekBall = nil
        case .openQuestion(let party):
            guard live, !opened, case .agents(let p) = party, agents.needsYou(p) else { break }
            cardFor = party
            opened = true
            hovered = true
            peekBall = nil
            questionOnly = true
        case .showCard(let party):
            guard live, party == .more || arrangement.all.contains(party) || arrangement.ears == party else { break }
            cardFor = party
            opened = true
            hovered = true
            questionOnly = false
            askOpen = nil
        case .openAsk(let p):
            guard !context.menuOpen, !context.fullscreen, hud == nil else { break }
            trayOpen = false
            askOpen = p
            opened = true
            hovered = true
            peekBall = nil
            questionOnly = false
        case .openDay:
            if !trayShows { apply(.openTray) }
            dayLarge = trayShows
        case .closeDay:
            dayLarge = false
        case .focusMedia:
            guard mediaOn, !context.menuOpen, !context.fullscreen, hud == nil else { break }
            // The open card's player (the second one's, from its ball), else the main one.
            let own: Party = opened && cardOwner == .media2 && media2On ? .media2 : .media
            cardFor = own; opened = true; hovered = true; playerTools = false; mediaFocus = true
        case .openTray:
            guard !context.menuOpen, !context.fullscreen, hud == nil else { break }
            mediaFocus = false
            if opened {
                if askOpen != nil || trayShows || context.locked { break }
                if cardOwner == .media && mediaOn { playerTools = true; break }   // the open player gains the tools
                // Another card is open (a ball's, Claude's chat, an activity's): the tools take its place.
                trayOver = arrangement.ears != .media; cardFor = .media; questionOnly = false; peekBall = nil
                if mediaOn { playerTools = true } else { trayOpen = true }
                break
            }
            switch arrangement.ears {
            case .media: cardFor = .media; opened = true; hovered = true; playerTools = true
            case nil: if !context.locked { trayOpen = true; opened = true; hovered = true }
            default:
                // Over an activity, Claude or Codex: it waits in a ball while the tools are open (owner, 11-11: the
                // double-click on the notch opens the tools whatever is in the ears).
                guard !context.locked else { break }
                trayOver = true; opened = true; hovered = true; cardFor = nil; questionOnly = false; peekBall = nil
                if mediaOn { playerTools = true } else { trayOpen = true }
            }
        case .context(let c):
            let wasPresenting = context.presenting
            context = c
            // Only while the app it's viewed in is at the island's display (11-11).
            agents.viewing = c.at(c.frontmostApp) ? c.viewedSession : nil
            if context.presenting != wasPresenting, let a = activity {
                if context.presenting && a.spec.tier == .transient {
                    end(a.serial)
                    break
                }
                effects.append(.redact)
            }
            if context.menuOpen || context.fullscreen { opened = false; hovered = false }
        case .hud(let kind):
            hud = kind
        case .hudEnded:
            hud = nil
        case .pointer(let on):
            pointerOnLiquid = on
        }
        if !opened { trayOver = false }
        // The empty notch's tray closes with its card, and gives way to anything that arrives (not to the activity it
        // was opened over).
        // A player can still exist while hidden by its own app or the user's Hide action. Only visible media
        // replaces the standalone tools; otherwise converting to playerTools would close the card over empty ears.
        let visibleMedia = arrangement.ears == .media
        if trayOpen && (!opened || visibleMedia || (arrangement.ears != nil && !trayOver)) {
            trayOpen = false
            if opened && visibleMedia { playerTools = true }    // a song appeared under the open tray: the tools stay
        }
        if playerTools && (!opened || cardOwner != .media || !mediaOn) { playerTools = false }
        if !trayShows { dayLarge = false }
        if mediaFocus && (!opened || !(cardOwner == .media || cardOwner == .media2 && media2On) || !mediaOn) { mediaFocus = false }
        if !mediaFocus { focusVideo = false }
        if !opened { questionOnly = false; askOpen = nil }
        normalize()
        // Whatever held the card left (the song stopped, the session hid because its app came to the front): an island that
        // stays open over nothing drew the idle notch while presses there found no card (log 11-10 23:34).
        if trayOver && arrangement.ears == nil { trayOver = false }
        if opened && arrangement.ears == nil && !trayOpen && askOpen == nil {
            opened = false; hovered = false; playerTools = false; mediaFocus = false; questionOnly = false
        }
        placeKeys = places(mode).keys
        // Closing a transient's card gives it two more seconds.
        if let a = activity, a.serial == before.activity?.serial, a.spec.transient != nil,
           before.cardOpen, !cardOpen {
            effects.append(.armTransient(serial: a.serial, seconds: 2))
        }
        return effects
    }

    private var cardOpen: Bool { mode == .card }

    /// A question card whose question was answered (here or in its app) has nothing left to show: it closes.
    private mutating func closeAnsweredQuestion() {
        guard questionOnly, opened, case .agents(let p)? = cardFor, !agents.needsYou(p) else { return }
        opened = false
        hovered = false
    }

    /// Nothing running is dropped: the same activity again starts over, a transient replaces a transient, a ringing call
    /// answered becomes the call; whatever else was showing keeps going in a ball (or off the island).
    private mutating func show(_ id: ActivityID, open: Bool?) -> [IslandEffect] {
        let spec = ActivitySpec[id]
        if context.presenting && spec.tier == .transient { return [] }   // presenting: transients stay off
        var effects: [IslandEffect] = []
        background.removeAll { $0.id == id }
        let previous = activity
        if let p = previous, !(p.id == id || p.spec.tier == .transient || (p.spec.tier == .alert && spec.tier == .live)) {
            background.insert(p, at: 0)
        }
        let resume = previous == nil && opened && mediaOn
        let wasEars = mode == .compact || mode == .duo
        let new = ActivityInstance(id: id, serial: nextSerial, resume: resume)
        nextSerial += 1
        activity = new
        normalize()
        if let seconds = spec.transient { effects.append(.armTransient(serial: new.serial, seconds: seconds)) }
        guard activity?.serial == new.serial else { return effects }   // it ranks lower: it starts in a ball
        // Typing: nothing opens by itself; the liquid nudges instead.
        opened = open ?? (spec.opens && !context.typing)
        if spec.opens && context.typing && open == nil { effects.append(.nudge) }
        cardFor = opened ? .activity : nil
        hovered = opened
        if wasEars && (mode == .compact || mode == .duo) { effects.append(.takeover) }
        return effects
    }

    private mutating func end(_ serial: Int) {
        if let i = background.firstIndex(where: { $0.serial == serial }) {
            if opened && cardOwner == .background(serial) { opened = false; hovered = false; cardFor = nil }
            background.remove(at: i)
            return
        }
        guard let a = activity, a.serial == serial else { return }
        cardFor = nil
        if !background.isEmpty {
            // Hand back what was there before: the best of the ones still running takes the ears again.
            activity = nil
            normalize()
            opened = false
            hovered = false
            return
        }
        // The player comes back if it was open when this arrived and the pointer is still on it.
        let back = a.resume && pointerOnLiquid && mediaOn
        activity = nil
        opened = back
        hovered = back
    }

    /// Alerts and transients leave on their own: they can't be hidden.
    public func hideable(_ p: Party) -> Bool {
        switch p {
        case .media: mediaOn
        case .media2: media2On
        case .more: false
        case .agents: true
        case .activity, .background: instance(p).map { $0.spec.tier != .alert && $0.spec.tier != .transient } ?? false
        }
    }

    private mutating func hide(_ p: Party, _ on: Bool) {
        guard !on || hideable(p) else { return }
        switch p {
        case .media: mediaHidden = on
        case .media2: media2Hidden = on
        case .activity: activity?.hidden = on
        case .background(let s): if let i = background.firstIndex(where: { $0.serial == s }) { background[i].hidden = on }
        case .more: break
        case .agents(let provider): agents.setHidden(provider, on)
        }
        if on && cardFor == p { cardFor = nil; opened = false; hovered = false }
    }

    /// `activity` is the best visible one: hidden ones, and ones whose own app is in front, rank last.
    private mutating func normalize() {
        let all = ([activity] + background.map(Optional.some)).compactMap { $0 }, c = context
        let rank = { (a: ActivityInstance) -> Int in
            if a.hidden || (c.hosts(a.id) && a.spec.tier != .alert) { return 9 }
            switch a.spec.tier { case .alert: return 0; case .transient: return 1; case .live: return 2; case .ongoing: return 3 }
        }
        let sorted = all.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        activity = sorted.first
        background = Array(sorted.dropFirst())
    }

    // MARK: - Arrangement

    /// Every activity still running, best first.
    public var running: [ActivityInstance] { ([activity] + background.map(Optional.some)).compactMap { $0 } }

    /// The showing a party stands for.
    public func instance(_ p: Party) -> ActivityInstance? {
        switch p {
        case .activity: activity
        case .background(let s): background.first { $0.serial == s }
        default: nil
        }
    }

    private func party(serial: Int) -> Party? {
        if activity?.serial == serial { return .activity }
        return background.contains { $0.serial == serial } ? .background(serial) : nil
    }

    private func isHidden(_ p: Party) -> Bool {
        switch p {
        case .media: mediaHidden
        case .media2: media2Hidden
        case .agents(let provider): agents.isHidden(provider)
        default: instance(p)?.hidden ?? false
        }
    }

    /// A paused song, a download and a far meeting never get a ball (they can still hold the ears).
    public func ballWorthy(_ p: Party) -> Bool {
        switch p {
        case .media: mediaPlaying
        case .media2: true          // it's only here while it plays
        case .more, .agents: true   // only providers with something to see or do are queued
        case .activity, .background: instance(p).map { $0.spec.ball && !$0.quiet } ?? false
        }
    }

    /// The queue: alert, transient, live (newest first), media, ongoing (newest first); minus what's hidden.
    /// The first takes the ears; two balls at most; ball-worthy ones without room go into `.more`.
    public var arrangement: Arrangement {
        // On the lock screen the song has its own card below the clock, as on iPhone: it leaves the island.
        let m = mediaOn && !inOwnPlace(mediaApp, mediaTitle) && !context.lockScreen
        let m2 = media2On && !inOwnPlace(media2App, media2Title) && !context.lockScreen
        let acts = ([activity] + background.map(Optional.some)).compactMap { $0 }
            .filter { !(context.hosts($0.id) && $0.spec.tier != .alert) }
        let tier = { (t: Tier) -> [Party] in
            acts.filter { $0.spec.tier == t }.map { $0.serial == activity?.serial ? .activity : .background($0.serial) }
        }
        // Agents (phase 2): a provider with a session that needs you ranks with the live activities, unless its own
        // app is in front (you're already there: it waits in its ball); other active providers come last; quiet ones
        // (every session read and waiting) aren't on the island.
        // The session you're looking at in its app leaves the island, as iPhone hides a Live Activity while you're in
        // it; the provider's other sessions stay, and one that needs you still comes forward, so you can answer it
        // without leaving the one you're in (owner, 11-07). `agents` already leaves the viewed session out.
        let active = AgentProvider.allCases.filter { agents.active($0) }
        let calling = active.filter { p in agents.sessions(p).contains { $0.state == .needs } }
        let order = tier(.alert) + tier(.transient) + tier(.live) + calling.map(Party.agents) + (m ? [.media] : []) + (m2 ? [.media2] : [])
            + tier(.ongoing) + active.filter { !calling.contains($0) }.map(Party.agents)
        let shown = order.filter { !isHidden($0) }, rest = Array(shown.dropFirst())
        let worthy = rest.filter(ballWorthy)
        var a = Arrangement()
        a.ears = shown.first
        a.overflow = Array(worthy.dropFirst(2))
        a.balls = Array(worthy.prefix(2)) + (a.overflow.isEmpty ? [] : [.more])
        a.quiet = rest.filter { !ballWorthy($0) }
        a.hidden = order.filter(isHidden)
        a.all = order
        return a
    }

    /// You're where this player plays: its app in front with its window on the island's display, and in a browser its
    /// own tab (the window's title has the player's title in it; YouTube's tab reads "(1) <title> - YouTube"). Unknown
    /// tab: the app counts. With the player on another display, or minimized, the song stays (11-11).
    public func inOwnPlace(_ app: String, _ title: String) -> Bool {
        guard context.at(app) else { return false }
        guard AppRules.browsers.contains(app), let w = context.frontWindowTitle, !w.isEmpty else { return true }
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        return w.localizedCaseInsensitiveContains(String(t.prefix(40)))
    }

    /// The activity holds the ears (its ear width applies).
    public var activityHoldsEars: Bool { activity != nil && arrangement.ears == .activity }

    /// Something other than the song holds the ears: an activity, or an agent provider.
    public var earsHeld: Bool {
        if case .agents? = arrangement.ears { return true }
        return activityHoldsEars
    }

    /// Their width: 96 pt for an agent provider ("Allow?", "2 working"), else the activity's own (nil: the default).
    public var heldEar: Double? {
        if case .agents? = arrangement.ears { return 96 }
        return activity?.spec.ear
    }

    /// What the liquid should be doing now.
    public var mode: PresentationMode {
        if hud != nil { return .hud }       // a system alert briefly takes over, then hands back
        let alert = activity?.spec.tier == .alert
        if (context.fullscreen || context.menuOpen) && !alert { return .idle }
        let a = arrangement
        // The empty notch opens only into the tray, or the quick-ask card.
        guard a.ears != nil else { return (trayOpen || askOpen != nil) && opened ? .card : .idle }
        if opened { return .card }
        // The hover preview: a song's, or Claude's and Codex's (sim `wantedMode`); an activity's ears don't preview.
        if hovered, a.ears == .media || earsHeld && !activityHoldsEars { return .peek }
        return a.balls.isEmpty ? .compact : .duo
    }

    /// The +N list has something to show.
    private var hasList: Bool { let a = arrangement; return !(a.overflow.isEmpty && a.quiet.isEmpty && a.hidden.isEmpty) }

    /// Whose card is open: the one that was asked for (the ears, a ball, a row of the list), else whoever holds the ears.
    public var cardOwner: Party {
        if trayOver && opened { return .media }   // the tray's card (the player's place), over the activity
        let a = arrangement
        if let c = cardFor, c == .more ? hasList : (a.ears == c || a.all.contains(c)) { return c }
        return a.ears ?? .media
    }

    /// Who waits in the balls in `mode`, best first: the arrangement's, or with a card open everyone but its owner
    /// (the ears' party steps into a ball while a ball's card is open).
    public func bubbleParties(_ mode: PresentationMode) -> [Party] {
        let a = arrangement
        switch mode {
        case .duo, .peek: return a.balls
        case .card:
            let own = cardOwner
            let others = ([a.ears].compactMap { $0 } + a.balls.filter { $0 != .more })
                .filter { $0 != own && ($0 != a.ears || ballWorthy($0)) }
            return Array(others.prefix(2)) + (others.count > 2 || !a.overflow.isEmpty ? [.more] : [])
        default: return []
        }
    }

    /// The places in `mode`: 0 right of the ears, 1 left, 2 the +N ball. A party keeps its place while it stays; a
    /// lone ball sits right.
    public func balls(_ mode: PresentationMode) -> [Party?] { places(mode).parties }

    private func places(_ mode: PresentationMode) -> (parties: [Party?], keys: [PlaceKey?]) {
        let want = bubbleParties(mode)
        let balls = want.filter { $0 != .more }.prefix(2)
        let key = { (p: Party) -> PlaceKey in
            switch p {
            case .media: .media
            case .media2: .media2
            case .agents(let provider): .agents(provider)
            default: .activity(self.instance(p)?.serial ?? -1)
            }
        }
        var parties: [Party?] = [nil, nil, nil], keys: [PlaceKey?] = [nil, nil]
        for p in balls { if let i = placeKeys.firstIndex(of: key(p)), parties[i] == nil { parties[i] = p; keys[i] = key(p) } }
        for p in balls where !keys.contains(key(p)) {
            if let i = (0..<2).first(where: { parties[$0] == nil }) { parties[i] = p; keys[i] = key(p) }
        }
        if parties[0] == nil, parties[1] != nil { parties.swapAt(0, 1); keys.swapAt(0, 1) }
        if want.contains(.more) { parties[2] = .more }
        return (parties, keys)
    }

    /// Who waits in the first ball in `mode`.
    public func bubbleParty(_ mode: PresentationMode) -> Party? { balls(mode)[0] }

    /// The first ball is out in `mode`.
    public func hasBubble(_ mode: PresentationMode) -> Bool {
        switch mode {
        case .split: true
        case .duo, .peek, .card: bubbleParty(mode) != nil
        default: false
        }
    }

    /// The +N list's rows: everything running that isn't in a ball while the list is open (the ears' party steps into a
    /// ball then, and can push another one out), best first. Hidden ones are listed apart (`arrangement.hidden`).
    public var listParties: [Party] {
        let a = arrangement, inBalls = Set(balls(.card).compactMap { $0 })
        return a.all.filter { !isHidden($0) && !inBalls.contains($0) && !(a.ears == $0 && ballWorthy($0) && cardOwner != .more) }
    }

    /// The +N ball's count in `mode`: parties worth a ball that aren't showing (not the ears', not a ball's, not the
    /// open card's).
    public func moreCount(_ mode: PresentationMode) -> Int {
        let a = arrangement, inBalls = Set(balls(mode).compactMap { $0 })
        return a.all.filter {
            !isHidden($0) && ballWorthy($0) && !inBalls.contains($0) && (mode == .card ? $0 != cardOwner : $0 != a.ears)
        }.count
    }

    /// The +N list's card: a row per party (44 pt), and a heading over the hidden ones.
    public var moreCard: CardSize {
        let a = arrangement
        let rows = listParties.count + a.hidden.count
        return CardSize(width: 320, height: 32 + Double(rows) * 44 + (a.hidden.isEmpty ? 0 : 26), radius: 30)
    }

    /// The card that opens: an activity's own size (the ears' or a ball's), the +N list, the empty notch's tray (the
    /// player's size), or the player with the tray's tools column beside it. `trayHeight`: the tray's page wants more
    /// height (the Notification Center, or the tools' notifications row); the player stays centred in it.
    public func cardSize(player: CardSize, trayColumn: Double = Island.trayColumn, trayHeight: Double? = nil) -> CardSize {
        if askOpen != nil { return Self.askCard }
        let own = cardOwner
        if own == .more { return moreCard }
        if case .agents(let provider) = own {
            return questionOnly ? Self.agentsQuestionCard(agents.urgent(provider)?.need) : Self.agentsCard(agents.urgent(provider))
        }
        if let a = instance(own) { return a.spec.card }
        if mediaOn && mediaFocus && (own == .media || own == .media2) { return focusVideo ? Self.videoCard : Self.focusCard }
        if trayShows && dayLarge { return Self.dayCard }
        var p = player
        if trayShows, let h = trayHeight { p.height = max(p.height, h) }
        guard mediaOn, playerTools else { return p }
        return CardSize(width: p.width + trayColumn, height: p.height, radius: p.radius)
    }

    /// An agent provider's card is the chat (sim `agCardSize`): its sessions, the recent messages, what it needs from
    /// you, a reply.
    public static func agentsCard(_ s: AgentSession?) -> CardSize { CardSize(width: 420, height: 300, radius: 36) }

    /// The focused player: the cover large on the left, the title and the synced lyrics on the right, the controls under.
    public static let focusCard = CardSize(width: 620, height: 318, radius: 40)
    /// Your day, large: the lyrics player's size.
    public static let dayCard = focusCard
    /// Watching a video in the island (owner, 11-11): 16:9 at 512 × 288 inside 16 pt margins, a 36 pt title row; it
    /// fits under the notch in the island's 420 pt window (608 × 342 ran past it, "a bit cut off"). Bigger: picture in
    /// picture.
    public static let videoCard = CardSize(width: 544, height: 354, radius: 32)

    /// The quick-ask card (sim `agCardSize`'s ask view): the provider switch, the field, the Screen chip.
    public static let askCard = CardSize(width: 420, height: 148, radius: 34)

    /// The question alone, opened by a hover: the chat's width, so a press grows it downwards into the chat. A permission
    /// is two rows (what and the command with Deny / Allow), a question up to two lines over its options; 20 pt above
    /// and below, like the other multi-row cards.
    public static func agentsQuestionCard(_ need: AgentNeed?) -> CardSize {
        // A question grows with its text (owner, 11-07: "I can't read the whole thing"): its lines, the options, and
        // two lines under them for the option you rest on, its full label and description.
        if case .question(let text, _)? = need {
            return CardSize(width: 420, height: 40 + Double(questionLines(text)) * 17 + 8 + 28 + 8 + 30, radius: 36)
        }
        return CardSize(width: 420, height: 96, radius: 36)
    }

    /// How many lines a question takes in the card (13 pt semibold, about 48 characters a line), four at most.
    public static func questionLines(_ text: String) -> Int {
        min(4, max(1, Int((Double(text.count) / 48).rounded(.up))))
    }

    /// A ball's peek: one card under the ball, two lines (who, and where it stands).
    public static let ballPeekCard = CardSize(width: 300, height: 60, radius: 30)

    /// A ball's peek by who's in it: a song's holds the notch's hover row (cover, title over artist, the bars and the
    /// transport; owner, 11-06), so it's wider.
    public static func peekCard(_ party: Party) -> CardSize {
        party == .media || party == .media2 ? CardSize(width: 340, height: 60, radius: 30) : ballPeekCard
    }

    /// The activity whose card is open (the ears' one, or a ball's).
    public var cardActivity: ActivityInstance? { instance(cardOwner) }

    /// The tray is on the open card (the empty notch's, the tools beside the player, or over an activity).
    public var trayShows: Bool { opened && askOpen == nil && cardOwner == .media && (trayOpen || (mediaOn && playerTools)) && !mediaFocus }

    /// Which content shows in `mode`.
    public func groups(_ mode: PresentationMode) -> ContentGroups {
        let a = arrangement
        if mode == .card, let p = askOpen {
            // The ask card owns the whole card; balls stay where they are.
            var g = ContentGroups()
            g.agentsAsk = p
            g.balls = balls(mode)
            return g
        }
        let own: Party? = mode == .card ? cardOwner : nil
        let showMusic = !trayOpen && (mediaOn && (own.map { $0 == .media } ?? (a.ears == .media)) || media2On && own == .media2)
        var g = ContentGroups()
        g.musicEars = showMusic && mode != .hud && mode != .idle
        g.activityEars = activity != nil && a.ears == .activity && (mode == .compact || mode == .duo)
        g.activityCard = mode == .card && own.flatMap(instance) != nil
        g.moreList = mode == .card && own == .more
        if case .agents(let p)? = own, mode == .card { g.agentsCard = p; g.agentsQuestion = questionOnly }
        if case .agents(let p)? = a.ears, mode == .compact || mode == .duo || mode == .peek { g.agentsEars = p }
        if mode == .peek { g.agentsPeek = g.agentsEars }
        if mode == .duo || mode == .peek || mode == .card { g.balls = balls(mode) }
        // The +N ball only swells: its list opens on a press.
        if let p = peekBall, p != .more, mode == .duo || mode == .peek, let i = g.balls.firstIndex(of: p) { g.peekPlace = i }
        g.hud = mode == .hud
        g.peek = showMusic && mode == .peek
        g.player = showMusic && (mode == .expanded || (mode == .card && !dayLarge))
        g.tray = mode == .card && own == .media && (trayOpen || (mediaOn && playerTools))
        if g.player && mode == .card && mediaFocus {
            g.player = false; g.tray = false
            if focusVideo { g.videoFocus = true } else { g.playerFocus = true }
        }
        return g
    }

    /// The activity that closes only by its buttons, the notch or a click outside (the ringing call).
    public var holdsOpen: Bool {
        // The Ask conversation stays open while you use the screen (owner, 11-07): Esc, its × or its ball close it.
        if opened && askOpen == nil && cardOwner == .agents(.ask) { return true }
        if opened && mediaFocus && (cardOwner == .media || cardOwner == .media2) { return true }   // lyrics or a video: it stays until you close it
        guard let a = activity else { return false }
        return a.spec.opens && opened && cardOwner == .activity
    }
}
