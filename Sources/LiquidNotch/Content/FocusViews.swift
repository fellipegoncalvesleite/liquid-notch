import AppKit
import IslandCore
import SwiftUI

/// The focused player (owner, 11-07: "if you double click the music island, maybe it could open a bigger screen with the
/// lyrics and all, a pretty one"): the cover large on the left (it rides in from the ears, `MusicEarsLayer`), the title
/// and artist, the synced lyrics with the line being sung bright and centred, the seek bar and the controls under them.
/// It stays open while you read; the notch, Esc or a swipe up close it like any card.
struct FocusPlayerLayer: View {
    let frame: FrameModel
    let director: IslandDirector

    static let cover = 254.0, inset = 32.0

    var body: some View {
        let card = Island.focusCard
        CardPlacement(frame: frame, card: card) {
            FocusPlayerCard(director: director)
                .frame(width: card.width, height: card.height, alignment: .topLeading)
                .opacity(min(max((min(max(frame.cardHeight / card.height, 0), 1.15) - 0.75) / 0.2, 0), 1))
        }
    }
}

private struct FocusPlayerCard: View {
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        let media = director.media
        let left = FocusPlayerLayer.inset * 2 + FocusPlayerLayer.cover - 4
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Marquee(text: media.title, font: .system(size: 20, weight: .semibold))
                    Marquee(text: media.artist, font: .system(size: 15), color: .white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let app = director.playerApp { OpenInPlayerButton(bundleID: app) { director.openInPlayer() } }
            }
            LyricsList(director: director, style: .focus)
                .frame(maxHeight: .infinity)
            FocusProgress(director: director)
            ZStack {
                HStack(spacing: 40) {
                    button("backward.fill", 22, "Previous track") { director.nextTrack(-1) }
                    button(director.playing ? "pause.fill" : "play.fill", 28, director.playing ? "Pause" : "Play") { director.togglePlaying() }
                    button("forward.fill", 22, "Next track") { director.nextTrack(1) }
                }
                HStack {
                    ModeButton.shuffle(director, size: 16)
                    Spacer()
                    ModeButton.repeating(director, size: 16)
                }
            }
            .frame(maxWidth: .infinity)
            // Volume across, the route picker at its end: the full player, as iPhone's Now Playing.
            HStack(spacing: 14) {
                VolumeSlider(director: director)
                AirPlayButton(size: 26)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, left).padding(.trailing, 28).padding(.vertical, 22)
        .onAppear { director.refreshModes() }
    }

    private func button(_ symbol: String, _ size: Double, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).contentTransition(.symbolEffect(.replace))
                .frame(width: size + 16, height: size + 8).contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

/// The lyrics, as iPhone shows them (owner, 11-07: "the timing of switching lyrics is so off and the animation is very
/// bad"): every line the same size (the sung line used to grow a size, which rewrapped the text and jolted the scroll),
/// the sung line bright and the rest dim, so the sung line sits a third of the way down. The lines glide on an even ease,
/// each a touch after the one above, like Apple Music's (a spring did half its move in the first 0.13 s and read as a
/// jump: "still kinda jumpy"). The line follows what you hear (`IslandDirector.lyricsElapsed`) and is checked ten times
/// a second, only while playing and shown. A tap on a line goes there. Plain lyrics (no timings) just scroll; none found
/// says so.
struct LyricsList: View {
    let director: IslandDirector
    let style: LyricsStyle
    @Environment(\.islandMotion) private var motion
    @Environment(\.revealed) private var revealed
    /// The line being sung, and each line's height (measured, so wrapped lines are fine).
    @State private var current: Int?
    @State private var heights: [Int: CGFloat] = [:]
    /// Whether the last move glides (to a nearby line) or jumps (a seek, a new song, shown again).
    @State private var glide = false

    /// The glide: an even ease over 0.7 s, slow off the mark and settling softly.
    private static let glideCurve = Animation.timingCurve(0.35, 0, 0.15, 1, duration: 0.7)
    /// The line under the pointer brightens: a click there goes to it.
    @State private var hovered: Int?

    var body: some View {
        let lyrics = director.lyrics
        Group {
            if let l = lyrics, !l.lines.isEmpty, motion.stills {
                // Stills draw the lines around the one being sung, with no clock.
                let current = l.current(at: director.lyricsElapsed) ?? 0
                VStack(alignment: .leading, spacing: style.spacing) {
                    ForEach(Array(l.lines.enumerated()).filter { abs($0.offset - current) <= 2 }, id: \.offset) { i, line in
                        lineText(line.text, i, current)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if let l = lyrics, !l.lines.isEmpty {
                GeometryReader { g in
                    let anchor = g.size.height * style.anchor, y = top(of: current)
                    VStack(alignment: .leading, spacing: style.spacing) {
                        ForEach(Array(l.lines.enumerated()), id: \.offset) { i, line in
                            lineText(line.text, i, current, hovered: hovered == i)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[i] = $0 }
                                .contentShape(Rectangle())
                                .onHover { over in if over { hovered = i } else if hovered == i { hovered = nil } }
                                .onTapGesture { director.seek(to: line.time) }
                                // Each line rides on its own, a touch after the one above it: the list rolls like a wave.
                                .offset(y: anchor - y)
                                .animation(glide ? Self.glideCurve.delay(stagger(i)) : nil, value: current)
                        }
                    }
                    .frame(width: g.size.width, alignment: .leading)
                }
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                             .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .background {
                    TimelineView(.animation(minimumInterval: 0.1, paused: !director.playing || !revealed)) { _ in
                        let now = l.line(from: current, at: director.lyricsElapsed)
                        Color.clear.onChange(of: now, initial: true) { was, line in
                            // Glide to the next line; a seek or a new song far away moves at once.
                            let near = abs((line ?? 0) - (was ?? 0)) <= 2 && current != nil
                            let e = director.lyricsElapsed
                            lyricsLog.notice("line \(was ?? -1) -> \(line ?? -1) heard=\(e, format: .fixed(precision: 3)) late=\(line.map { e - l.lines[$0].time } ?? 0, format: .fixed(precision: 3))")
                            glide = near && !motion.reduce
                            current = line
                        }
                    }
                }
                .onChange(of: l.key) { _, _ in heights = [:]; glide = false; current = nil }
                // Shown again: straight to the line being sung, no glide from the one it showed when it hid (owner, 11-07:
                // "it seems to go back then go to the current lyrics").
                .onChange(of: revealed) { _, on in
                    guard on else { return }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { glide = false; current = l.line(from: nil, at: director.lyricsElapsed) }
                }
                // The clock's check against the player's own position, every 3 s while they show and play.
                .task(id: revealed && director.playing && !motion.stills) {
                    guard revealed && director.playing && !motion.stills else { return }
                    while !Task.isCancelled {
                        director.checkClock()
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
            } else if let l = lyrics, !l.plain.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(l.plain.joined(separator: "\n")).font(.system(size: style.size - 3, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(director.lyricsLoading || lyrics == nil ? "Finding the lyrics…" : "No lyrics for this song")
                    .font(.system(size: style.size - 3, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    /// Where line `i`'s top sits in the stack: the heights above it and their spacing.
    private func top(of line: Int?) -> CGFloat {
        guard let line, line > 0 else { return 0 }
        return (0..<line).reduce(0) { $0 + (heights[$1] ?? 0) + style.spacing }
    }

    /// How long line `i` waits before it moves: none above the line just left, then 35 ms more per line below it (at
    /// most 0.21 s).
    private func stagger(_ i: Int) -> Double {
        Double(min(max(i - (current ?? 0) + 1, 0), 6)) * 0.035
    }

    /// One line: the same font for all; the sung one white, the ones to come dim, the sung-past ones dimmer and a touch
    /// smaller (scaled, so nothing rewraps).
    private func lineText(_ text: String, _ i: Int, _ current: Int?, hovered: Bool = false) -> some View {
        let now = i == current, past = current.map { i < $0 } ?? false
        return Text(text.isEmpty ? "♪" : text)
            .font(.system(size: style.size, weight: .bold))
            .foregroundStyle(.white.opacity(now ? 1 : hovered ? 0.7 : past ? style.past : style.coming))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(now ? 1 : 0.96, anchor: .leading)
    }
}

/// The small button to the song in its player (owner, 11-07): the player's own icon, read from the installed app (no
/// marks bundled), in a 30 pt target left of the music bars (they ride into the card's top right corner; the button sat
/// on them), brighter under the pointer, no focus ring.
private struct OpenInPlayerButton: View {
    let bundleID: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "the player"
        Button(action: action) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
                } else {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 18))
                }
            }
            .frame(width: 20, height: 20)
            .opacity(hover ? 1 : 0.8)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .padding(.trailing, 26)
        .help("Open in \(name)")
        .accessibilityLabel("Open in \(name)")
    }
}

/// How the lyrics are drawn: big in the focused player, smaller on the lock card's frosted glass.
struct LyricsStyle {
    var size: Double
    var spacing: Double
    /// Where the sung line's top sits, as a fraction of the height.
    var anchor: Double
    var past: Double
    var coming: Double

    static let focus = LyricsStyle(size: 18, spacing: 10, anchor: 0.32, past: 0.22, coming: 0.36)
    static let lock = LyricsStyle(size: 15, spacing: 6, anchor: 0.34, past: 0.4, coming: 0.5)
}

/// The seek bar with both times, as in the player.
private struct FocusProgress: View {
    let director: IslandDirector
    @State private var scrub: Double?

    var body: some View {
        let _ = director.now   // the ticker, as in the player's bar: it sat at 0:00 after a skip
        let length = director.media.duration ?? 0
        let elapsed = scrub.map { $0 * length } ?? director.elapsed
        VStack(spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.9)).frame(width: length > 0 ? w * min(elapsed / length, 1) : 0)
                }
                .frame(height: scrub != nil ? 8 : 5).frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(length > 0 ? DragGesture(minimumDistance: 0)
                    .onChanged { v in if scrub == nil { director.scrub(true) }; scrub = min(max(v.location.x / max(w, 1), 0), 1) }
                    .onEnded { v in director.seek(to: min(max(v.location.x / max(w, 1), 0), 1) * length); scrub = nil; director.scrub(false) } : nil)
            }
            .frame(height: 14)
            HStack {
                Text(clockText(elapsed))
                Spacer()
                Text(length > 0 ? "-" + clockText(max(length - elapsed, 0)) : "")
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(scrub != nil ? 0.95 : 0.5))
        }
    }
}



// MARK: - Watching a video in the island (owner, 11-11)

/// The video's focused view: the video mirrored from its tab (`VideoMirror`), its title and a × over it. It stays open
/// until you close it.
struct VideoFocusLayer: View {
    let frame: FrameModel
    let director: IslandDirector

    var body: some View {
        let card = Island.videoCard
        CardPlacement(frame: frame, card: card) {
            VideoFocusCard(director: director, mirror: director.videoMirror)
                .frame(width: card.width, height: card.height, alignment: .topLeading)
                .opacity(min(max((min(max(frame.cardHeight / card.height, 0), 1.15) - 0.75) / 0.2, 0), 1))
        }
    }
}

private struct VideoFocusCard: View {
    let director: IslandDirector
    let mirror: VideoMirror
    @Environment(\.islandMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Marquee(text: director.media.title, font: .system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { director.popOutVideo() } label: {
                    Image(systemName: "pip.enter").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Picture in picture")
                .disabled(mirror.state != .showing)
                Button { director.closeVideo() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Close the video")
            }
            .frame(height: 26)
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black)
                if motion.stills {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.3))
                } else {
                    MirrorView(layer: mirror.layer)
                }
                message
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
    }

    @ViewBuilder private var message: some View {
        switch mirror.state {
        case .finding: ProgressView().controlSize(.small).tint(.white)
        case .needsPermission: note("Allow Screen Recording in Setup to watch it here")
        case .notFound: note("Couldn't find the video's window")
        case .otherTab: note("Bring its tab to the front of its window to watch it here")
        case .idle, .showing: EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center).padding(24)
    }
}

/// Hosts the mirror's layer (frames land there straight from ScreenCaptureKit, no SwiftUI redraws).
private struct MirrorView: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer = CALayer()
        layer.removeFromSuperlayer()
        v.layer?.addSublayer(layer)
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if layer.superlayer !== v.layer { layer.removeFromSuperlayer(); v.layer?.addSublayer(layer) }   // back from PiP
        layer.frame = v.bounds
    }
}
