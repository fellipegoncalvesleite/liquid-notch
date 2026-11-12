import AppKit
import Observation

/// What's in the tray (design `docs/superpowers/specs/2026-11-01-idle-tray-design.md`): the page showing, the
/// clipboard's recent text, the files on the shelf, the user's shortcuts and the Focus picked here. The island
/// decides when the tray shows; this decides what's in it.
@MainActor @Observable
final class TrayModel {
    enum Page: String, CaseIterable, Sendable { case main, timer, focus, clipboard, shelf, shortcuts, today }

    struct Clip: Equatable, Identifiable {
        let id: Int
        let text: String
        var isLink: Bool { text.hasPrefix("http://") || text.hasPrefix("https://") }
    }

    /// The four Focus modes macOS ships with. Nothing public sets one: `FocusSwitcher` presses it in Control Center.
    enum FocusMode: String, CaseIterable, Identifiable, Sendable {
        case doNotDisturb = "Do Not Disturb", work = "Work", personal = "Personal", sleep = "Sleep"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .doNotDisturb: "moon.fill"
            case .work: "briefcase.fill"
            case .personal: "person.fill"
            case .sleep: "bed.double.fill"
            }
        }
    }

    private(set) var page: Page = .main
    /// The page the next opening starts at (the Shelf when a file is dragged in).
    @ObservationIgnored var nextPage: Page = .main
    private(set) var clips: [Clip] = []
    private(set) var files: [URL] = []
    /// The user's shortcuts (nil until listed).
    private(set) var shortcuts: [String]?
    /// The Focus that's on: what the system says when it can say which (any mode, custom ones too), else the one last
    /// picked here.
    private(set) var focus: FocusMode?
    /// Its name as macOS calls it ("Work", "Reading"), when the system says.
    private(set) var focusName: String?
    /// A row that just ran or copied, shown with a check for a moment.
    private(set) var done: String?

    // Wiring
    @ObservationIgnored var copyToPasteboard: ((String) -> Void)?
    @ObservationIgnored var runShortcut: ((String) -> Void)?
    @ObservationIgnored var listShortcuts: (() -> Void)?
    /// Presses a Focus mode in Control Center (pressing the one that's on turns it off).
    @ObservationIgnored var toggleFocus: ((FocusMode) -> Void)?
    @ObservationIgnored private var clipSerial = 0
    @ObservationIgnored private var doneClear: Task<Void, Never>?

    static let maxClips = 8

    /// The tray just appeared: it starts at the grid, or wherever a drag asked for.
    func opened() {
        page = nextPage
        nextPage = .main
        done = nil
        if page == .shortcuts { listShortcuts?() }
    }

    func go(_ p: Page) {
        page = p
        done = nil
        if p == .shortcuts { listShortcuts?() }
    }

    // MARK: - Clipboard

    func addClip(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        clipSerial += 1
        clips = Array(([Clip(id: clipSerial, text: t)] + clips.filter { $0.text != t }).prefix(Self.maxClips))
    }

    func copy(_ clip: Clip) {
        copyToPasteboard?(clip.text)
        flash("clip\(clip.id)")
    }

    func clearClips() { clips = [] }

    // MARK: - Shelf

    func addFiles(_ urls: [URL]) {
        let new = urls.filter { u in !files.contains(u) }
        files = new + files
        page = .shelf
    }

    func clearFiles() { files = [] }

    // MARK: - Shortcuts and Focus

    func shortcutsListed(_ names: [String]) { shortcuts = names }

    /// The first four of the user's shortcuts.
    var pinnedShortcuts: [String] { Array((shortcuts ?? []).prefix(4)) }

    func run(_ name: String) {
        runShortcut?(name)
        flash("sc\(name)")
    }

    /// Picks a mode (picking the one that's on turns it off).
    func pick(_ mode: FocusMode) {
        focus = focus == mode ? nil : mode
        focusName = focus?.rawValue
        toggleFocus?(mode)
    }

    /// The system says no Focus is on any more.
    func focusTurnedOff() { focus = nil; focusName = nil }

    /// The system says which Focus is on (turned on here or anywhere else).
    func systemFocus(_ name: String) {
        focusName = name
        focus = FocusMode(rawValue: name)
    }

    private func flash(_ key: String) {
        done = key
        doneClear?.cancel()
        doneClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, self?.done == key else { return }
            self?.done = nil
        }
    }
}
