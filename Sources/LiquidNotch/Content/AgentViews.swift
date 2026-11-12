import IslandCore
import SwiftUI

/// Claude and Codex in the notch, phase 2 (docs/superpowers/specs/2026-11-06-agents-design.md): a ball per provider,
/// its ears, and its card with the approval.
enum AgentLook {
    static let clay = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    static func symbol(_ p: AgentProvider) -> String {
        switch p {
        case .claude: "asterisk"
        case .codex: "hexagon"
        case .ask: "sparkles"   // the tray's Ask tool
        }
    }
    static func tint(_ p: AgentProvider) -> Color { p == .claude ? clay : .white }
    static func label(_ p: AgentProvider) -> String { p == .codex ? "ChatGPT" : p.name }

    /// Each session's ring segment, by state.
    static func segment(_ s: AgentState) -> Color {
        switch s {
        case .working: .white.opacity(0.38)
        case .needs: IslandColor.orange
        case .done: IslandColor.green
        case .ready: .white.opacity(0.16)
        case .error: IslandColor.red
        }
    }

    /// The ears' word for where a provider stands; needing you, it says what's asked.
    static func word(_ s: AgentSession?, working: Int) -> (String, Color) {
        guard let s else { return ("Ready", IslandColor.secondary) }
        switch s.state {
        case .needs: if case .question = s.need { return ("Asks you", IslandColor.orange) } else { return ("Allow?", IslandColor.orange) }
        case .error: return (s.step == "Usage limit" ? "Limit" : "Error", IslandColor.red)
        case .done: return ("Done", IslandColor.green)
        case .working: return (working > 1 ? "\(working) working" : "Working", IslandColor.secondary)
        case .ready: return ("Ready", IslandColor.secondary)
        }
    }
}

/// The provider's real mark (owner, 11-06: "use real symbols"): Claude's starburst and OpenAI's knot, read at runtime
/// from the installed apps' own menu-bar template images (`TrayIconTemplate`, `chatgptTemplate`), so nothing of theirs
/// is bundled here; tinted clay for Claude, white for ChatGPT. Without the app, the SF Symbol stands in.
struct AgentMark: View {
    let provider: AgentProvider
    let size: Double

    var body: some View {
        Group {
            if let image = Self.image(provider) {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: AgentLook.symbol(provider)).resizable().scaledToFit().fontWeight(.bold).padding(size * 0.08)
            }
        }
        .foregroundStyle(AgentLook.tint(provider))
        .frame(width: size, height: size)
        .accessibilityLabel(AgentLook.label(provider))
    }

    @MainActor private static var cache: [AgentProvider: NSImage?] = [:]

    @MainActor static func image(_ p: AgentProvider) -> NSImage? {
        guard p != .ask else { return nil }   // Ask is the notch's own: its sparkles
        if let hit = cache[p] { return hit }
        let (bundle, file) = p == .claude ? (Agents.app(.claude), "TrayIconTemplate") : (Agents.app(.codex), "chatgptTemplate")
        let candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
                          p == .codex ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat") : nil,
                          URL(fileURLWithPath: p == .claude ? "/Applications/Claude.app" : "/Applications/ChatGPT.app")]
        var image: NSImage?
        for case let app? in candidates {
            let res = app.appendingPathComponent("Contents/Resources")
            // NSImage(contentsOf:) on the 1x file picks up its @2x / @3x siblings as representations.
            if let i = NSImage(contentsOf: res.appendingPathComponent("\(file).png")) { image = i; break }
        }
        image?.isTemplate = true
        cache[p] = image
        return image
    }
}

/// A provider's ball: its glyph inside a ring with one segment per session (four at most).
struct AgentBall: View {
    let provider: AgentProvider
    let agents: Agents
    var size = 24.0

    var body: some View {
        let list = Array(agents.sessions(provider).prefix(4)), n = list.count, gap = n > 1 ? 7.0 / 360 : 0
        ZStack {
            ForEach(Array(list.enumerated()), id: \.offset) { i, s in
                Circle()
                    .trim(from: Double(i) / Double(max(n, 1)) + gap / 2, to: Double(i + 1) / Double(max(n, 1)) - gap / 2)
                    .stroke(AgentLook.segment(s.state), style: StrokeStyle(lineWidth: size * 0.075))
                    .rotationEffect(.degrees(-90))
            }
            AgentMark(provider: provider, size: size * 0.66)
        }
        .frame(width: size, height: size)
        .padding(size * 0.04)
    }
}

/// The ears when a provider holds them: its ball, and a word. Hovered, the ball slides down into the lip beside the
/// session's row (`AgentsPeekLayer`), as the song's cover does, and the word gives way to the row's second line. `pk`
/// follows the ears' height, so leaving the preview, or opening the card from it, runs the same move back.
struct AgentsEarsLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let provider: AgentProvider?
    /// Kept while the ears fade out, so they don't pop.
    @State private var last: AgentProvider?

    var body: some View {
        let cx = FrameModel.cx, nhw = frame.notchHalfWidth, nh = frame.notchHeight
        let rightX = cx + nhw + 8, rightW = max(frame.right - 12 - rightX, 0)
        let pk = min(max((frame.height - nh) / max(frame.peekHeight - nh, 1), 0), 1.1)
        let lipC = nh + (frame.peekHeight - nh) / 2
        // The ball as drawn in the ears (22 pt) and in a ball's peek (24 pt, 26 with its padding), at the row's left.
        // In the ears at their scale (`EarMetrics`; 22 pt in a real notch).
        let e = frame.earScale, ear = 22.0 * e / 24
        let full = 24 * 1.08, scale = ear + (1 - ear) * pk
        let ballX = frame.left + 12 + 5 * pk
        let ballY = (nh - full * ear) / 2 + (lipC - full / 2 - (nh - full * ear) / 2) * pk
        ZStack(alignment: .topLeading) {
            if let provider = provider ?? last {
                let a = director.island.agents
                let (word, color) = AgentLook.word(a.urgent(provider), working: a.sessions(provider).filter { $0.state == .working }.count)
                AgentBall(provider: provider, agents: a, size: 24)
                    .modifier(BarrelRoll(rolls: director.barrelRolls))
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: ballX, y: ballY)
                Text(word).font(IslandType.ear).foregroundStyle(color).lineLimit(1)
                    .frame(width: rightW / e, height: nh / e, alignment: .trailing)
                    .scaleEffect(e, anchor: .topLeading)
                    .frame(width: rightW, height: nh, alignment: .topLeading).offset(x: rightX)
                    .opacity(1 - min(pk, 1))
            }
        }
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
        .allowsHitTesting(false)   // the ears' ball and word never take a press from the island
        .onChange(of: provider) { _, p in if p != nil { last = p } }
    }
}

/// The ears' hover preview when a provider holds them (sim `agPeek`): the session's row in the lip, as in a ball's peek,
/// beside the ball that slid down from the ear: its title, and its state with the last line it wrote (names and text
/// stay private while presenting: `IslandDirector.peekText`).
struct AgentsPeekLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let provider: AgentProvider?
    @State private var last: AgentProvider?

    var body: some View {
        let nh = frame.notchHeight
        let rowC = nh + (frame.height - nh) / 2, x = frame.left + 53
        ZStack(alignment: .topLeading) {
            if let provider = provider ?? last {
                let (title, line) = director.peekText(.agents(provider))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .frame(width: max(frame.right - 18 - x, 0), height: 32, alignment: .leading)
                .offset(x: x, y: rowC - 16)
            }
        }
        .foregroundStyle(.white)
        .frame(width: NotchContentView.size.width, height: NotchContentView.size.height, alignment: .topLeading)
        .onChange(of: provider) { _, p in if p != nil { last = p } }
    }
}

/// A provider's card is the chat (11-06, sim `agChatHTML`): a chip per session, the recent messages from its transcript
/// with tool runs folded, what it needs from you, and a reply. 420 × 300. Opened by a hover on a session that needs you,
/// it shows only the question (`groups.agentsQuestion`, `Island.agentsQuestionCard`); a press grows it into the chat.
/// It keeps what it last showed while it fades out (it used to pop out).
struct AgentsCardLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let provider: AgentProvider?
    @Environment(\.presenting) private var presenting
    @Environment(\.islandMotion) private var motion
    @State private var reply = ""
    @State private var open: Set<Int> = []
    @State private var last: AgentProvider?
    @State private var lastQuestion = false
    @State private var lastNeed: AgentNeed?
    /// The option whose full label and description show under the pills (owner, 11-07): the one you rested on, else the
    /// first; `restingOn` is the pill under the pointer, taken after a moment.
    @State private var restedOption: String?
    @State private var restingOn: String?
    /// The chip under the pointer: its × shows in place of the state dot, like a Safari tab.
    @State private var chipHover: String?
    @FocusState private var focused: Bool

    var body: some View {
        let question = provider != nil ? director.groups.agentsQuestion : lastQuestion
        Group {
            if let p = provider ?? last, let s = director.agentShown(p) {
                if question {
                    let need = s.need ?? lastNeed
                    let size = Island.agentsQuestionCard(need)
                    CardPlacement(frame: frame, card: size) {
                        Group { if let need { needBox(s, need, boxed: false) } }
                            .padding(.horizontal, 18)
                            .frame(width: size.width, height: size.height)
                            .foregroundStyle(.white)
                            .onChange(of: s.need, initial: true) { _, n in if n != nil { lastNeed = n } }
                    }
                } else {
                    let size = Island.agentsCard(s)
                    CardPlacement(frame: frame, card: size) {
                        VStack(alignment: .leading, spacing: 10) {
                            chips(p, shown: s).rise(0)
                            messages(s).rise(1)
                            if let need = s.need { needBox(s, need).rise(2) }
                            HStack(spacing: 8) {
                                replyField(s)
                                if p == .ask { screenChip }
                            }
                            .rise(2)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 16)
                        .frame(width: size.width, height: size.height)
                        .foregroundStyle(.white)
                        .onChange(of: focused) { _, f in director.replyFocused = f }
                        .onChange(of: s.id) { _, _ in open = [] }
                        // The Ask chat opens with its field ready to type into (its ball, the shortcut).
                        .onChange(of: director.askFocusTick) { _, _ in if p == .ask { focused = true } }
                        .task(id: p) {
                            guard p == .ask, !motion.stills else { return }
                            try? await Task.sleep(for: .milliseconds(80))
                            focused = true
                        }
                    }
                }
            }
        }
        .onChange(of: provider) { _, p in if p != nil { last = p } }
        .onChange(of: question) { _, q in if provider != nil { lastQuestion = q } }
    }

    /// One chip per session, scrolling sideways when there are more than fit (owner, 11-07: the chat was cut off when
    /// seven chips pushed the card wider than its frame); each title at most 150 pt.
    private func chips(_ p: AgentProvider, shown: AgentSession) -> some View {
        HStack(spacing: 6) {
            Group {
                if motion.stills {
                    chipRow(p, shown: shown).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()   // stills can't draw a scroll view
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) { chipRow(p, shown: shown) }
                            .onAppear { proxy.scrollTo(shown.id, anchor: .trailing) }
                            .onChange(of: shown.id) { _, id in withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            .frame(height: 28)
            .layoutPriority(-1)
            // A new conversation, from here (sim's `+` chip): the card turns into the ask field in place.
            Button { director.openAsk(new: true) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8)).frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .help("Ask something new")
            .accessibilityLabel("New question")
            if p == .ask {
                // The Ask chat stays open while you use the screen: it closes here, with Esc or with its ball.
                Button { director.closeAsk() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7)).frame(width: 28, height: 28).contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Close")
            } else {
                Button { director.openAgentApp(p) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7)).frame(width: 28, height: 28).contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .help("Open in \(IslandDirector.appName(Agents.app(of: shown)))")
                .accessibilityLabel("Open in \(IslandDirector.appName(Agents.app(of: shown)))")
            }
        }
        .frame(height: 28)
    }

    private func chipRow(_ p: AgentProvider, shown: AgentSession) -> some View {
                HStack(spacing: 6) {
                    ForEach(director.island.agents.sessions(p)) { x in
                        let title = presenting ? p.name : director.agentTitle(x), hover = chipHover == x.id
                        HStack(spacing: 2) {
                            Button { director.selectAgent(x) } label: {
                                HStack(spacing: 6) {
                                    AgentMark(provider: p == .ask ? (director.askBackend[x.id] ?? .claude) : p, size: 15)
                                    Text(title).font(.system(size: 13, weight: .medium))
                                        .lineLimit(1).frame(maxWidth: 150, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                                }
                                .padding(.leading, 8).frame(height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(PressScaleStyle())
                            .accessibilityAction(named: "Close") { director.closeSession(x) }
                            // The state dot, and the × in its place under the pointer (owner, 11-07: "put an x here so I
                            // can close some sessions"): the notch stops following that session. Same slot: nothing moves.
                            ZStack {
                                Circle().fill(AgentLook.segment(x.state)).frame(width: 6, height: 6).opacity(hover ? 0 : 1)
                                if hover {
                                    Button { director.closeSession(x) } label: {
                                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                            .frame(width: 16, height: 16)
                                            .background(Circle().fill(.white.opacity(0.16)))
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(PressScaleStyle())
                                    .help("Stop following this session")
                                    .accessibilityLabel("Close \(title)")
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                        .padding(.trailing, 6).frame(height: 28)
                        .foregroundStyle(x.id == shown.id || hover ? .white : .white.opacity(0.7))
                        .background(Capsule().fill(.white.opacity(x.id == shown.id ? 0.14 : 0)))
                        .overlay(Capsule().strokeBorder(.white.opacity(x.id == shown.id ? 0 : 0.16), lineWidth: 0.5))
                        .contentShape(Capsule())
                        .onHover { inside in
                            if inside { chipHover = x.id } else if chipHover == x.id { chipHover = nil }
                        }
                        .id(x.id)
                    }
                }
    }

    /// The recent items, newest at the bottom, scrolled to the newest; scrolling up shows the earlier ones (owner, 11-06:
    /// "I can't scroll in that chat"). Stills draw the last few without a scroll view (ImageRenderer can't draw one).
    @ViewBuilder private func messages(_ s: AgentSession) -> some View {
        let fade = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)],
                                  startPoint: .top, endPoint: .bottom)
        if motion.stills {
            messageList(s, items: Array((director.agentChats[s.id] ?? []).suffix(5).enumerated()))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .clipped()
                .mask(fade)
        } else {
            ScrollView(.vertical) {
                messageList(s, items: Array((director.agentChats[s.id] ?? []).enumerated()))
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(fade)
        }
    }

    private func messageList(_ s: AgentSession, items: [(offset: Int, element: AgentChatItem)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if presenting {
                Text("Hidden while presenting").foregroundStyle(.white.opacity(0.45))
            } else if items.isEmpty {
                Text(s.transcript.isEmpty && s.provider == .claude ? "Its messages show after its next step" : "No messages yet")
                    .foregroundStyle(.white.opacity(0.45))
            }
            if !presenting {
                ForEach(items, id: \.offset) { i, item in row(item, i) }
                if s.state == .working, !s.step.isEmpty {
                    Label(s.step, systemImage: "ellipsis").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
                }
                if s.state == .error { Text(s.step).foregroundStyle(IslandColor.red) }
            }
        }
        .font(.system(size: 13))
    }

    @ViewBuilder private func row(_ item: AgentChatItem, _ i: Int) -> some View {
        switch item {
        case .you(let t):
            HStack {
                Spacer(minLength: 64)
                Text(t).lineLimit(4).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.14)))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .agent(let t):
            Text(Self.markdown(t)).foregroundStyle(.white.opacity(0.92)).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .tools(let summary, let list):
            VStack(alignment: .leading, spacing: 4) {
                Button { if open.contains(i) { open.remove(i) } else { open.insert(i) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11))
                        Text(summary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open.contains(i) ? 90 : 0))
                    }
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open.contains(i) {
                    Text(list.joined(separator: "\n")).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55)).lineLimit(8).padding(.leading, 20)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What a session needs from you: boxed in orange inside the chat; on its own (the question card) it's the card, with
    /// the provider's mark leading.
    private func needBox(_ s: AgentSession, _ need: AgentNeed, boxed: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch need {
            case .permission(let tool, let detail):
                HStack(spacing: 6) {
                    if !boxed { mark(s.provider) }
                    Text(tool == "Bash" || tool == "shell" ? "Run this command?" : "Allow this?").fontWeight(.semibold)
                    Text(tool).foregroundStyle(.white.opacity(0.55))
                }
                HStack(spacing: 8) {
                    Text(presenting ? "Hidden while presenting" : (detail.isEmpty ? tool : detail))
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(boxed ? Color.black.opacity(0.4) : Color.white.opacity(0.1)))
                    if director.answerable.contains(s.id) {
                        pill("Deny", prime: false) { director.answerAgent(s.id, allow: false) }
                        pill("Allow", prime: true) { director.answerAgent(s.id, allow: true) }
                    } else {
                        // Held too long (the hook gave up), or its app was in front: it's asked there.
                        pill("Answer", prime: true) { director.openAgentApp(s.provider) }
                    }
                }
            case .question(let text, let options):
                // The question in full (owner, 11-07: "I can't read the whole thing"), the card grows to fit it.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !boxed { mark(s.provider) }
                    Text(presenting ? "\(s.provider.name) asks you" : text).fontWeight(.semibold)
                        .lineLimit(Island.questionLines(text)).fixedSize(horizontal: false, vertical: true)
                        .help(text)
                }
                HStack(spacing: 6) {
                    let canAnswer = director.answerable.contains(s.id)
                    ForEach(Array(options.prefix(3).enumerated()), id: \.offset) { _, o in
                        // While the hook still waits, an option answers it from here (sim AG2).
                        Button { director.answerQuestion(s.id, o) } label: {
                            Text(o).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(Capsule().fill(.white.opacity(o == detailOption(options) ? 0.22 : canAnswer ? 0.14 : 0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressScaleStyle())
                        .disabled(!canAnswer)
                        .onHover { inside in restOn(inside ? o : nil) }
                    }
                    Spacer(minLength: 0)
                    if !canAnswer { pill("Answer", prime: true) { director.openAgentApp(s.provider) } }
                }
                // The option you rest on, in full: its label and what it means. It changes only after a moment on
                // another option and never snaps back, so moving across the pills doesn't make it jump.
                if !presenting, let o = detailOption(options) {
                    let detail = director.optionDetail(s.id, o)
                    (Text(o).fontWeight(.semibold).foregroundStyle(.white.opacity(0.9))
                        + Text(detail.map { " · \($0)" } ?? "").foregroundStyle(.white.opacity(0.6)))
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                        .animation(.easeOut(duration: 0.15), value: o)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, boxed ? 12 : 0).padding(.vertical, boxed ? 10 : 0)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IslandColor.orange.opacity(boxed ? 0.13 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(IslandColor.orange.opacity(boxed ? 0.4 : 0), lineWidth: 0.5))
    }

    private func detailOption(_ options: [String]) -> String? {
        if let o = restedOption, options.contains(o) { return o }
        return options.first
    }

    /// Resting on a pill for 0.3 s makes it the one described; moving across the pills on the way to another changes
    /// nothing, and leaving keeps the last one.
    private func restOn(_ o: String?) {
        restingOn = o
        guard let o else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if restingOn == o { restedOption = o }
        }
    }

    private func mark(_ p: AgentProvider) -> some View {
        AgentMark(provider: p, size: 16)
    }

    /// A capsule field with a send button, like Messages' inline reply; the placeholder says where the reply goes.
    /// Who answers this session: its provider, or for an Ask conversation the backend it runs on.
    private func backendOf(_ s: AgentSession) -> AgentProvider {
        s.provider == .ask ? (director.askBackend[s.id] ?? .claude) : s.provider
    }

    /// The Ask chat's Screen toggle: a fresh look at the screen goes with each message while it's on.
    private var screenChip: some View {
        let on = director.askShotOn && director.askShotAllowed
        return Button { director.toggleAskShot() } label: {
            Image(systemName: "display").font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? .white : .white.opacity(0.45))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(on ? 0.16 : 0.06)))
                .overlay(on ? nil : Image(systemName: "line.diagonal").font(.system(size: 18, weight: .regular)).foregroundStyle(.white.opacity(0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .help(on ? "Sees your screen with each message" : "Your screen stays private")
        .accessibilityLabel(on ? "Screen: on" : "Screen: off")
    }

    private func replyField(_ s: AgentSession) -> some View {
        let placeholder = director.agentNotes[s.id] ?? director.replyPlaceholder(s)
        return HStack(spacing: 0) {
            if motion.stills {
                Text(placeholder).foregroundStyle(.white.opacity(0.4)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $reply)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { send(s) }
                    .onExitCommand { if s.provider == .ask { director.closeAsk() } }
                    .accessibilityLabel("Reply to \(s.provider.name)")
            }
            Button { send(s) } label: {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(backendOf(s) == .claude ? .white : .black)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(backendOf(s) == .claude ? AgentLook.clay : .white))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(pressed: 0.85, hover: 1.06))
            .accessibilityLabel("Send")
        }
        .font(.system(size: 13))
        .padding(.leading, 14).padding(.trailing, 3)
        .frame(height: 32)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.35 : 0.12), lineWidth: focused ? 1 : 0.5))
    }

    private func send(_ s: AgentSession) {
        guard !reply.trimmingCharacters(in: .whitespaces).isEmpty else { focused = true; return }
        director.replyAgent(s, reply)
        reply = ""
    }

    private func pill(_ title: String, prime: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prime ? .black : .white)
                .padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(prime ? IslandColor.orange : .white.opacity(0.14)))
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Inline Markdown (bold, code, links) as the agents write it; anything else as plain text.
    static func markdown(_ t: String) -> AttributedString {
        (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
    }
}

/// A ball's own hover (owner, 11-06): its peek hangs under it, two lines: who, and where it stands. A song's is the
/// notch's hover row (`Island.peekCard`). It keeps what it last showed while it fades out (it used to pop out).
struct BallPeekLayer: View {
    let frame: FrameModel
    let director: IslandDirector
    let party: Party?
    @State private var last: Party?

    var body: some View {
        Group {
            if let party = party ?? last {
                let card = Island.peekCard(party)
                CardPlacement(frame: frame, card: card) {
                    Group {
                        if party == .media { mediaRow }
                        else if let a = director.island.instance(party), a.id == .meeting { meetingRow(a) }
                        else { row(party) }
                    }
                    .frame(width: card.width, height: card.height)
                    .foregroundStyle(.white)
                }
            }
        }
        .onChange(of: party) { _, p in if p != nil { last = p } }
    }

    /// An event's ball peeks as the ears show it: the ring, the title over the time left, and a line bar.
    private func meetingRow(_ a: ActivityInstance) -> some View {
        let m = director.meetingFor(a)
        let state = EventRing.State(meeting: m, now: director.date())
        return HStack(spacing: 10) {
            EventRing(meeting: m, now: director.date(), size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(director.island.context.presenting ? "Event" : m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(state.figure + (state.started ? " left" : " to start"))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(state.textColor.opacity(0.85)).lineLimit(1)
            }
            Spacer(minLength: 6)
            LineBar(progress: state.started ? state.elapsed : state.progress, tint: state.started ? state.color : .white.opacity(0.6))
                .frame(width: 64, height: 6)
        }
        .padding(.horizontal, 17)
    }

    private func row(_ party: Party) -> some View {
        let (title, line) = director.peekText(party)
        return HStack(spacing: 10) {
            PartyGlyph(party: party, director: director).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
    }

    /// A song's ball peeks like the notch's hover (owner, 11-06: "the music ball hover should have the buttons from the
    /// notch hover"): the cover, title over artist, the bars, and previous / play-pause / next, which act without
    /// opening the player (a press anywhere else on it opens the player).
    private var mediaRow: some View {
        HStack(spacing: 10) {
            AlbumArt(media: director.media, corner: 8).frame(width: 30, height: 30)
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(director.media.title).font(.system(size: 13, weight: .semibold))
                    Text(director.media.artist).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                .id(director.media.id)
                .transition(.trackSwap)
            }
            .animation(.easeInOut(duration: 0.28), value: director.media.id)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            EqualizerBars(color: Color(hex: director.media.colorHex), playing: director.playing, visible: party != nil)
                .frame(width: 18, height: 13)
            HStack(spacing: 2) {
                PeekButton(symbol: "backward.fill", size: 11, label: "Previous track") { director.nextTrack(-1) }
                PeekButton(symbol: director.playing ? "pause.fill" : "play.fill", size: 12,
                           label: director.playing ? "Pause" : "Play") { director.togglePlaying() }
                PeekButton(symbol: "forward.fill", size: 11, label: "Next track") { director.nextTrack(1) }
            }
        }
        .padding(.horizontal, 15)
    }
}
