import AppKit
import IslandCore
import SwiftUI

/// Live controls for the liquid: force each state, bend every spring and merge.
@MainActor
final class DebugPanelController {
    private var window: NSPanel?
    private let store: TuningStore
    private let surface: NotchSurfaceController

    init(store: TuningStore, surface: NotchSurfaceController) {
        self.store = store
        self.surface = surface
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { window?.orderOut(nil); return }
        if window == nil {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
            w.title = "Liquid Notch — Debug"
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DebugView(store: store, surface: surface))
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                w.setFrameOrigin(NSPoint(x: v.maxX - 380, y: v.maxY - 740))
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DebugView: View {
    @Bindable var store: TuningStore
    let surface: NotchSurfaceController
    @State private var mode: PresentationMode = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                states
                ActivityControls(director: surface.director)
                ContextControls(director: surface.director)
                LiveReadout(director: surface.director, keys: surface.keys)
                MotionControls(store: store, surface: surface)
                Section("Time") {
                    TuneSlider("Time scale", $store.tuning.timeScale, 0.05...1, "%.2f×")
                }
                SpringEditor(title: "Shape spring", config: $store.tuning.shapeSpring)
                SpringEditor(title: "Droplet spring", config: $store.tuning.dropletSpring)
                SpringEditor(title: "Glow spring", config: $store.tuning.glowSpring)
                Section("Merge (smooth-min k)") {
                    TuneSlider("k notch ↔ blob", $store.tuning.kNotch, 0...24, "%.1f")
                    TuneSlider("k droplet", $store.tuning.kDrop, 0...32, "%.1f")
                    TuneSlider("k bezel (ears)", $store.tuning.kBezelCompact, 0...30, "%.1f")
                    TuneSlider("k bezel (expanded)", $store.tuning.kBezelExpanded, 0...40, "%.1f")
                }
                Section("Droplet") {
                    TuneSlider("Radius", $store.tuning.dropRadius, 6...30, "%.1f pt")
                    TuneSlider("Gap from ear", $store.tuning.dropGap, 0...30, "%.1f pt")
                    TuneSlider("Neck thickness", $store.tuning.dynamics.neckRatio, 0...1, "%.2f")
                    TuneSlider("Neck break gap", $store.tuning.dynamics.breakGap, 0...24, "%.1f pt")
                    TuneSlider("Stretch gain", $store.tuning.dynamics.stretchGain, 0...0.004, "%.4f")
                    TuneSlider("Max stretch", $store.tuning.dynamics.maxStretch, 0...1, "%.2f")
                    TuneSlider("Pinch radius", $store.tuning.dynamics.pinchRadius, 0...3, "%.2f pt")
                    TuneSlider("Bulge delay", $store.tuning.bulgeDelay, 0...0.3, "%.2f s")
                    TuneSlider("Absorb delay", $store.tuning.absorbDelay, 0...0.3, "%.2f s")
                }
                Section("Opening, hover, press") {
                    TuneSlider("Pour sag", $store.tuning.pourDepth, 0...16, "%.1f pt")
                    TuneSlider("Pour spread", $store.tuning.pourSpread, 0...1, "%.2f")
                    TuneSlider("Pour hold", $store.tuning.pourDelay, 0...0.3, "%.2f s")
                    TuneSlider("Content delay", $store.tuning.contentDelay, 0...0.4, "%.2f s")
                    TuneSlider("Preview widen", $store.tuning.peekExtra, 0...60, "%.0f pt")
                    TuneSlider("Preview height", $store.tuning.peekHeight, 40...120, "%.0f pt")
                    TuneSlider("Preview radius", $store.tuning.peekRadius, 0...40, "%.0f pt")
                    TuneSlider("Axis lag", $store.tuning.axisLag, 0...0.2, "%.2f s")
                    TuneSlider("Press squish", $store.tuning.pressSquish, 0...16, "%.1f pt")
                    TuneSlider("Ear with 2 activities", $store.tuning.minimalExtent, 10...120, "%.0f pt")
                }
                Section("Bloom (dim glow)") {
                    TuneSlider("Brightness", $store.tuning.bloomIntensity, 0...0.3, "%.3f")
                    TuneSlider("Falloff (ears)", $store.tuning.bloomFalloff, 1...40, "%.0f pt")
                    TuneSlider("Falloff (open)", $store.tuning.bloomFalloffOpen, 1...80, "%.0f pt")
                    TuneSlider("Pulse", $store.tuning.pulseIntensity, 0...0.6, "%.2f")
                }
                Section("Card") {
                    TuneSlider("Half width", $store.tuning.cardHalfWidth, 120...260, "%.0f pt")
                    TuneSlider("Height", $store.tuning.cardHeight, 100...220, "%.0f pt")
                    TuneSlider("Radius", $store.tuning.cardRadius, 8...60, "%.0f pt")
                    TuneSlider("Gap below bar", $store.tuning.cardGap, 2...24, "%.1f pt")
                    TuneSlider("Bridge thickness", $store.tuning.cardNeckMax, 2...40, "%.1f pt")
                    TuneSlider("Bridge break gap", $store.tuning.cardBreakGap, 2...20, "%.1f pt")
                    TuneSlider("Close: rise hold (×2)", $store.tuning.budDelay, 0...0.3, "%.2f s")
                    TuneSlider("Hit margin", $store.tuning.hitPad, 0...12, "%.1f pt")
                    TuneSlider("Open card stays", $store.tuning.closeDelay, 0...8, "%.1f s")
                    TuneSlider("Preview stays", $store.tuning.leaveDelay, 0...2, "%.2f s")
                }
                Section("Shape") {
                    TuneSlider("Ear extent", $store.tuning.earExtent, 10...200, "%.0f pt")
                    TuneSlider("Ear radius", $store.tuning.earRadius, 0...19, "%.1f pt")
                    TuneSlider("HUD extent", $store.tuning.hudExtent, 10...220, "%.0f pt")
                    TuneSlider("Expanded half width", $store.tuning.expandedHalfWidth, 110...360, "%.0f pt")
                    TuneSlider("Expanded height", $store.tuning.expandedHeight, 60...280, "%.0f pt")
                    TuneSlider("Expanded radius", $store.tuning.expandedRadius, 0...80, "%.0f pt")
                    TuneSlider("Corner exponent", $store.tuning.cornerExponent, 2...5, "%.2f")
                    TuneSlider("Notch radius", $store.tuning.notchRadius, 0...16, "%.1f pt")
                    TuneSlider("Idle inset", $store.tuning.idleInset, 0...4, "%.1f pt")
                    TuneSlider("Rest: wider", $store.tuning.idleGrow, 0...6, "%.1f pt")
                    TuneSlider("Rest: lower", $store.tuning.idleDrop, 0...3, "%.1f pt")
                    TuneSlider("Rest: corner radius", $store.tuning.idleRadius, 6...19, "%.1f pt")
                    TuneSlider("Rest: shoulder flare", $store.tuning.idleBezel, 0...16, "%.1f")
                    TuneSlider("Edge feather", $store.tuning.edgeFeather, 0.5...6, "%.1f px")
                }
                Section("Aura") {
                    TuneSlider("Glow (ears)", $store.tuning.glowCompact, 0...1, "%.2f")
                    TuneSlider("Falloff (ears)", $store.tuning.falloffCompact, 1...40, "%.0f pt")
                    TuneSlider("Glow (expanded)", $store.tuning.glowExpanded, 0...1, "%.2f")
                    TuneSlider("Falloff (expanded)", $store.tuning.falloffExpanded, 1...80, "%.0f pt")
                    ColorPicker("Aura color", selection: auraBinding, supportsOpacity: false)
                    HStack {
                        ForEach(["#FF4FA3", "#7C5CFF", "#2EC5FF", "#3DDC84", "#FFB020", "#FF5A36"], id: \.self) { hex in
                            Button { store.tuning.auraHex = hex } label: {
                                Circle().fill(Color(srgb: SRGB.parse(hex)!)).frame(width: 18, height: 18)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Button("Copy values") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.json, forType: .string)
                    }
                    Button("Reset to defaults") { store.reset() }
                }
            }
            .padding(14)
        }
        .frame(minWidth: 340, minHeight: 400)
    }

    private var states: some View {
        Section("Force shape") {
            Picker("", selection: $mode) {
                ForEach(PresentationMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _, m in surface.present(m) }
        }
    }

    private var auraBinding: Binding<Color> {
        Binding(
            get: { Color(srgb: SRGB.parse(store.tuning.auraHex) ?? SIMD3(1, 0.3, 0.6)) },
            set: { c in
                let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
                store.tuning.auraHex = SRGB.hex(SIMD3(Double(ns.redComponent), Double(ns.greenComponent),
                                                      Double(ns.blueComponent)))
            })
    }
}

/// Sample music, HUD and activities, so every state can be driven without real data (P1).
private struct ActivityControls: View {
    let director: IslandDirector

    private static let names: [(ActivityID, String)] = [
        (.incoming, "Incoming call"), (.airpods, "AirPods"), (.charging, "Plug in charger"),
        (.timer, "Timer"), (.recording, "Screen recording"), (.meeting, "Next meeting"),
        (.camera, "Camera on"), (.download, "Download"), (.messages, "Messages"),
        (.chess, "Chess"), (.agentLimit, "Usage limit"), (.agentBack, "Limit reset"),
        (.lockScreen, "Locked"), (.unlocked, "Unlock moment"),
    ]

    var body: some View {
        Section("Activities (samples)") {
            HStack {
                Button(director.sampleOn ? "Stop sample music" : "Play sample music") {
                    director.sampleOn ? director.stopMusic() : director.startMusic()
                }
                Button("Next track") { director.nextTrack() }
                Button("Volume up") { director.volumeUp() }
                Button("Brightness up") { director.brightnessUp() }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Self.names, id: \.0) { id, name in
                    // A lit button ends its activity (owner, 11-06: "can't unmark things"), wherever it runs.
                    let running = director.island.running.first { $0.id == id }
                    Button(name) { if let running { director.end(serial: running.serial) } else { director.show(id) } }
                        .tint(running != nil ? .accentColor : nil)
                        .buttonStyle(.bordered)
                }
                // Football (sim's strip): a pressed team ends its match or its reminder.
                ForEach([("pal", "Palmeiras"), ("bar", "Barcelona")], id: \.0) { key, name in
                    Button(name) { director.footballButton(key) }
                        .tint(director.footballRunning(key) ? .accentColor : nil)
                        .buttonStyle(.bordered)
                }
                Button("Focus on") { director.showFocusSample(on: true) }.buttonStyle(.bordered)
                Button("Focus off") { director.showFocusSample(on: false) }.buttonStyle(.bordered)
                Button("Battery 20%") { director.showLowBatterySample(level: 20) }.buttonStyle(.bordered)
                Button("Battery 10%") { director.showLowBatterySample(level: 10) }.buttonStyle(.bordered)
                // Notifications (11-07): the next sample (every shape and level in turn), and the center.
                Button("Notification") { director.notifySample() }.buttonStyle(.bordered)
                Button("End activity") { director.endActivity() }
                    .disabled(director.island.activity == nil)
            }
            Text("Now Playing: \(director.nowPlaying.map { "\($0.title) · \($0.playing ? "playing" : "paused")" } ?? "nothing") (from \(director.nowPlayingSource)). Hover the ears for a preview, click to open the card.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Where you are on the Mac: what the system reports (Live), or the simulator's Context strip to fake it.
private struct ContextControls: View {
    let director: IslandDirector

    private static let apps: [(String, String)] = [
        (BundleID.finder, "Finder"), (BundleID.music, "Music"), (BundleID.faceTime, "FaceTime"),
        (BundleID.safari, "Safari"), (BundleID.keynote, "Keynote"),
    ]

    var body: some View {
        let c = director.island.context
        let sys = director.systemContext
        Section("Context") {
            Toggle("Live: the island follows the Mac", isOn: Binding(get: { director.liveContext },
                                                                   set: { director.setLiveContext($0) }))
            Text("System: \(sys.frontmostApp)\(sys.fullscreen ? " · fullscreen" : "")\(sys.menuOpen ? " · menu open" : "")\(sys.locked ? " · locked" : "")\(sys.micInUse ? " · mic in use" : "")\(sys.cameraInUse ? " · camera in use" : "")\(sys.focusOn.map { $0 ? " · Focus on" : " · Focus off" } ?? " · Focus unknown")")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Picker("Frontmost app", selection: binding(\.frontmostApp)) {
                ForEach(Self.apps, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Fullscreen video", isOn: binding(\.fullscreen))
                Toggle("Menu open", isOn: binding(\.menuOpen))
                Toggle("Typing", isOn: binding(\.typing))
                Toggle("Sharing screen", isOn: binding(\.sharing))
            }
            .toggleStyle(.button)
            if c.presenting {
                Text("Presenting: transients stay off, names and texts are hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding<V>(_ kp: WritableKeyPath<DesktopContext, V>) -> Binding<V> {
        Binding(get: { director.island.context[keyPath: kp] },
                set: { v in
                    // Touching a control fakes the context: Live goes off until switched back on.
                    var c = director.island.context
                    c[keyPath: kp] = v
                    director.setLiveContext(false)
                    director.setContext(c)
                })
    }
}

/// What the live activities read (P4).
private struct LiveReadout: View {
    let director: IslandDirector
    let keys: MediaKeyTap

    var body: some View {
        Section("Live") {
            Text([
                director.power.map { "Battery \($0.level)% · \($0.status)" } ?? "Battery: none",
                director.meeting.map { "Next meeting at \($0.start.formatted(date: .omitted, time: .shortened))\($0.joinURL != nil ? " · join link" : "")" } ?? "No meeting within 10 min",
                director.pods.map { "\($0.name) · buds \($0.buds.map { "\($0)%" } ?? "?") · case \($0.caseLevel.map { "\($0)%" } ?? "?")" } ?? "AirPods: not connected since launch",
                keys.running ? "Volume/brightness keys: ours (system HUD replaced)" : "Volume/brightness keys: system (allow Accessibility)",
            ].joined(separator: "\n"))
            .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

/// Glow options and a Reduce Motion override.
private struct MotionControls: View {
    @Bindable var store: TuningStore
    let surface: NotchSurfaceController
    @State private var reduceMotion = false

    var body: some View {
        Section("Look") {
            HStack {
                Toggle("Dim glow", isOn: $store.tuning.dimGlow)
                Toggle("Pulse", isOn: $store.tuning.glowPulse).disabled(!store.tuning.dimGlow)
                Toggle("Hairline", isOn: $store.tuning.hairline).disabled(!store.tuning.dimGlow)
                Toggle("Reduce Motion", isOn: $reduceMotion)
                    .onChange(of: reduceMotion) { _, on in surface.forceReduceMotion = on }
            }
            .toggleStyle(.button)
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct SpringEditor: View {
    let title: String
    @Binding var config: SpringConfig
    var body: some View {
        Section(title) {
            TuneSlider("Stiffness", $config.stiffness, 10...1200, "%.0f")
            TuneSlider("Damping", $config.damping, 1...80, "%.1f")
            Text(String(format: "ζ = %.2f   settles in ≈ %.2f s", config.dampingRatio, config.settleTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct TuneSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    init(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String) {
        self.label = label
        _value = value
        self.range = range
        self.format = format
    }
    var body: some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .frame(width: 62, alignment: .trailing)
        }
    }
}

private extension Color {
    init(srgb c: SIMD3<Double>) { self.init(.sRGB, red: c.x, green: c.y, blue: c.z) }
}
