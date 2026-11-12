import IslandCore
import SwiftUI

/// The one-time support card (11-11), laid out like AirPane's: the cup, one line and one under it, Not now and Buy me a
/// coffee. Quiet on purpose.
struct SupportEar: View {
    let side: EarSide
    var body: some View {
        if side == .left {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 14, weight: .semibold)).entrance(side, 0)
        } else {
            Text("Liquid Notch").font(IslandType.ear).lineLimit(1).entrance(side, 0)
        }
    }
}

struct SupportCard: View {
    let director: IslandDirector

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40).background(Circle().fill(.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enjoying Liquid Notch?").font(IslandType.title).lineLimit(1)
                    Text("It's free and open source. A coffee keeps it going.")
                        .font(IslandType.secondary).foregroundStyle(IslandColor.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .rise(0)
            HStack(spacing: 10) {
                CardPill(title: "Not now", prominent: false) { director.supportCard(coffee: false) }
                CardPill(title: "Buy me a coffee", prominent: true) { director.supportCard(coffee: true) }
            }
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A card's capsule button: white when it's the card's one prominent action, a light fill otherwise.
struct CardPill: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(IslandType.body.weight(.medium)).lineLimit(1)
                .foregroundStyle(prominent ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                .background(Capsule().fill(prominent ? .white : .white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(pressed: 0.97, hover: 1))
    }
}
