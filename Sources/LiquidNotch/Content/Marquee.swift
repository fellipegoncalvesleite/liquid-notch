import SwiftUI

/// A line that's too long scrolls like iPhone's Now Playing (owner, 11-07: "see how it cuts off the name? … how does iOS
/// handle it?"): it rests 1.6 s, slides left at 30 pt a second with a copy following 36 pt behind, and starts over; the
/// edges fade. A line that fits stays still, and so does every line under Reduce Motion and in stills.
struct Marquee: View {
    let text: String
    let font: Font
    var color: Color = .white
    @State private var textWidth: CGFloat = 0
    @State private var start = Date()
    @Environment(\.islandMotion) private var motion
    @Environment(\.revealed) private var revealed

    private static let gap = 36.0, speed = 30.0, rest = 1.6, fade = 10.0

    var body: some View {
        // The hidden line sets the height; the moving one sits over it.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    let w = g.size.width, overflow = textWidth > w + 0.5
                    let still = !overflow || motion.stills || motion.reduce || !revealed
                    TimelineView(.animation(paused: still)) { ctx in
                        let cycle = Double(textWidth + Self.gap) / Self.speed + Self.rest
                        let t = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
                        let x = still ? 0 : -max(0, t - Self.rest) * Self.speed
                        HStack(spacing: Self.gap) {
                            line
                            if overflow && !still { line }
                        }
                        .offset(x: x)
                        .frame(width: w, alignment: .leading)
                    }
                    .clipped()
                    .mask(overflow ? AnyView(edgeFade) : AnyView(Color.black))
                }
            }
            .background(
                line.fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            )
            .onChange(of: text) { _, _ in start = Date() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private var line: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private var edgeFade: some View {
        GeometryReader { g in
            let f = Self.fade / max(g.size.width, 1)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: f),
                                   .init(color: .black, location: 1 - f), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }
}
