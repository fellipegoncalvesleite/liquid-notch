import IslandCore
import QuartzCore
import XCTest
@testable import LiquidNotch

/// The island on the lock screen (11-07, docs/superpowers/specs/2026-11-07-lock-screen-design.md).
@MainActor
final class LockTests: XCTestCase {
    private func director() -> (IslandDirector, ManualScheduler) {
        let d = IslandDirector(), s = ManualScheduler()
        d.schedule = s.schedule
        d.frontmostApp = { "" }
        return (d, s)
    }

    // LOCK1: locked, the lock holds the ears and the song leaves the island (its card below the clock has it).
    func testLOCK1LockedIsland() {
        let (d, _) = director()
        d.startMusic()
        XCTAssertEqual(d.island.arrangement.ears, .media)
        d.systemContextChanged(DesktopContext(lockScreen: true))
        XCTAssertEqual(d.island.activity?.id, .lockScreen)
        XCTAssertEqual(d.island.arrangement.ears, .activity)
        XCTAssertFalse(d.island.arrangement.all.contains(.media), "the song is on its lock-screen card, not the island")
        XCTAssertTrue(d.island.mediaOn, "still playing")
        // A press on the lock opens nothing.
        d.pointerDown(at: .zero, hit: .ears)
        d.pointerUp(at: .zero, hit: .ears, corridor: false)
        XCTAssertFalse(d.island.opened)
    }

    // LOCK2: unlocking plays the moment (the lock opens, the check), then the song comes back to the ears.
    func testLOCK2UnlockMoment() {
        let (d, s) = director()
        d.startMusic()
        d.systemContextChanged(DesktopContext(lockScreen: true))
        d.systemContextChanged(DesktopContext())
        XCTAssertEqual(d.island.activity?.id, .unlocked)
        XCTAssertFalse(d.island.running.contains { $0.id == .lockScreen })
        s.advance(1.3)
        XCTAssertNil(d.island.activity)
        XCTAssertEqual(d.island.arrangement.ears, .media, "the island hands back what was there")
    }

    // LOCK3: the card sits centred below the clock, its bottom where the collapsed card's is; the window has room above
    // for the enlarged artwork.
    func testLOCK3CardFrame() {
        let screen = NSRect(x: 0, y: 0, width: 1710, height: 1112)
        let f = LockCardController.frame(on: screen, avatarHidden: true)
        XCTAssertEqual(f.midX, screen.midX, accuracy: 0.5)
        let collapsedCentreFromTop = screen.maxY - (f.minY + LockCardController.collapsed.height / 2)
        XCTAssertEqual(collapsedCentreFromTop / screen.height, LockCardController.centreFromTop, accuracy: 0.001)
        XCTAssertEqual(f.height, LockCardController.expanded.height)
        XCTAssertGreaterThan(screen.maxY - f.maxY, 230, "clear of the system clock at the top")
        XCTAssertGreaterThan(f.minY, 100, "above the bottom edge, where the account photo was")
        // The owner's screenshot (11-07): the card's bottom touched the password field (its top at 1000 pt from the top).
        XCTAssertGreaterThanOrEqual(1000 - (screen.maxY - f.minY), 20, "clear of the password field")
    }

    // LOCK4: the album-art wallpaper is screen-sized (2×), the cover blurred behind and sharp between the clock and the
    // card; the flying cover (sprite) holds it with its shadow's margin, and the file is written.
    func testLOCK4ArtWallpaperImage() throws {
        let art = NSImage(size: NSSize(width: 300, height: 300))
        art.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 300, height: 300).fill(); art.unlockFocus()
        let cg = try XCTUnwrap(art.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ln-lock4-\(UUID().uuidString)")
        // The owner's lock screen hides the account photo (the card sits low); not whatever the test Mac is set to.
        let p = try XCTUnwrap(LockWallpaper.parts(key: "k", art: cg, size: CGSize(width: 1710, height: 1112), folder: folder,
                                                  avatarHidden: true))
        XCTAssertEqual(p.back.width, 3420)
        XCTAssertEqual(p.back.height, 2224)
        // Centred between the clock (its digits end 265 pt from the top) and the card, and clear of the card with its
        // lyrics open (the owner's screenshots, 11-07: under the clock and into the card; then closer to the clock).
        let card = LockCardController.frame(on: NSRect(x: 0, y: 0, width: 1710, height: 1112), avatarHidden: true)
        // The card as it is while the art is the wallpaper: no cover of its own, shorter (owner, 11-07).
        let cardTop = card.minY + LockCardController.bare.height
        XCTAssertEqual((1112 - p.coverRect.maxY) - 265, p.coverRect.minY - cardTop, accuracy: 1, "as far from the clock as from the card")
        XCTAssertGreaterThanOrEqual(p.coverRect.minY - (card.minY + LockCardController.bareLyrics.height), 8, "clear of the lyrics")
        XCTAssertGreaterThan(p.coverRect.height, 380)
        XCTAssertEqual(p.coverRect.width, p.coverRect.height)
        XCTAssertEqual(p.coverRect.midX, 855, accuracy: 0.5)
        XCTAssertTrue(p.spriteRect.contains(p.coverRect))
        XCTAssertEqual(Double(p.sprite.width) / 2, p.spriteRect.width, accuracy: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.file.path))
        try? FileManager.default.removeItem(at: folder)
    }

    // LOCK4b: with the account photo showing, the card goes up; the cover still sits between the clock and the card,
    // centred and clear of the lyrics (smaller, as there's less room).
    func testLOCK4ArtWithTheAvatarShowing() {
        let size = CGSize(width: 1710, height: 1112)
        let cover = LockWallpaper.coverRect(in: size, avatarHidden: false)
        let card = LockCardController.frame(on: NSRect(origin: .zero, size: size), avatarHidden: false)
        XCTAssertGreaterThan(cover.height, 150)
        XCTAssertEqual(cover.midX, 855, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(cover.minY - (card.minY + LockCardController.bareLyrics.height), 8, "clear of the lyrics")
        XCTAssertLessThanOrEqual(cover.maxY, size.height * (1 - LockWallpaper.clockBottom), "under the clock")
    }


    // DESK1: the desktop's colours dim more at night (8 pm to 7 am; owner, 11-07: "especially at night").
    func testDESK1NightVeil() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: hour))! }
        XCTAssertTrue(DesktopColors.isNight(at(23), calendar: cal))
        XCTAssertTrue(DesktopColors.isNight(at(3), calendar: cal))
        XCTAssertFalse(DesktopColors.isNight(at(7), calendar: cal))
        XCTAssertFalse(DesktopColors.isNight(at(14), calendar: cal))
        XCTAssertTrue(DesktopColors.isNight(at(20), calendar: cal))
    }

    // BEAT2 (owner, 11-07: "can't it pulse and not bug me? the strip? because desktop beating makes no sense"): the
    // strip pulses wherever you are while music plays; held during a Focus and while presenting; softer while you type.
    func testBEAT2PulsesGentlyWherever() {
        func scale(focus: Bool? = false, key: Double = 60, presenting: Bool = false) -> Double {
            DesktopColors.pulseScale(focusOn: focus, secondsSinceKey: key, presenting: presenting)
        }
        XCTAssertEqual(scale(), 1)
        XCTAssertEqual(scale(key: 5), 0.6, "typing: softer, still there")
        XCTAssertEqual(scale(focus: true), 0)
        XCTAssertEqual(scale(presenting: true), 0)
        XCTAssertEqual(scale(focus: nil), 1, "Focus unknown")
    }

    // DESK2 (owner, 11-07: "not getting darker on pause"): pausing stops only the breathing. The strip, its glow and
    // the veil live outside the paused layer, so the paused tone (and a beat, and the night veil) still animate; under
    // a paused parent an animation stays on its first frame.
    func testDESK2PausingStopsOnlyTheBreathing() {
        let l = DesktopColors.layers(size: CGSize(width: 1710, height: 1112), bar: 37.5)
        func under(_ layer: CALayer, _ ancestor: CALayer) -> Bool {
            var p = layer.superlayer
            while let s = p { if s === ancestor { return true }; p = s.superlayer }
            return false
        }
        XCTAssertTrue(l.copies.allSatisfy { under($0, l.drift) }, "the cover breathes in the drift")
        for layer in [l.strip, l.glow, l.veil, l.flowFade, l.flowClock, l.flow, l.dim] {
            XCTAssertTrue(under(layer, l.root))
            XCTAssertFalse(under(layer, l.drift), "outside the paused layer")
        }
        XCTAssertNotNil(l.copies.first?.animation(forKey: "breathe"))
    }

    // BEAT3 (owner: "can't it pulse and not bug me?", then of +5% to +8% over the whole strip: "i asked it to make faint
    // glows under beats following the bars … nothing"): a pulse is a soft light beside the notch, 0.04–0.09 lighter in
    // OKLab at its peak by day (seen from the corner of the eye, never a flash), less at night; brightness only, gone
    // a few hundred points out.
    func testBEAT3AFaintLightBesideTheNotch() {
        XCTAssertEqual(DesktopColors.beatLift(strength: 0, night: false), 0, "nothing while the bars hold still")
        XCTAssertGreaterThanOrEqual(DesktopColors.beatLift(strength: 1, night: false), 0.05)
        XCTAssertLessThanOrEqual(DesktopColors.beatLift(strength: 1, night: false), 0.09)
        XCTAssertLessThan(DesktopColors.beatLift(strength: 1, night: true), DesktopColors.beatLift(strength: 1, night: false))
        let w = 1710.0
        XCTAssertEqual(DesktopColors.glowShape(w / 2 + 110, width: w), 1, accuracy: 0.01, "full beside the notch")
        XCTAssertLessThan(DesktopColors.glowShape(w / 2 + 600, width: w), 0.01, "gone 600 pt out")
        XCTAssertEqual(DesktopColors.glowShape(300, width: w), DesktopColors.glowShape(w - 300, width: w), accuracy: 1e-9)
        let main = DesktopColors.RGB(r: 0.12, g: 0.2, b: 0.42)
        let lit = DesktopColors.glowColour(main)
        func hue(_ c: DesktopColors.RGB) -> Double { DesktopColors.perceivedHue(c) }
        XCTAssertEqual(hue(lit), hue(main), accuracy: 2, "light, not another hue")
        XCTAssertGreaterThan(DesktopColors.oklab(lit).0, DesktopColors.oklab(main).0 + 0.1)
    }

    // STRIP1 (owner, 11-07: "most of them look flat", then of the lit version "the strip looks artificial"): a shade
    // lighter behind the notch and deeper at the edges, the same on both sides, never an effect (within ±10%).
    func testSTRIP1AShadeLighterBehindTheNotch() {
        let w = 1710.0
        let middle = DesktopColors.across(w / 2, width: w), edge = DesktopColors.across(0, width: w)
        XCTAssertGreaterThan(middle / edge, 1.05)
        XCTAssertLessThan(middle / edge, 1.2)
        XCTAssertLessThanOrEqual(abs(middle - 1), 0.1)
        XCTAssertLessThanOrEqual(abs(edge - 1), 0.1)
        XCTAssertEqual(DesktopColors.across(400, width: w), DesktopColors.across(w - 400, width: w), accuracy: 1e-9)
    }

    // STRIP2: lit up, the strip never gets too light for the menu bar's white text (4.5:1, relative luminance 0.18),
    // and keeps its hue (the channels scale together).
    func testSTRIP2WhiteTextStaysLegible() {
        func luminance(_ c: DesktopColors.RGB) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        let silver = DesktopColors.RGB(r: 0.77, g: 0.77, b: 0.79)   // a white cover's neutral, lit behind the notch
        let lit = DesktopColors.legible(silver)
        XCTAssertLessThanOrEqual(luminance(lit), 0.18)
        XCTAssertEqual(lit.b / lit.r, silver.b / silver.r, accuracy: 1e-9)
        let deep = DesktopColors.RGB(r: 0.2, g: 0.13, b: 0.34)      // a deep purple stays as it is
        XCTAssertEqual(DesktopColors.legible(deep), deep)
    }

    /// A cover of `main` with a patch of `patch` in a corner.
    private func cover(_ main: (Double, Double, Double), patch: (Double, Double, Double)) throws -> CGImage {
        let c = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(srgbRed: main.0, green: main.1, blue: main.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        c.setFillColor(CGColor(srgbRed: patch.0, green: patch.1, blue: patch.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        return try XCTUnwrap(c.makeImage())
    }

    // STRIP3 (owner, 11-07: "is he taking from default colors instead of the album? stop that right now", of a
    // mustard cover with a green strip; "it's turning blue albums purple???"): the strip is the cover's own main colour
    // made deep, its hue as the eye sees it within 4° of the cover's, never remapped.
    func testSTRIP3TheCoversOwnColour() throws {
        func hue(_ c: (Double, Double, Double)) -> Double { DesktopColors.perceivedHue(DesktopColors.RGB(r: c.0, g: c.1, b: c.2)) }
        func off(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
        let covers: [(String, (Double, Double, Double))] = [
            ("navy", (0.08, 0.04, 0.35)), ("mustard", (0.78, 0.6, 0.14)), ("forest", (0.12, 0.32, 0.1)),
            ("purple", (0.32, 0.1, 0.45)), ("red", (0.6, 0.08, 0.08)), ("sky", (0.35, 0.6, 0.85)),
        ]
        for (name, c) in covers {
            let s = DesktopColors.stripColour(try cover(c, patch: c))
            XCTAssertLessThanOrEqual(off(DesktopColors.perceivedHue(s), hue(c)), 4, name)
            let (l, _, _) = DesktopColors.oklab(s)
            XCTAssertLessThanOrEqual(l, DesktopColors.depth.upperBound + 1e-6, "\(name): deep")
            XCTAssertGreaterThanOrEqual(l, DesktopColors.depth.lowerBound - 1e-6, "\(name): about the same depth, never black")
        }
    }

    // STRIP4: only as rich as the cover: a muted cover gives a muted strip (OKLab saturation, chroma over lightness).
    func testSTRIP4OnlyAsRichAsTheCover() throws {
        func saturation(_ c: DesktopColors.RGB) -> Double { let (l, a, b) = DesktopColors.oklab(c); return (a * a + b * b).squareRoot() / l }
        for c in [DesktopColors.RGB(r: 0.45, g: 0.5, b: 0.58), DesktopColors.RGB(r: 0.55, g: 0.45, b: 0.35), DesktopColors.RGB(r: 0.78, g: 0.6, b: 0.14)] {
            let s = DesktopColors.stripColour(try cover((c.r, c.g, c.b), patch: (c.r, c.g, c.b)))
            XCTAssertLessThanOrEqual(saturation(s), saturation(c) + 0.01)
        }
    }

    /// A cover of `field` with `share` of it painted with each of `marks` (in bands from the top).
    private func plain(_ field: (Double, Double, Double), marks: [(Double, Double, Double)] = [], share: Double = 0) throws -> CGImage {
        let c = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(srgbRed: field.0, green: field.1, blue: field.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        for (i, m) in marks.enumerated() {
            c.setFillColor(CGColor(srgbRed: m.0, green: m.1, blue: m.2, alpha: 1))
            c.fill(CGRect(x: 0, y: 100 - Double(i + 1) * share * 100, width: 100, height: share * 100))
        }
        return try XCTUnwrap(c.makeImage())
    }

    // STRIP5 (owner, 11-07: "some still don't capture the vibe colour of the album", of a sepia cover with a grey strip):
    // a plain cover keeps its own tint; a vivid accent on a plain field names it; *Blonde* stays silver, a black-and-white
    // cover grey, a black cover with thin colours charcoal.
    func testSTRIP5PlainCoversKeepTheirTint() throws {
        func chroma(_ c: DesktopColors.RGB) -> Double { let (_, a, b) = DesktopColors.oklab(c); return (a * a + b * b).squareRoot() }
        func off(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
        let sepia = (0.66, 0.58, 0.56)
        let s = DesktopColors.stripColour(try plain(sepia))
        XCTAssertGreaterThan(chroma(s), 0.015, "sepia, not grey")
        XCTAssertLessThanOrEqual(off(DesktopColors.perceivedHue(s), DesktopColors.perceivedHue(.init(r: sepia.0, g: sepia.1, b: sepia.2))), 10)
        XCTAssertLessThan(chroma(DesktopColors.stripColour(try plain((0.4, 0.4, 0.4)))), 0.005, "grey stays grey")
        // An orange painting on cream (Getz/Gilberto's way).
        let orange = (0.85, 0.42, 0.12)
        let g = DesktopColors.stripColour(try plain((0.93, 0.9, 0.82), marks: [orange], share: 0.2))
        XCTAssertLessThanOrEqual(off(DesktopColors.perceivedHue(g), DesktopColors.perceivedHue(.init(r: orange.0, g: orange.1, b: orange.2))), 6)
        // *Blonde*: 83% white, the rest skin (saturation ~0.35, skin hues aren't accents).
        let blonde = DesktopColors.stripColour(try plain((0.94, 0.93, 0.92), marks: [(0.62, 0.45, 0.36)], share: 0.17))
        XCTAssertLessThan(chroma(blonde), 0.03, "silver")
        XCTAssertGreaterThan(DesktopColors.oklab(blonde).0, 0.55, "light")
        // Black with a thin rainbow (each colour 1.5%).
        let rainbow = [(0.9, 0.1, 0.1), (0.95, 0.55, 0.1), (0.95, 0.9, 0.1), (0.2, 0.8, 0.2), (0.15, 0.4, 0.9), (0.5, 0.2, 0.8)]
        let dark = DesktopColors.stripColour(try plain((0.03, 0.03, 0.03), marks: rainbow, share: 0.015))
        XCTAssertLessThan(chroma(dark), 0.03, "charcoal")
    }

    // PAL1 (owner, 11-07: moving colours "looked ugly on colorful album"): the strip's colours keep to the album's main
    // colour, its own shades within 45°, never a far hue (a red cover's olive), and a flat cover moves in tones of its
    // one colour (a lighter one, a deeper one).
    func testPAL1ThePaletteKeepsToTheMainColour() throws {
        func off(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
        let red = (0.75, 0.1, 0.1), olive = (0.45, 0.45, 0.12)
        let p = DesktopColors.stripPalette(try plain(red, marks: [olive], share: 0.4))
        XCTAssertEqual(p.count, 3)
        let main = DesktopColors.perceivedHue(p[0])
        XCTAssertLessThanOrEqual(off(main, DesktopColors.perceivedHue(.init(r: red.0, g: red.1, b: red.2))), 4, "red names it")
        for c in p { XCTAssertLessThanOrEqual(off(DesktopColors.perceivedHue(c), main), 45, "no olive") }
        let flat = DesktopColors.stripPalette(try plain((0.1, 0.25, 0.7)))
        for c in flat { XCTAssertLessThanOrEqual(off(DesktopColors.perceivedHue(c), DesktopColors.perceivedHue(flat[0])), 4) }
        XCTAssertGreaterThan(DesktopColors.oklab(flat[1]).0, DesktopColors.oklab(flat[0]).0, "a lighter tone")
        XCTAssertLessThan(DesktopColors.oklab(flat[2]).0, DesktopColors.oklab(flat[0]).0, "a deeper tone")
    }

    // PAL2 (owner, 11-07: "the colors look very muted"): a cover's colour is as saturated as its colourful part, not as
    // its slice's mean (shades of one hue average towards grey): half vivid blue and half greyish blue gives a strip
    // nearly as saturated as the vivid half.
    func testPAL2AsRichAsTheColourfulPart() throws {
        func saturation(_ c: DesktopColors.RGB) -> Double { let (l, a, b) = DesktopColors.oklab(c); return (a * a + b * b).squareRoot() / l }
        let vivid = DesktopColors.RGB(r: 0.1, g: 0.25, b: 0.8)
        let s = DesktopColors.stripColour(try plain((0.3, 0.38, 0.55), marks: [(vivid.r, vivid.g, vivid.b)], share: 0.5))
        XCTAssertGreaterThanOrEqual(saturation(s), saturation(vivid) * 0.85)
        XCTAssertLessThanOrEqual(saturation(s), saturation(vivid) + 0.01, "never richer than the cover")
    }

    // FLOW1: the moving colours are mirrored about the notch (the same on both sides, like the island), loop seamlessly,
    // move slowly (no stop changes by more than 2% a second) and keep the menu bar's white text legible.
    func testFLOW1SlowMirroredLegible() throws {
        func luminance(_ c: DesktopColors.RGB) -> Double {
            0.2126 * DesktopColors.linear(c.r) + 0.7152 * DesktopColors.linear(c.g) + 0.0722 * DesktopColors.linear(c.b)
        }
        let p = DesktopColors.stripPalette(try plain((0.75, 0.1, 0.1), marks: [(0.9, 0.45, 0.1), (0.85, 0.2, 0.45)], share: 0.25))
        let w = 1710.0
        for t in stride(from: 0.0, to: DesktopColors.flowLoop, by: 7) {
            let f = DesktopColors.flow(p, at: t, width: w), next = DesktopColors.flow(p, at: t + 1, width: w)
            for i in f.indices {
                let m = f[f.count - 1 - i]
                XCTAssertEqual(f[i].r, m.r, accuracy: 1e-9); XCTAssertEqual(f[i].b, m.b, accuracy: 1e-9)
                XCTAssertLessThanOrEqual(luminance(f[i]), 0.18 + 1e-6)
                XCTAssertLessThan(max(abs(f[i].r - next[i].r), abs(f[i].g - next[i].g), abs(f[i].b - next[i].b)), 0.02)
            }
        }
        let a = DesktopColors.flow(p, at: 13, width: w), b = DesktopColors.flow(p, at: 13 + DesktopColors.flowLoop, width: w)
        for i in a.indices { XCTAssertEqual(a[i].g, b[i].g, accuracy: 1e-9, "loops seamlessly") }
    }

    // DESK3 (owner, 11-07: "the wallpaper is still not the same as the blurred one from the lock screen … it's already
    // done"): the desktop shows the lock screen's own background, drawn once per song and shared.
    func testDESK3TheDesktopSharesTheLockScreensBackground() async throws {
        let art = try cover((0.1, 0.3, 0.6), patch: (0.9, 0.8, 0.2))
        let size = CGSize(width: 1710, height: 1112)
        let a = SongBackground.image(key: "song", art: art, size: size)
        let b = SongBackground.image(key: "song", art: art, size: size)
        let first = await a.value, second = await b.value
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "drawn once, shared")
        XCTAssertEqual(first?.width, 3420)
        let next = await SongBackground.image(key: "next", art: art, size: size).value
        XCTAssertFalse(next === first, "a new song draws its own")
    }

    // WALL1 (v1, 11-11): losing someone's wallpaper is the worst bug this app could ship. The original is backed up once,
    // byte for byte, a later swap never overwrites it with the art, and putting it back restores it exactly.
    func testWALL1TheOriginalWallpaperComesBackExactly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wall-\(UUID().uuidString)")
        let store = dir.appendingPathComponent("Store/Index.plist"), backup = dir.appendingPathComponent("LN/backup.plist")
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 * 7) })
        try original.write(to: store)
        XCTAssertFalse(LockWallpaper.putBack(backup, to: store), "nothing to put back: the store isn't touched")
        XCTAssertEqual(try Data(contentsOf: store), original)
        XCTAssertTrue(LockWallpaper.backUp(store: store, to: backup))
        try Data("the art".utf8).write(to: store)                    // the swap
        XCTAssertTrue(LockWallpaper.backUp(store: store, to: backup))  // a second swap (the next song)
        XCTAssertEqual(try Data(contentsOf: backup), original, "the backup is still the original, not the art")
        XCTAssertTrue(LockWallpaper.putBack(backup, to: store))
        XCTAssertEqual(try Data(contentsOf: store), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    // LOCK-AVATAR (v1, 11-11): with the lock screen's photo and name showing (macOS's default), the card sits higher, clear
    // of them and still under the clock.
    func testLockCardClearsTheAccountPhoto() {
        let screen = NSRect(x: 0, y: 0, width: 1710, height: 1112)
        let hidden = LockCardController.frame(on: screen, avatarHidden: true)
        let shown = LockCardController.frame(on: screen, avatarHidden: false)
        XCTAssertGreaterThan(shown.minY, hidden.minY + 150, "moved up")
        XCTAssertGreaterThan(screen.maxY - shown.maxY, screen.height * LockWallpaper.clockBottom, "under the clock")
    }
}
