import AppKit
import IslandCore
import SwiftUI

// Football, chess and the agents' usage limit: ears, ball glyphs and cards, ported from the sim (`ACT.kickoff`,
// `match`, `goal`, `fulltime`, `chess`, `aglimit`, `agback` in sim/src/acts.js and agents.js; styles in acts.css).

// MARK: - Ears

struct SportsEars: View {
    let instance: ActivityInstance
    let side: EarSide
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        let _ = director.now
        HStack(spacing: 7) {
            switch (instance.id, side) {
            case (.kickoff, .left):
                CrestPair(match: director.footballFor(instance), size: 20, overlap: 5).entrance(side, 0)
            case (.kickoff, .right):
                Text(director.footballFor(instance).untilText(from: director.date())).font(IslandType.ear.monospacedDigit())
                    .entrance(side, 0)
            case (.match, .left):
                let m = director.footballFor(instance)
                Crest(team: m.home, size: 22).entrance(side, 0)
                Score(value: m.score[0]).entrance(side, 1)
            case (.match, .right):
                let m = director.footballFor(instance)
                Score(value: m.score[1]).entrance(side, 0)
                Crest(team: m.away, size: 22).entrance(side, 1)
            case (.goal, .left):
                let g = director.footballGoal
                Crest(team: g.match.team(g.side), size: 22).entrance(side, 0)
                Text(g.word.uppercased()).font(IslandType.ear).foregroundStyle(IslandColor.green).entrance(side, 1)
            case (.goal, .right):
                Text(director.footballGoal.match.scoreText).font(IslandType.ear.monospacedDigit()).entrance(side, 0)
            case (.fulltime, .left):
                CrestPair(match: director.footballFinal, size: 20, overlap: 5).entrance(side, 0)
            case (.fulltime, .right):
                Text("\(director.footballFinal.sport.finalShort) \(director.footballFinal.scoreText)").font(IslandType.ear.monospacedDigit()).entrance(side, 0)
            case (.chess, .left):
                let c = director.chessFor(instance)
                ChessToken(piece: c.now.piece, size: 22).entrance(side, 0)
                Text(c.now.san).font(IslandType.ear.monospacedDigit()).entrance(side, 1)
            case (.chess, .right):
                let c = director.chessFor(instance)
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text(clockText(c.mine.rounded(.up))).font(IslandType.ear.monospacedDigit())
                        .foregroundStyle(c.mine < 20 ? IslandColor.red : .white)
                }
                .entrance(side, 0)
            case (.agentLimit, .left), (.agentBack, .left):
                let l = director.limitFor(instance)
                AgentMark(provider: l.provider, size: 16).entrance(side, 0)
                Text(instance.id == .agentLimit ? "Limit" : l.provider.name).font(IslandType.ear).entrance(side, 1)
            case (.agentLimit, .right):
                Text(director.limitFor(instance).resets.map { "until \($0)" } ?? "Usage limit").font(IslandType.ear)
                    .foregroundStyle(IslandColor.red).entrance(side, 0)
            case (.agentBack, .right):
                Text("is back").font(IslandType.ear).foregroundStyle(IslandColor.green).entrance(side, 0)
            default:
                EmptyView()
            }
        }
    }
}

/// A score in the ears: it flips when it changes (the sim's `bump`).
private struct Score: View {
    let value: Int
    var body: some View {
        Text("\(value)").font(IslandType.ear.monospacedDigit()).contentTransition(.numericText(value: Double(value)))
            .animation(.snappy, value: value)
    }
}

/// The ball's glyph for these activities.
struct SportsGlyph: View {
    let instance: ActivityInstance
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        switch instance.id {
        case .kickoff: CrestPair(match: director.footballFor(instance), size: 16, overlap: 4)
        case .match: FootballMini(match: director.footballFor(instance))
        case .goal: Crest(team: director.footballGoal.match.team(director.footballGoal.side), size: 20)
        case .fulltime: CrestPair(match: director.footballFinal, size: 16, overlap: 4)
        case .chess: ChessToken(piece: director.chessFor(instance).now.piece, size: 22)
        case .agentLimit, .agentBack:
            let p = director.limitFor(instance).provider
            AgentMark(provider: p, size: 15)
        default: EmptyView()
        }
    }
}

/// In a ball: the score, ringed in your team's colour.
private struct FootballMini: View {
    let match: FootballMatch
    var body: some View {
        Text(match.scoreText)
            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minWidth: 24, minHeight: 24)
            .overlay(Capsule().strokeBorder(Color(hex: match.ourTeam.colorHex), lineWidth: 2))
            .contentTransition(.numericText())
    }
}

// MARK: - Crests

/// A crest from ESPN's CDN; a badge in the team's colour with its abbreviation until (or unless) it loads.
struct Crest: View {
    let team: FootballTeam
    let size: Double
    private var store: CrestStore { .shared }

    var body: some View {
        ZStack {
            if let image = store.image(team) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            } else {
                Circle().fill(Color(hex: team.colorHex))
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                Text(team.abbr).font(.system(size: (size * 0.3).rounded(), weight: .bold)).tracking(-0.02 * size * 0.3)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(team.name)
    }
}

struct CrestPair: View {
    let match: FootballMatch
    let size: Double
    let overlap: Double

    var body: some View {
        HStack(spacing: -overlap) {
            Crest(team: match.home, size: size)
            Crest(team: match.away, size: size)
        }
    }
}

// MARK: - Cards

struct SportsCard: View {
    let instance: ActivityInstance
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        let _ = director.now
        switch instance.id {
        case .kickoff:
            let m = director.footballFor(instance)
            Row(lead: CrestPair(match: m, size: 40, overlap: 10), title: m.sport == .soccer ? "\(m.home.name) × \(m.away.name)" : "\(m.away.name) @ \(m.home.name)",
                sub: "\(m.competition) · \(m.kickoffText) · \(m.untilText(from: director.date()))")
        case .match: MatchCard(match: director.footballFor(instance))
        case .goal:
            let g = director.footballGoal, t = g.match.team(g.side)
            Row(lead: Crest(team: t, size: 44), title: "\(g.word), \(t.name)!",
                sub: "\(g.whenText) · \(g.match.home.name) \(g.match.scoreText) \(g.match.away.name)")
        case .fulltime:
            let m = director.footballFinal
            Row(lead: CrestPair(match: m, size: 40, overlap: 10), title: "\(m.home.name) \(m.scoreText) \(m.away.name)",
                sub: "\(m.sport.finalWord) · \(m.competition)")
        case .chess: ChessCard(instance: instance, director: director)
        case .agentLimit:
            let l = director.limitFor(instance)
            Row(lead: AlertMark(provider: l.provider, color: IslandColor.red), title: "\(l.provider.name) hit its usage limit",
                sub: l.resets.map { "Resets at \($0) · sessions pause until then" } ?? "Sessions pause until it resets")
        case .agentBack:
            let l = director.limitFor(instance)
            Row(lead: AlertMark(provider: l.provider, color: IslandColor.green), title: "\(l.provider.name) is back",
                sub: "The limit reset · paused sessions can carry on")
        default: EmptyView()
        }
    }
}

/// The sim's `.row-call`: a glyph, then a title over a secondary line.
private struct Row<Lead: View>: View {
    let lead: Lead
    let title: String
    let sub: String

    var body: some View {
        HStack(spacing: 12) {
            lead.rise(0)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(IslandType.title).lineLimit(1)
                Text(sub).font(IslandType.secondary).foregroundStyle(IslandColor.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

/// The provider's mark on a 44 pt tinted disc (sim `.ag-alert`).
private struct AlertMark: View {
    let provider: AgentProvider
    let color: Color
    var body: some View {
        AgentMark(provider: provider, size: 24)
            .frame(width: 44, height: 44).background(Circle().fill(color.opacity(0.22)))
    }
}

/// The live match: both teams, LIVE and the minute, the score, the last event, and a 90-minute bar with a dot per goal.
private struct MatchCard: View {
    let match: FootballMatch

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                team(match.home)
                Spacer(minLength: 0)
                VStack(spacing: 1) {
                    HStack(spacing: 5) {
                        LiveDot()
                        Text("LIVE").tracking(0.44)
                        Text(match.minuteText).padding(.leading, 4).monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandColor.red)
                    HStack(spacing: 9) {
                        Text("\(match.score[0])").contentTransition(.numericText(value: Double(match.score[0])))
                        Text("–").foregroundStyle(.white.opacity(0.35))
                        Text("\(match.score[1])").contentTransition(.numericText(value: Double(match.score[1])))
                    }
                    .font(IslandType.numeral)
                    .animation(.snappy, value: match.score)
                    Text(match.stale ? "Score unavailable" : match.last).font(.system(size: 11)).foregroundStyle(IslandColor.dim)
                        .lineLimit(1)
                }
                .rise(1)
                Spacer(minLength: 0)
                team(match.away)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(.white.opacity(0.7)).frame(width: geo.size.width * match.progress)
                    ForEach(Array(match.goals.enumerated()), id: \.offset) { _, g in
                        Circle().fill(Color(hex: match.team(g.side).colorHex))
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5).padding(-1.5))
                            .frame(width: 8, height: 8)
                            .offset(x: geo.size.width * min(Double(g.minute) / 90, 1) - 4)
                    }
                }
            }
            .frame(height: 4)
            .rise(2)
        }
        .frame(maxHeight: .infinity)
    }

    private func team(_ t: FootballTeam) -> some View {
        VStack(spacing: 2) {
            Crest(team: t, size: 34)
            Text(t.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 88)
        .rise(0)
    }
}

/// The red LIVE dot, blinking like the sim's `urgent`.
private struct LiveDot: View {
    @Environment(\.islandMotion) private var motion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { ctx in
            let on = motion.stills || motion.reduce || Int(ctx.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            Circle().fill(IslandColor.red).frame(width: 6, height: 6).opacity(on ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.3), value: on)
        }
    }
}

// MARK: - Chess

/// The moved piece on a small disc: a light disc for Black's pieces, a warm grey one for White's.
struct ChessToken: View {
    let piece: Character
    let size: Double

    var body: some View {
        let white = piece.isUppercase
        Text(ChessSample.glyph(piece))
            .font(.custom("Apple Symbols", size: (size * 0.72).rounded()))
            .foregroundStyle(white ? .white : Color(hex: "#1C1C1E"))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: white ? "#77726A" : "#ECE7DC")))
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
    }
}

private struct ChessCard: View {
    let instance: ActivityInstance
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        let c = director.chessFor(instance), n = c.now
        HStack(spacing: 14) {
            ChessBoard(board: ChessSample.board(c.step), from: n.from, to: n.to).rise(0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Your move").font(IslandType.title).lineLimit(1)
                        (Text("\(presenting ? "Opponent" : ChessSample.opponent) played ") + Text(n.san).foregroundStyle(.white).fontWeight(.semibold))
                            .font(IslandType.secondary).foregroundStyle(IslandColor.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    RoundButton(symbol: "arrow.up.right", style: .gray, size: 36, label: "Open game") { director.chessOpen(instance) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    clock(c.mine.rounded(.up), mine: true, low: c.mine < 20)
                    clock(n.theirClock, mine: false, low: false)
                }
            }
            .frame(height: 100)
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }

    private func clock(_ seconds: Double, mine: Bool, low: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(mine ? Color.white : Color(hex: "#1C1C1E"))
                .overlay(mine ? nil : Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                .frame(width: 8, height: 8)
            Text(clockText(seconds)).font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(low ? IslandColor.red : mine ? .white : .white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(.white.opacity(mine ? 0.16 : 0.08)))
    }
}

/// A muted board from White's side, the last move's two squares in soft yellow.
private struct ChessBoard: View {
    let board: [Character?]
    let from: Int
    let to: Int

    var body: some View {
        let cell = 100.0 / 8
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { f in
                        let i = r * 8 + f
                        ZStack {
                            Rectangle().fill(Color(hex: (r + f) % 2 == 1 ? "#8B8579" : "#CDC8BD"))
                            if i == from || i == to { Rectangle().fill(Color(red: 1, green: 214 / 255, blue: 10 / 255).opacity(0.55)) }
                            if let p = board[i] {
                                Text(ChessSample.glyph(p)).font(.custom("Apple Symbols", size: 11))
                                    .foregroundStyle(p.isUppercase ? .white : Color(hex: "#151515"))
                                    .shadow(color: p.isUppercase ? .black.opacity(0.8) : .clear, radius: 0.4)
                                    .shadow(color: p.isUppercase ? .black.opacity(0.6) : .clear, radius: 0.4)
                            }
                        }
                        .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        .accessibilityLabel("Board after the opponent's move")
    }
}
