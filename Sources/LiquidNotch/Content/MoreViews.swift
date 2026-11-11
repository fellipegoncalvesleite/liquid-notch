import IslandCore
import SwiftUI

/// The +N ball's list (11-06): what deserves a ball but has no room, what never gets one (a paused song, a download, a
/// far meeting), and what you hid. Each row opens its party's card in place; a hidden one can be shown again.
struct MoreListLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let card: CardSize

    var body: some View {
        CardPlacement(frame: frame, card: card) {
            MoreList(director: director)
                .frame(width: card.width, height: card.height, alignment: .topLeading)
        }
    }
}

/// The list itself, at its natural height (`Island.moreCard` is that height: 32 + 44 a row + 26 for the heading).
struct MoreList: View {
    let director: IslandDirector

    var body: some View {
        let shown = director.island.listParties, hidden = director.island.arrangement.hidden
        VStack(alignment: .leading, spacing: 0) {
            // The rows rise in one after another (sim `#more.in .more-list > *`), the late ones together.
            ForEach(Array(shown.enumerated()), id: \.element) { i, p in row(p, hidden: false).rise(min(i, 3)) }
            if !hidden.isEmpty {
                Text("Hidden")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(height: 22, alignment: .bottomLeading)
                    .padding(.bottom, 4)
                    .rise(min(shown.count, 3))
                ForEach(hidden, id: \.self) { p in row(p, hidden: true).rise(min(shown.count + 1, 4)) }
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }

    private func row(_ p: Party, hidden: Bool) -> some View {
        HStack(spacing: 10) {
            PartyGlyph(party: p, director: director).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(director.title(of: p)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                // No empty second line: a row without a status centres its name on the glyph, as in the sim.
                let status = director.status(of: p)
                if !status.isEmpty {
                    Text(status).font(.system(size: 12)).foregroundStyle(IslandColor.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(hidden ? "Show" : "Open") { hidden ? director.unhide(p) : director.openCard(p) }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(.white.opacity(0.14)))
                .buttonStyle(PressScaleStyle())
        }
        .frame(height: 44)
    }
}

/// A party's glyph, as its ball shows it.
struct PartyGlyph: View {
    let party: Party
    let director: IslandDirector

    var body: some View {
        switch party {
        case .media: AlbumArt(media: director.media, corner: 11).frame(width: 22, height: 22)
        case .media2: AlbumArt(media: director.media2, corner: 11).frame(width: 22, height: 22)
        case .activity, .background:
            if let a = director.island.instance(party) { ActivityGlyph(instance: a, director: director) }
        case .more: EmptyView()
        case .agents(let p): AgentBall(provider: p, agents: director.island.agents)
        }
    }
}
