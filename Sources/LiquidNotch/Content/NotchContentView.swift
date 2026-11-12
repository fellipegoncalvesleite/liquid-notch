import AVKit
import AppKit
import IslandCore
import SwiftUI

/// Which groups show and how the content moves. Changes only when the island changes,
/// never per frame, so the root view's body is cheap.
@MainActor @Observable
final class NotchContentModel {
    var groups = ContentGroups()
    var mode: PresentationMode = .idle
    /// The open card's final size (content lays out at it and rides the spring as one piece). Kept while it closes.
    var card = CardSize(width: 372, height: 168, radius: 34)
    /// The card that's open, or closing, is the player's: the art and bars ride it back to the ears (sim: they follow
    /// the card while it's still there).
    var cardIsPlayer = false

    /// Whether the art and bars ride the card's channels: the player's card while it's open, and while it closes. Never
    /// a ball's peek, which borrows those channels (11-06 polish: once the player had been open, hovering a ball pulled
    /// the song's cover into the peek).
    static func artRidesCard(mode: PresentationMode, groups: ContentGroups, was: Bool) -> Bool {
        if mode == .card { return groups.player }
        if groups.peekPlace != nil { return false }
        return was
    }
    /// The player's own width: with the tray's tools beside it, the card is wider and the player is its left column.
    var playerWidth = 372.0
    /// The player's own height: in a taller card (the Notification Center beside it) it stays centred.
    var playerHeight = 168.0
    /// How far the player sits down in the open card.
    var playerDrop: Double { max(0, (card.height - playerHeight) / 2) }
    var contentDelay = 0.17
    var timeScale = 1.0
    var reduceMotion = false
    /// The music bars' audio, when they follow what's playing (owner, 11-06).
    var bars: AudioBars?
    /// Offscreen stills (`--snapshot`): no animation at all, static stand-ins for AppKit controls.
    var stills = false

    /// The pointer pressed, dragged or released the liquid (not a control on it), in panel points.
    @ObservationIgnored var onPress: ((SIMD2<Double>) -> Void)?
    @ObservationIgnored var onDrag: ((SIMD2<Double>) -> Void)?
    @ObservationIgnored var onRelease: ((SIMD2<Double>) -> Void)?
}

/// The liquid's frame as drawn, published every frame. Only small leaf views read it, so a
/// frame re-renders those leaves and nothing else. Panel points, top-left origin, x = 380 at the notch.
@MainActor @Observable
final class FrameModel {
    var halfWidth = 0.0
    var height = 0.0
    var radius = 0.0
    var mainX = 0.0
    var cardHalfWidth = 0.0
    var cardTop = 0.0
    var cardHeight = 0.0
    var cardRadius = 0.0
    var cardX = 0.0
    var dropX = 0.0
    var dropY = 0.0
    var dropRadius = 0.0
    // The left ball and the +N ball (11-06).
    var e1X = 0.0
    var e1R = 0.0
    var e2X = 0.0
    var e2R = 0.0

    @ObservationIgnored var notchHalfWidth = 104.0
    @ObservationIgnored var notchHeight = 37.5
    @ObservationIgnored var peekHeight = 68.0
    @ObservationIgnored var expandedHeight = 172.0
    @ObservationIgnored var bubbleRadius = 18.0
    /// The ears' content scale for this notch (`EarMetrics`): 1 in a real notch.
    var earScale: Double { EarMetrics.scale(notchHeight: notchHeight) }

    func update(_ f: ShapeFrame) {
        let s = f.state
        halfWidth = max(s.mainHalfWidth, 0)
        height = s.mainHeight
        radius = max(s.mainRadius, 0)
        mainX = s.mainX
        cardHalfWidth = max(s.cardHalfWidth, 0)
        cardTop = s.cardTop
        cardHeight = max(s.cardHeight, 0)
        cardRadius = max(s.cardRadius, 0)
        cardX = s.cardX
        dropX = s.dropX
        dropY = s.dropY
        dropRadius = min(f.dropRadii.x, f.dropRadii.y)
        e1X = s.e1X; e1R = max(s.e1R, 0)
        e2X = s.e2X; e2R = max(s.e2R, 0)
    }

    /// A ball's centre x (from the notch's centre) and radius, by place: 0 right, 1 left, 2 the +N ball.
    func ball(_ place: Int) -> (x: Double, r: Double, full: Double) {
        switch place {
        case 1: (e1X, e1R, bubbleRadius)
        case 2: (e2X, e2R, 13)
        default: (dropX, dropRadius, bubbleRadius)
        }
    }

    static let cx = 380.0
    var left: Double { Self.cx + mainX - halfWidth }
    var right: Double { Self.cx + mainX + halfWidth }
}

/// Lets clicks land on the first try in a panel that never activates the app.
final class ContentHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// How the island's content moves, handed down to every piece.
struct IslandMotion: Equatable {
    var reduce = false
    var timeScale = 1.0
    var delay = 0.17
    var stills = false
    func seconds(_ s: Double) -> Double { s / max(timeScale, 0.05) }
}

extension EnvironmentValues {
    @Entry var islandMotion = IslandMotion()
    /// Presenting: names, photos and message text stay private.
    @Entry var presenting = false
    /// The layer is showing (`Reveal`): per-frame animations inside run only then.
    @Entry var revealed = true
    /// The music bars' audio: every set of bars (the ears, the player, a song ball's peek) follows it when it can.
    @Entry var audioBars: AudioBars? = nil
}

/// The SwiftUI layer above the liquid. Shape first, content after: groups reveal from a
/// blur and a slight scale `contentDelay` after the shape moves, and leave quickly.
/// The album art and the bars are the same views in every state and ride the shape's
/// own spring from the ears into the player card, the way the Dynamic Island morphs.
struct NotchContentView: View {
    let model: NotchContentModel
    let frame: FrameModel
    let director: IslandDirector

    static let size = NotchSurfaceController.panelSize

    var body: some View {
        let g = model.groups
        let motion = IslandMotion(reduce: model.reduceMotion || model.stills, timeScale: model.timeScale,
                                  delay: model.contentDelay, stills: model.stills)
        ZStack(alignment: .topLeading) {
            PressLayer(model: model)

            ZStack(alignment: .topLeading) {
                MusicEarsLayer(frame: frame, director: director, model: model)
                    .reveal(g.musicEars, motion)
                PeekLayer(frame: frame, director: director)
                    .reveal(g.peek, motion)
                PlayerLayer(frame: frame, director: director, card: model.card, playerWidth: model.playerWidth, drop: model.playerDrop)
                    .reveal(g.player, motion)
                FocusPlayerLayer(frame: frame, director: director)
                    .reveal(g.playerFocus, motion)
                VideoFocusLayer(frame: frame, director: director)
                    .reveal(g.videoFocus, motion)
                TrayLayer(frame: frame, director: director, card: model.card, withPlayer: g.player, playerWidth: model.playerWidth)
                    .reveal(g.tray, motion)
                HUDLayer(frame: frame, director: director)
                    .reveal(g.hud, motion)
                ActivityEarsLayer(frame: frame, director: director)
                    .reveal(g.activityEars, motion)
                ActivityCardLayer(frame: frame, director: director, card: model.card)
                    .reveal(g.activityCard, motion)
                MoreListLayer(frame: frame, director: director, card: model.card)
                    .reveal(g.moreList, motion)
                AgentsEarsLayer(frame: frame, director: director, provider: g.agentsEars)
                    .reveal(g.agentsEars != nil, motion)
                // Mounted with the ears (not only while previewing) so the row fades out as the lip shrinks.
                AgentsPeekLayer(frame: frame, director: director, provider: g.agentsEars)
                    .reveal(g.agentsPeek != nil, motion)
                AgentsCardLayer(frame: frame, director: director, provider: g.agentsCard)
                    .reveal(g.agentsCard != nil, motion)
                AskCardLayer(frame: frame, director: director, provider: g.agentsAsk)
                    .reveal(g.agentsAsk != nil, motion)
                BallPeekLayer(frame: frame, director: director, party: g.peekPlace.flatMap { g.balls[$0] })
                    .reveal(g.peekPlace != nil, motion)
            }
            .mask(alignment: .topLeading) { ClipMask(frame: frame) }

            // The balls live outside the clip and each rides its own spring.
            ForEach(0..<3, id: \.self) { place in
                BubbleLayer(frame: frame, director: director, party: g.balls[place], place: place)
                    .reveal(g.balls[place] != nil, motion)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .environment(\.islandMotion, motion)
        .environment(\.presenting, director.island.context.presenting)
        .environment(\.audioBars, model.bars)
        .environment(\.colorScheme, .dark)
        .transaction { if model.stills { $0.disablesAnimations = true } }
    }
}

// MARK: - Pointer

/// Presses on the liquid itself (controls above take theirs first). The panel only takes the
/// mouse while it's over the liquid, so this sees only presses that belong to the island.
private struct PressLayer: View {
    let model: NotchContentModel
    @State private var down = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let p = SIMD2(Double(v.location.x), Double(v.location.y))
                    if !down {
                        down = true
                        model.onPress?(SIMD2(Double(v.startLocation.x), Double(v.startLocation.y)))
                    }
                    model.onDrag?(p)
                }
                .onEnded { v in
                    down = false
                    model.onRelease?(SIMD2(Double(v.location.x), Double(v.location.y)))
                })
    }
}

// MARK: - Clip

/// The ears plus the card: two rounded rects in one path, from the frame.
private struct ClipMask: View {
    let frame: FrameModel

    var body: some View {
        Path { p in
            let l = frame.left, r = frame.right, h = frame.height
            let er = min(frame.radius, frame.halfWidth, max(h, 0))
            p.move(to: CGPoint(x: l, y: -1))
            p.addLine(to: CGPoint(x: r, y: -1))
            p.addLine(to: CGPoint(x: r, y: h - er))
            p.addArc(center: CGPoint(x: r - er, y: h - er), radius: er, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: l + er, y: h))
            p.addArc(center: CGPoint(x: l + er, y: h - er), radius: er, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
            let cw = frame.cardHalfWidth, ch = frame.cardHeight
            if cw > 0.5 && ch > 0.5 {
                let cr = min(frame.cardRadius, cw, ch / 2)
                let rect = CGRect(x: FrameModel.cx + frame.cardX - cw, y: frame.cardTop, width: 2 * cw, height: ch)
                p.addRoundedRect(in: rect, cornerSize: CGSize(width: cr, height: cr), style: .continuous)
            }
        }
        .fill(.white)
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
    }
}

// MARK: - Music

private func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

/// The album art and the bars: in the ears at rest, travelling into the player card on the
/// card's own spring (overshoot included), breathing with the hover preview.
private struct MusicEarsLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let model: NotchContentModel

    var body: some View {
        let l = frame.left, r = frame.right, h = frame.height
        let ch = frame.cardHeight, cw = frame.cardHalfWidth
        let focus = model.mode == .card && model.groups.playerFocus
        let inCard = model.mode == .card ? (model.groups.player || focus) : ch > 0.5 && model.cardIsPlayer
        // The hover preview (owner, 11-01: the first one was "underwhelming"): the cover grows and slides down into
        // the lip beside the title and the bars move next to the controls, one row. `pk` follows the ears' height,
        // so leaving the preview, or opening the card from it, runs the same move back.
        let nh = frame.notchHeight
        let pk = clamp((h - nh) / max(frame.peekHeight - nh, 1), 0, 1.1)
        let lipC = nh + (frame.peekHeight - nh) / 2
        // At rest the cover and the bars are centred in the notch at its ear scale (`EarMetrics`; 22 and 13 pt in a real
        // notch, 7.75 and 12.25 pt from the top).
        let e = frame.earScale
        let pose = (artX: lerp(l + 11, l + 16, pk), artY: lerp((nh - 22 * e) / 2, lipC - 15, pk), art: lerp(22 * e, 30, pk),
                    corner: lerp(6 * e, 8, pk), barsX: lerp(r - 11 - 18 * e, r - 124, pk), barsY: lerp((nh - 13 * e) / 2, lipC - 6.5, pk),
                    barsScale: lerp(e, 1, min(pk, 1)))
        var size: Double, corner: Double, artX: Double, artY: Double, barsScale: Double, barsX: Double, barsY: Double
        if inCard {
            let q = clamp(ch / model.card.height, 0, 1.15)
            // The player is the card's left column (the tray's tools take the rest): its share rides the spring.
            let cl = FrameModel.cx + frame.cardX - cw, ct = frame.cardTop
            let crt = cl + 2 * cw * model.playerWidth / max(model.card.width, 1)
            let cty = ct + model.playerDrop * min(q, 1)   // centred beside a taller tray (the Notification Center)
            // The player as it was before the short cards (owner, 11-01: "better before, like iPhone").
            if focus {
                // The focused view: the cover large on the left (the same cover, riding the card's spring).
                let big = FocusPlayerLayer.cover, inset = FocusPlayerLayer.inset
                let qf = clamp(ch / Island.focusCard.height, 0, 1.15)
                size = lerp(pose.art, big, qf); corner = lerp(pose.corner, 22, qf)
                artX = lerp(pose.artX, FrameModel.cx + frame.cardX - Island.focusCard.halfWidth + inset, qf); artY = lerp(pose.artY, ct + inset, qf)
                // The bars go to the card's top right corner, clear of the title.
                barsScale = lerp(pose.barsScale, 1.2, qf)
                barsX = lerp(pose.barsX, FrameModel.cx + frame.cardX + Island.focusCard.halfWidth - 28 - 22, qf); barsY = lerp(pose.barsY, ct + 30, qf)
            } else {
                size = lerp(pose.art, 58, q); corner = lerp(pose.corner, 14, q)
                artX = lerp(pose.artX, cl + 20, q); artY = lerp(pose.artY, cty + 20, q)
                barsScale = lerp(pose.barsScale, 1.33, q); barsX = lerp(pose.barsX, crt - 44, q); barsY = lerp(pose.barsY, cty + 28, q)
            }
        } else {
            size = pose.art; corner = pose.corner; artX = pose.artX; artY = pose.artY
            barsScale = pose.barsScale; barsX = pose.barsX; barsY = pose.barsY
        }
        let vinyl = inCard && model.groups.player && director.vinylOut
        return ZStack(alignment: .topLeading) {
            // The record behind its sleeve: it slides out to the right as the title makes room.
            VinylRecord(media: director.media, playing: director.playing, out: vinyl, elapsed: { director.elapsed })
                .frame(width: size - 4, height: size - 4)
                .offset(x: artX + 2 + (vinyl ? PlayerCard.vinylSlide : 0), y: artY + 2)
                .opacity(inCard && model.groups.player ? 1 : 0)
                .animation(.spring(duration: 0.5, bounce: 0.25), value: vinyl)
            ZStack {
                AlbumArt(media: director.media, corner: corner)
                    .id(director.media.artKey)
                    .transition(.trackSwap)
            }
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.28), value: director.media.artKey)
            .offset(x: artX, y: artY)
            EqualizerBars(color: Color(hex: director.media.colorHex), playing: director.playing,
                          visible: model.groups.musicEars)
                .frame(width: 18, height: 13)
                .scaleEffect(barsScale, anchor: .topLeading)
                .offset(x: barsX, y: barsY)
        }
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
        .allowsHitTesting(false)   // the cover and the bars never take a press (the player's own cover button does)
    }
}

/// A vinyl record: black with fine grooves and a sheen, the cover as its centre label, a spindle hole. It turns at 33⅓ rpm
/// with the song's elapsed time, so it stops when the song pauses and jumps with a seek.
private struct VinylRecord: View {
    let media: MediaInfo
    let playing: Bool
    /// Out of its sleeve: it only turns then. It stays mounted with the music ears, hidden behind the cover (opacity, not
    /// the layer's reveal), and its clock re-rendered the whole island every frame whenever a song played (a profile with
    /// music playing, 11-07: ~5% CPU on the main thread).
    let out: Bool
    let elapsed: () -> Double
    @Environment(\.islandMotion) private var motion
    @Environment(\.revealed) private var revealed

    var body: some View {
        TimelineView(.animation(paused: !out || !playing || motion.stills || motion.reduce || !revealed)) { _ in
            GeometryReader { g in
                let d = g.size.width
                ZStack {
                    Circle().fill(Color(white: 0.08))
                    Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.75)   // its rim, so it reads on the black card
                    ForEach(0..<6, id: \.self) { i in
                        Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5).padding(d * (0.06 + Double(i) * 0.045))
                    }
                    // The light on the grooves stays put while the record turns underneath it.
                    Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.10), .clear, .clear, .white.opacity(0.07), .clear],
                                                  center: .center))
                    AlbumArt(media: media, corner: 0)
                        .frame(width: d * 0.4, height: d * 0.4)
                        .clipShape(Circle())
                        .rotationEffect(.degrees(elapsed() * 200))   // 33⅓ rpm = 200° a second
                    Circle().fill(Color(white: 0.06)).frame(width: d * 0.05, height: d * 0.05)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The hover preview's row: the cover (it travels in from the ears), title over artist, the bars, and small
/// transport controls on the right, so a skip or a pause doesn't need the player (owner, 11-01: "a bit quicker").
private struct PeekLayer: View {
    let frame: FrameModel
    let director: IslandDirector

    var body: some View {
        let nh = frame.notchHeight
        let rowC = nh + (frame.height - nh) / 2
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Marquee(text: director.media.title, font: .system(size: 13, weight: .semibold))
                    Marquee(text: director.media.artist, font: .system(size: 11.5, weight: .medium), color: .white.opacity(0.55))
                }
                .id(director.media.id)
                .transition(.trackSwap)
            }
            .animation(.easeInOut(duration: 0.28), value: director.media.id)
            .lineLimit(1)
            .frame(width: max(2 * frame.halfWidth - 192, 0), height: 30, alignment: .leading)
            .offset(x: frame.left + 56, y: rowC - 15)
            // A press anywhere on the row but its buttons opens the player (owner, 11-07: "clicking there doesn't
            // expand it, that's bad UX"): text would otherwise take the click from the press layer underneath.
            .allowsHitTesting(false)
            HStack(spacing: 2) {
                PeekButton(symbol: "backward.fill", size: 11, label: "Previous track") { director.nextTrack(-1) }
                PeekButton(symbol: director.playing ? "pause.fill" : "play.fill", size: 12,
                           label: director.playing ? "Pause" : "Play") { director.togglePlaying() }
                PeekButton(symbol: "forward.fill", size: 11, label: "Next track") { director.nextTrack(1) }
            }
            .offset(x: frame.right - 18 - 76, y: rowC - 12)
        }
        .foregroundStyle(.white)
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
    }
}

/// A 24 pt round control in the preview's lip (and a song's ball peek), lit on hover.
struct PeekButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void
    @State var over = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(over ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(pressed: 0.85, hover: 1))
        .onHover { over = $0 }
        .accessibilityLabel(label)
    }
}

/// The player card's text and controls (the art and bars travel in on their own), laid out at
/// the card's final size and riding the spring as one scaled piece. Follows the iPhone's
/// expanded Now Playing: title and artist, an inline progress row, centred controls, AirPlay.
private struct PlayerLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let card: CardSize
    let playerWidth: Double
    var drop = 0.0

    var body: some View {
        CardPlacement(frame: frame, card: card) {
            PlayerCard(director: director, card: CardSize(width: min(playerWidth, card.width), height: card.height, radius: card.radius))
                .offset(y: drop)
                .frame(width: card.width, height: card.height, alignment: .topLeading)
                .opacity(clamp((clamp(frame.cardHeight / card.height, 0, 1.15) - 0.75) / 0.2, 0, 1))
        }
    }
}

private struct PlayerCard: View {
    let director: IslandDirector
    let card: CardSize
    /// How far the record peeks out of its sleeve (the cover), and the title with it.
    static let vinylSlide = 30.0
    /// Room the title leaves for the tools button.
    static let toolsRoom = 32.0

    var body: some View {
        let media = director.media
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Marquee(text: media.title, font: IslandType.title)
                    Marquee(text: media.artist, font: IslandType.body, color: .white.opacity(0.55))
                }
                .id(media.id)
                .transition(.trackSwap)
            }
            .animation(.easeInOut(duration: 0.28), value: media.id)
            .frame(width: card.width - 156 - Self.toolsRoom - (director.vinylOut ? Self.vinylSlide : 0), alignment: .leading)
            .offset(x: 92 + (director.vinylOut ? Self.vinylSlide : 0), y: 26)
            .animation(.spring(duration: 0.5, bounce: 0.25), value: director.vinylOut)

            // Click the cover for the lyrics (owner, 11-07: the double-click "sometimes works, sometimes doesn't"; they chose
            // the cover). Hold it and the record slides out of its sleeve and spins with the song ("something cool if you
            // click the album artwork"); hold again and it slides back.
            // A real button (owner, 11-07: "the cover also does nothing": a tap gesture paired with a long press dropped
            // clicks), with the hold riding beside it; a hold that took the record out swallows the button's click.
            CoverButton(director: director)
                .offset(x: 20, y: 20)

            // The tools, in sight (a double-click on the notch itself also opens them, but nothing on screen said so):
            // left of the music bars, which ride into the top right corner.
            ToolsButton { director.openToolsOnly() }
                .offset(x: card.width - 64 - Self.toolsRoom, y: 24)

            // The row is the scrubber's 20 pt target tall, so it sits 3 pt higher to keep the bar where it was.
            PlayerProgress(director: director)
                .frame(width: card.width - 40)
                .offset(x: 20, y: 93)

            ZStack {
                HStack(spacing: 32) {
                    PlayerButton(symbol: "backward.fill", size: 25, label: "Previous track") { director.nextTrack(-1) }
                    PlayerButton(symbol: director.playing ? "pause.fill" : "play.fill", size: 30,
                                 label: director.playing ? "Pause" : "Play") { director.togglePlaying() }
                    PlayerButton(symbol: "forward.fill", size: 25, label: "Next track") { director.nextTrack(1) }
                }
                // Shuffle on the left; repeat and the system's own route picker (AirPlay speakers, headphones, this Mac)
                // on the right.
                HStack(spacing: 8) {
                    ModeButton.shuffle(director, size: 15)
                    Spacer()
                    ModeButton.repeating(director, size: 15)
                    AirPlayButton(size: 30)
                }
            }
            .frame(width: card.width - 40, height: 34)
            .offset(x: 20, y: 120)
        }
        .foregroundStyle(.white)
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .onAppear { director.refreshModes() }
    }
}

/// The player's cover: a click opens the lyrics, a hold pulls the record out of its sleeve (or puts it back).
private struct CoverButton: View {
    let director: IslandDirector
    @State private var held = false

    var body: some View {
        Button {
            if held { held = false; return }
            director.openFocus()
        } label: {
            Color.clear.frame(width: 58, height: 58).contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            held = true
            director.toggleVinyl()
        })
        .accessibilityLabel("Lyrics")
        .accessibilityAction(named: director.vinylOut ? "Put the record back" : "Take the record out") { director.toggleVinyl() }
    }
}

/// The player's progress bar, a slider like iPhone's Now Playing (11-06, docs/superpowers/specs/2026-11-06-scrubber-design.md):
/// press anywhere on it (a 20 pt tall target) and the fill jumps there, drag to move it (the song plays on), release to
/// seek. It thickens to 10 pt while held, 8 on hover; both times turn white while held. A live stream doesn't scrub.
private struct PlayerProgress: View {
    let director: IslandDirector
    @State private var scrub: Double?
    @State private var hovering = false
    @Environment(\.islandMotion) private var motion

    var body: some View {
        // Reads the ticker so the row redraws at 4 Hz while the card is open.
        let _ = director.now
        let length = director.media.duration ?? 0
        let elapsed = scrub.map { $0 * length } ?? director.elapsed
        let height = scrub != nil ? 10.0 : hovering && length > 0 ? 8 : 6
        HStack(spacing: 10) {
            Text(clockText(elapsed)).frame(minWidth: 32, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: length > 0 ? w * min(elapsed / length, 1) : 0)
                }
                .frame(height: height)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .gesture(length > 0 ? DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if scrub == nil { director.scrub(true) }
                        scrub = min(max(v.location.x / max(w, 1), 0), 1)
                    }
                    .onEnded { v in
                        let f = min(max(v.location.x / max(w, 1), 0), 1)
                        director.seek(to: f * length)
                        scrub = nil
                        director.scrub(false)
                    } : nil)
            }
            .frame(height: 20)
            .animation(motion.reduce ? nil : .easeOut(duration: 0.16), value: height)
            // A live stream has no length: no time left to show.
            Text(length > 0 ? "-" + clockText(max(length - elapsed, 0)) : "").frame(minWidth: 32, alignment: .trailing)
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.white.opacity(scrub != nil ? 1 : 0.55))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(length > 0 ? "\(clockText(elapsed)) of \(clockText(length))" : "Live")
        .accessibilityAdjustableAction { direction in
            guard length > 0 else { return }
            director.seek(to: director.elapsed + (direction == .increment ? 5 : -5))
        }
    }
}

/// Opens the tools beside the player.
private struct ToolsButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.55))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .help("Tools")
        .accessibilityLabel("Tools")
    }
}

/// Shuffle or repeat: dim when off, white with a soft plate when on (as iPhone's), the repeat-one glyph for one.
struct ModeButton: View {
    let symbol: String
    let on: Bool
    let size: CGFloat
    let label: String
    let action: () -> Void

    static func shuffle(_ d: IslandDirector, size: CGFloat) -> ModeButton {
        let on = d.shuffle ?? false
        return ModeButton(symbol: "shuffle", on: on, size: size, label: on ? "Shuffle on" : "Shuffle off") { d.toggleShuffle() }
    }

    static func repeating(_ d: IslandDirector, size: CGFloat) -> ModeButton {
        let mode = d.repeatMode ?? .off
        let label = switch mode { case .off: "Repeat off"; case .all: "Repeat all"; case .one: "Repeat one" }
        return ModeButton(symbol: mode == .one ? "repeat.1" : "repeat", on: mode != .off, size: size, label: label) { d.cycleRepeat() }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on ? .white : .white.opacity(0.45))
                .frame(width: size + 13, height: size + 11)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(on ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.18), value: on)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A volume slider, as iPhone's: speaker glyphs at both ends, press anywhere and drag; the level follows one to one.
struct VolumeSlider: View {
    let director: IslandDirector
    @State private var drag: Double?
    @State private var hovering = false

    var body: some View {
        let level = drag ?? director.volume
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 11))
            GeometryReader { g in
                let w = max(g.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white.opacity(drag != nil ? 1 : 0.85)).frame(width: w * level)
                }
                .frame(height: drag != nil ? 8 : hovering ? 7 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if drag == nil { director.scrub(true) }
                        let l = min(max(v.location.x / w, 0), 1)
                        drag = l
                        director.setPlayerVolume(l)
                    }
                    .onEnded { _ in drag = nil; director.scrub(false) })
                .animation(.easeOut(duration: 0.14), value: drag != nil)
            }
            .frame(height: 18)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11))
        }
        .foregroundStyle(.white.opacity(0.55))
        .onAppear { director.syncVolume() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
        .accessibilityAdjustableAction { dir in director.setPlayerVolume(director.volume + (dir == .increment ? 0.0625 : -0.0625)) }
    }
}

private struct PlayerButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.8))
                .frame(width: size + 4, height: size + 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - HUD

/// Volume or brightness takes over the ears: the icon (following the level) and the percentage on the
/// left, a 6 pt white bar on the right. The icon bounces on each press.
private struct HUDLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    @Environment(\.islandMotion) private var motion

    var body: some View {
        let nh = frame.notchHeight, e = frame.earScale
        // Sizes at the ears' scale (`EarMetrics`; as designed in a real notch).
        let iconFont: CGFloat = 13 * e, box: CGFloat = 18 * e, digits: CGFloat = 12 * e, percent: CGFloat = 10 * e
        let iconY: CGFloat = (nh - box) / 2 + 0.5 * e, textY: CGFloat = (nh - box) / 2 + 0.25 * e
        let textX: CGFloat = frame.left + 13 + 24 * e
        let bright = director.island.hud == .brightness
        let level = director.hudLevel
        let tint = Color.white              // white for brightness too (owner, 11-01)
        let icon = bright ? (level < 0.5 ? "sun.min.fill" : "sun.max.fill")
                          : (level <= 0 ? "speaker.slash.fill" : "speaker.wave.3.fill")
        ZStack(alignment: .topLeading) {
            Image(systemName: icon, variableValue: bright || level <= 0 ? nil : level)
                .font(.system(size: iconFont, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, options: .nonRepeating, value: motion.reduce ? 0 : level)
                .frame(width: box, height: box)
                .offset(x: frame.left + 13, y: iconY)
            // Quieter than the icon (12 pt medium, the % smaller and dimmer), and nudged so the digits'
            // middle sits on the ears' midline with the icon (measured on the 2x snapshot).
            (Text("\(Int((level * 100).rounded()))").font(.system(size: digits, weight: .medium).monospacedDigit())
             + Text("%").font(.system(size: percent, weight: .medium)).foregroundColor(.white.opacity(0.6)))
                .foregroundStyle(.white.opacity(0.9))
                .frame(height: box)
                .offset(x: textX, y: textY)
            // A slider (v1): under the pointer or held it thickens from 6 to 10 pt like the player's scrubber, and follows
            // the drag without a spring (the spring is for key presses). Read-only, it dims.
            let held = director.hudHeld
            let bar = (held ? 10.0 : 6.0) * e
            Capsule().fill(tint.opacity(0.22))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint.opacity(director.hudReadOnly ? 0.5 : 1)).frame(width: IslandDirector.hudBarWidth * level)
                        .animation(motion.reduce || held ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: level)
                }
                .frame(width: IslandDirector.hudBarWidth, height: bar)
                .animation(motion.reduce ? nil : .snappy(duration: 0.18), value: held)
                .offset(x: frame.right - 14 - IslandDirector.hudBarWidth, y: nh / 2 - bar / 2)
        }
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
    }
}

// MARK: - Bubble

/// A ball beside the ears: one glyph, the minimal view of whoever waits there (the +N ball shows its count).
private struct BubbleLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let party: Party?
    let place: Int
    @State private var last: Party?

    var body: some View {
        let b = frame.ball(place)
        let k = clamp(b.r / b.full, 0, 1.1)
        Group {
            switch party ?? last {
            case .media:
                AlbumArt(media: director.media, corner: 11).frame(width: 22, height: 22)
            case .media2:
                AlbumArt(media: director.media2, corner: 11).frame(width: 22, height: 22)
            case .activity:
                if let a = director.shownActivity { ActivityGlyph(instance: a, director: director) }
            case .background(let serial):
                if let a = director.island.background.first(where: { $0.serial == serial }) {
                    ActivityGlyph(instance: a, director: director)
                }
            case .agents(let p):
                AgentBall(provider: p, agents: director.island.agents).modifier(BarrelRoll(rolls: director.barrelRolls))
            case .more:
                Text("+\(director.island.moreCount(director.mode))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            case nil:
                EmptyView()
            }
        }
        .frame(width: 24, height: 24)
        .scaleEffect(k)
        .offset(x: FrameModel.cx + b.x - 12, y: frame.dropY - 12)
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onChange(of: party) { _, p in if p != nil { last = p } }
    }
}

// MARK: - Card placement

/// Lays the card's content out at its final size and rides the spring as one piece, scaled
/// from its top edge, so nothing re-wraps or slides while it opens; the clip reveals it.
struct CardPlacement<Content: View>: View {
    let frame: FrameModel
    let card: CardSize
    @ViewBuilder let content: Content

    var body: some View {
        let k = clamp(min(frame.cardHalfWidth / card.halfWidth, frame.cardHeight / card.height), 0.3, 1.08)
        content
            .frame(width: card.width, height: card.height)
            .scaleEffect(k, anchor: .top)
            .offset(x: FrameModel.cx + frame.cardX - card.halfWidth, y: frame.cardTop)
            .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
    }
}

// MARK: - Reveal

private struct Reveal: ViewModifier {
    let on: Bool
    let motion: IslandMotion

    func body(content: Content) -> some View {
        let animation: Animation = on
            ? (motion.reduce ? .easeOut(duration: motion.seconds(0.15))
                             : .spring(response: motion.seconds(0.34), dampingFraction: 0.62).delay(motion.seconds(motion.delay)))
            : .easeOut(duration: motion.seconds(0.1))
        // Scoped so that only the reveal animates; the per-frame layout never does.
        // Hidden layers stay mounted: their per-frame animations pause (`revealed`), or a scrolling title would keep
        // the whole island redrawing every frame (seen 11-07: 25-80% CPU).
        content.environment(\.revealed, on).animation(animation) {
            $0.opacity(on ? 1 : 0)
                .blur(radius: on || motion.reduce ? 0 : 6)
                .scaleEffect(on || motion.reduce ? 1 : 0.92,
                             anchor: UnitPoint(x: 0.5, y: 19.0 / NotchContentView.size.height))
        }
        // Hidden content takes no clicks, no focus and no VoiceOver.
        .allowsHitTesting(on)
        .disabled(!on)
        .accessibilityHidden(!on)
    }
}

private extension View {
    func reveal(_ on: Bool, _ motion: IslandMotion) -> some View { modifier(Reveal(on: on, motion: motion)) }
}

// MARK: - AirPlay

/// The system route picker, drawn as a plain glyph to match the controls. (A still shows our own
/// glyph: offscreen renders can't draw AppKit views.)
struct AirPlayButton: View {
    let size: CGFloat
    @Environment(\.islandMotion) private var motion

    var body: some View {
        if motion.stills {
            Image(systemName: "airplayaudio").font(.system(size: size * 0.7)).frame(width: size, height: size)
        } else {
            RoutePicker().frame(width: size, height: size).accessibilityLabel("AirPlay")
        }
    }
}

private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.6), for: .normalHighlighted)
        v.setRoutePickerButtonColor(.systemBlue, for: .active)
        return v
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

// MARK: - Track swap

/// The old track blurs out while the new one blurs in, in place (opacity only under Reduce Motion).
private struct SwapEffect: ViewModifier {
    let out: Bool
    @Environment(\.islandMotion) private var motion
    func body(content: Content) -> some View {
        content.opacity(out ? 0 : 1).blur(radius: out && !motion.reduce ? 4 : 0)
    }
}

extension AnyTransition {
    static var trackSwap: AnyTransition {
        .modifier(active: SwapEffect(out: true), identity: SwapEffect(out: false))
    }
}

// MARK: - Pieces

/// The cover: the real artwork, a sample's drawn cover, or a plain note when the player sends none.
struct AlbumArt: View {
    let media: MediaInfo
    let corner: Double

    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            if let art = media.artwork {
                Image(nsImage: art.image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: s, height: s)
            } else if let track = media.sample {
                ZStack {
                    LinearGradient(colors: track.gradient.map { Color(hex: $0) },
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Color(hex: track.dotHex))
                        .frame(width: s * track.dotSize, height: s * track.dotSize)
                        .position(x: s * track.dotAt.x, y: s * track.dotAt.y)
                }
            } else {
                Image(systemName: "music.note").font(.system(size: s * 0.45, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: s, height: s)
                    .background(Color(white: 0.2))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Four bars in the album's colour. They follow what the Mac plays while `audio` can (owner, 11-06), and otherwise
/// animate only while playing and shown, so a paused or hidden player costs nothing; Reduce Motion holds them still.
struct EqualizerBars: View {
    let color: Color
    let playing: Bool
    let visible: Bool
    /// What the Mac plays, when the bars follow it (`AudioBars.showsReal`); otherwise they animate.
    @Environment(\.audioBars) private var audio
    @Environment(\.islandMotion) private var motion

    var body: some View {
        if motion.stills {
            // Offscreen stills can't draw AppKit views: the still pose, in a Canvas.
            let pose = playing ? 0.6 : 0.25
            Canvas { ctx, size in
                for (i, rect) in BarsView.rects(in: size, heights: [pose, pose, pose, pose]).enumerated() where i < 4 {
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .foreground)
                }
            }
            .foregroundStyle(color)
        } else {
            // SwiftUI only updates this when the colour, playing, shown or real audio changes; every tick happens in the
            // bars' own layers (the island's whole content tree used to re-lay out 30 times a second: 10–13% CPU).
            BarsLayer(color: NSColor(color), live: playing && visible && !motion.reduce, playing: playing,
                      audio: visible && audio?.showsReal == true ? audio : nil, timeScale: motion.timeScale)
        }
    }

    static let periods = [0.8, 0.55, 0.95, 0.7]
    static let phases = [0.0, 0.2, 0.5, 0.35]
    /// The lowest a bar goes on real audio: quiet music keeps the bars visible, never empty (owner, 11-06).
    static let floor = 0.22
}

private struct BarsLayer: NSViewRepresentable {
    let color: NSColor
    let live: Bool
    let playing: Bool
    let audio: AudioBars?
    let timeScale: Double

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.configure(color: color, live: live, playing: playing, audio: audio, timeScale: timeScale)
    }
}

/// Four layers and a display link of their own: real levels (read, not observed) or the animation, 30 times a second
/// while live, and nothing at all while paused or hidden.
final class BarsView: NSView {
    private let bars = (0..<4).map { _ in CALayer() }
    private var link: CADisplayLink?
    private var live = false, playing = false, timeScale = 1.0
    private var audio: AudioBars?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for b in bars {
            b.cornerRadius = 1.5
            b.anchorPoint = .zero
            layer?.addSublayer(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // presses go to the island underneath

    func configure(color: NSColor, live: Bool, playing: Bool, audio: AudioBars?, timeScale: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)                  // a new album colour eases in
        for b in bars { b.backgroundColor = color.cgColor }
        CATransaction.commit()
        self.live = live
        self.playing = playing
        self.audio = audio
        self.timeScale = timeScale
        updateLink()
        draw(at: CACurrentMediaTime())
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    override func layout() {
        super.layout()
        draw(at: CACurrentMediaTime())
    }

    private func updateLink() {
        let wanted = window != nil && (live || audio != nil)
        if wanted, link == nil {
            let l = displayLink(target: self, selector: #selector(step(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            l.add(to: .main, forMode: .common)
            link = l
        } else if !wanted, let l = link {
            l.invalidate()
            link = nil
        }
    }

    @objc private func step(_ link: CADisplayLink) { draw(at: link.targetTimestamp) }

    private func draw(at time: CFTimeInterval) {
        let heights: [Double]
        if let audio {
            heights = audio.levels.map { EqualizerBars.floor + (1 - EqualizerBars.floor) * $0 }
        } else if live {
            let t = time * max(timeScale, 0.05)
            heights = (0..<4).map { 0.25 + 0.75 * (sin((t / EqualizerBars.periods[$0] + EqualizerBars.phases[$0]) * .pi) + 1) / 2 }
        } else {
            heights = Array(repeating: playing ? 0.6 : 0.25, count: 4)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (b, rect) in zip(bars, Self.rects(in: bounds.size, heights: heights)) { b.frame = rect }
        CATransaction.commit()
    }

    /// Four bars bottom-aligned, 2 pt apart, each `heights[i]` (0…1) of the height.
    static func rects(in size: CGSize, heights: [Double]) -> [CGRect] {
        let w = (size.width - 6) / 4
        return heights.prefix(4).enumerated().map { i, h in
            let hh = size.height * min(max(h, 0), 1)
            return CGRect(x: Double(i) * (w + 2), y: size.height - hh, width: w, height: hh)
        }
    }
}

extension Color {
    init(hex: String) {
        let c = SRGB.parse(hex) ?? SIMD3(1, 1, 1)
        self.init(.sRGB, red: c.x, green: c.y, blue: c.z)
    }
}
