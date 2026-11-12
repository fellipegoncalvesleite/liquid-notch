import IslandCore
import SwiftUI

/// AirPane's one-time card (11-11): what it does in one line, Learn more and Don't show again. Quiet on purpose.
struct AirPaneEar: View {
    let side: EarSide
    var body: some View {
        if side == .left {
            Image(systemName: "airpods.gen4").font(.system(size: 15, weight: .semibold)).entrance(side, 0)
        } else {
            Text("AirPane").font(IslandType.ear).entrance(side, 0)
        }
    }
}

struct AirPaneCard: View {
    let director: IslandDirector

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "airpods.gen4").font(.system(size: 19, weight: .medium))
                    .frame(width: 40, height: 40).background(Circle().fill(.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open the case, see your AirPods").font(IslandType.title).lineLimit(1)
                    Text("AirPane pops up like iPhone's: the buds in 3D, battery and audio switching.")
                        .font(IslandType.secondary).foregroundStyle(IslandColor.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .rise(0)
            HStack(spacing: 10) {
                CardPill(title: "Don't show again", prominent: false) { director.airPaneCard(learnMore: false) }
                CardPill(title: "Learn more", prominent: true) { director.airPaneCard(learnMore: true) }
            }
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}
