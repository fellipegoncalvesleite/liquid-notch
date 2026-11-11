import AppKit
import CoreImage
import OSLog
import QuartzCore

/// The song's cover on the desktop while it plays (owner, 11-07; `docs/superpowers/specs/2026-11-07-desktop-colors-design.md`).
/// One click-through window per screen just above the wallpaper and under the icons, on every Space. Two parts:
/// - the **menu bar strip** (what shows nearly all the time): deep tones of the cover's main colour moving slowly along
///   the bar (`stripPalette`, `flow`), and a soft light beside the notch on the beat (`beat(_:)`);
/// - **the rest**: the lock screen's background, the cover filling the screen and softly blurred, breathing very slowly.
/// Core Animation runs it in the render server, so the app does nothing per frame; it stops while the song is paused or
/// nothing of the desktop shows. Songs crossfade; when the music goes it fades out and the owner's own wallpaper is there.
///
/// How it got here: a zoomed copy showed only the cover's middle ("why is some just a static colour"); colour pools lost
/// the album ("disconnected from the album identity"); a turning drift was liked but busy on colourful covers ("too much
/// colours … doing random stuff"); with the strip its own thing, the rest became the lock screen's blur ("the wallpaper
/// can be the blurry background like in the lock screen").
@MainActor
final class DesktopColors {
    static let key = "desktopColors"
    /// Off unless Setup's switch is on (owner, 11-07: "keep that in the options, leave the lock screen with the music by
    /// default but for this desktop leave it without this function as default"); the lock screen's art stays on
    /// (`LockWallpaper.autoEnabled`).
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? false }

    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "desktop")

    /// One screen's layers. Only `drift` (the breathing cover) is paused by the clock: under a paused layer a new
    /// animation stays on its first frame, so the paused tone, a beat and the night veil sit outside it (owner, 11-07:
    /// "not getting darker on pause": the 1.2 s fade to the paused tone was added just as the whole stage paused).
    struct Layers {
        let root: CALayer
        let drift: CALayer
        let copies: [CALayer]
        let veil: CAGradientLayer
        /// The menu bar strip's band (`band`), masked to the bar and the fade below it. Inside, bottom to top: `strip`,
        /// `flowFade` › `flowClock` › `flow`, `glow`, `dim`.
        let band: CALayer
        /// The strip's still tone: what shows while paused (the colours fade out over it).
        let strip: CAGradientLayer
        /// The album's colours moving along the strip while it plays (`flow(_:at:width:stops:)`); `flowFade` shows or
        /// hides them, `flowClock` stops their clock (like `drift`).
        let flowFade: CALayer
        let flowClock: CALayer
        let flow: CAGradientLayer
        /// A soft light beside the notch, shown for a moment on a beat (`beat(_:)`).
        let glow: CAGradientLayer
        /// Black over the whole band at night (`nightDim`).
        let dim: CALayer
    }

    private struct Stage {
        let window: NSWindow
        let layers: Layers
        var copies: [CALayer] { layers.copies }
        var veil: CAGradientLayer { layers.veil }
        var strip: CAGradientLayer { layers.strip }
        var glow: CAGradientLayer { layers.glow }
    }

    private var stages: [Stage] = []
    private var shown = false
    private var key: String?
    /// The cover blurred, and the strip's colour.
    private var images: Images?
    private var rendering: String?
    private var playing = false
    /// Whether a song is on (before Setup's switch is asked).
    private var songOn = false
    private var observers: [NSObjectProtocol] = []
    /// Checks the hour now and then while the colours show (the night veil).
    private var nightCheck: Timer?
    /// How strongly the strip may pulse right now (`pulseScale`, with the live context).
    var pulseScale: (() -> Double)?
    /// A fullscreen window is in front (owner, 11-07: "shouldn't be there when I'm in full screen for like a movie"):
    /// the strip fades out, its colours stop and no beat lights it. A fullscreen Space never shows this window anyway;
    /// this covers a video filling the screen in its own Space. The wallpaper part stays as it is.
    private var fullscreen = false

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        // A Space change: the strip's on it or not (`stripSeen`).
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        })
        // Setup's switch takes effect at once.
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shown != (self.songOn && Self.enabled) else { return }
                self.shown.toggle()
                if self.shown { self.show() } else { self.hide() }
            }
        })
    }

    /// Every island change: whether a song is on (and the switch is), which, its cover, whether it plays, and whether a
    /// fullscreen window is in front.
    func update(on: Bool, key: String, art: NSImage?, playing: Bool, fullscreen: Bool = false) {
        if self.fullscreen != fullscreen {
            self.fullscreen = fullscreen
            Self.log.notice("desktop strip \(fullscreen ? "hidden (fullscreen)" : "back", privacy: .public)")
            CATransaction.begin()
            CATransaction.setAnimationDuration(fullscreen ? 0.3 : 1.2)
            for stage in stages { stage.layers.band.opacity = fullscreen ? 0 : 1 }
            CATransaction.commit()
            if fullscreen { glowOff() }
            updateClock()
        }
        songOn = on
        // A new song: its own beat.
        if key != beatKey { beatKey = key; glowOff() }
        let on = on && Self.enabled
        if key != self.key, let cg = art?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            render(key: key, cg)
        }
        if self.playing != playing {
            self.playing = playing
            if !playing { glowOff() }
            updateClock()
            // Paused, the colours stop and fade out over a muted, darker still tone; playing, they come back.
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.2)
            for stage in stages {
                paintStrips(stage, night: Self.isNight())
                showFlow(stage)
            }
            CATransaction.commit()
        }
        guard on != shown else { return }
        Self.log.notice("desktop colours \(on ? "show" : "hide", privacy: .public) (song on \(self.songOn), switch \(Self.enabled), playing \(playing), song \(key, privacy: .public))")
        shown = on
        if on { show() } else { hide() }
    }

    // MARK: - The colours

    /// The song's background is the lock screen's own (`SongBackground`: drawn once, for the built-in screen, and
    /// shared; owner, 11-07: "the wallpaper is still not the same as the blurred one from the lock screen"); the strip's
    /// colour is worked out here.
    private func render(key: String, _ cg: CGImage) {
        guard rendering != key else { return }
        rendering = key
        let box = Box(cg)
        let size = (NotchGeometry.current()?.0 ?? NSScreen.main)?.frame.size ?? CGSize(width: 1710, height: 1112)
        let back = SongBackground.image(key: key, art: cg, size: size)
        Task.detached(priority: .utility) {
            let palette = Self.stripPalette(box.image)
            let cover = await back.value
            await MainActor.run {
                guard self.rendering == key else { return }
                self.rendering = nil
                self.key = key
                let images = Images(cover: cover, palette: palette)
                self.images = images
                self.setContents(images, fade: self.shown)
            }
        }
    }

    /// The song's background (the lock screen's, 2× the built-in screen) and the strip's colours (`stripPalette`).
    struct Images: @unchecked Sendable {
        let cover: CGImage?
        let palette: [RGB]
        var strip: RGB { palette[0] }
    }

    struct RGB: Sendable, Equatable {
        var r, g, b: Double
        var cg: CGColor { CGColor(srgbRed: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1), alpha: 1) }
    }

    /// The menu bar strip's colour (owner, 11-07, passing on another review: "the strip is what I'll see 95% of the
    /// time"; in a thin strip a red on one side and an olive on the other look random): **the colour a person would name
    /// for the album, made deep** (owner, 11-07: "some still don't capture the vibe colour of the album").
    /// - A coloured cover: its main colour, the one covering the most of its coloured area (12 slices of 30°, dark pixels
    ///   counted, a little more for saturation, smoothed with the neighbours; 10° slices split a forest's greens thin and
    ///   its yellow ground won), the mean of the pixels within 25° of that slice. Averaging the whole cover came out muddy,
    ///   and the most colourful patch over the biggest one went wrong too (*Grace*'s magenta face beat its blue).
    /// - A cover that's mostly plain (over 60% white, grey, black or barely tinted): a vivid accent that names it, if
    ///   there is one (saturation 0.45 and up, not dark, not skin, at least 6% of the cover: an orange painting on cream);
    ///   otherwise the field's own tint, as light as the cover (charcoal to silver): a sepia stays sepia, a warm black warm,
    ///   *Blonde* (83% white) silver ("I think Blonde would be white"). It was plain grey, which washed out sepia covers.
    ///
    /// No invented colour (owner, 11-07, of a mustard cover with a green strip: "is he taking from default colors instead
    /// of the album? stop that right now"): a fixed HSB tone and a yellow-green-to-green remap turned mustard green and deep
    /// blues purple ("it's turning blue albums purple???").
    nonisolated static func stripColour(_ cg: CGImage) -> RGB { stripPalette(cg)[0] }

    /// The strip's colours: the main colour (`stripColour`) first, then two companions that keep to it, for the colours
    /// moving along the strip (owner, 11-07, of the strip as one flat colour: "the colors look very muted and ugly …
    /// before it was moving colors, not one static, I feel like it might be better, but it looked ugly on colorful
    /// album"). The companions are the cover's own shades 12–45° either side of the main colour (OKLab hue: a red
    /// cover's oranges and pinks), made deep the same way; where the cover has none, a lighter and a deeper tone of the
    /// main colour. Never a far hue: a red beside an olive is what looked random on colourful covers.
    nonisolated static func stripPalette(_ cg: CGImage) -> [RGB] {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        let fallback = RGB(r: 0.2, g: 0.2, b: 0.21)
        guard drawn else { return [fallback, tone(fallback, by: 0.035), tone(fallback, by: -0.03)] }
        var coloured = [Pixel](), vivid = [Pixel]()
        var neutrals = 0, neutralLight = 0.0
        var all = (r: 0.0, g: 0.0, b: 0.0)   // in linear light
        for i in 0..<(n * n) {
            let c = RGB(r: Double(px[i * 4]) / 255, g: Double(px[i * 4 + 1]) / 255, b: Double(px[i * 4 + 2]) / 255)
            all = (all.r + linear(c.r), all.g + linear(c.g), all.b + linear(c.b))
            var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
            guard sat > 0.18, v > 0.06 else { neutrals += 1; neutralLight += Double(v); continue }   // dark greens count
            let p = Pixel(h: Double(h), w: 1 + 0.5 * Double(sat), c: c)
            coloured.append(p)
            let degrees = Double(h) * 360
            let skin = degrees >= 5 && degrees <= 45 && sat < 0.7
            if sat >= 0.45 && v >= 0.25 && !skin { vivid.append(p) }
        }
        let count = Double(n * n)
        if Double(neutrals) > count * 0.6 || coloured.isEmpty {
            if let accent = main(of: vivid), Double(accent.pixels) >= count * 0.06 {
                let m = deep(accent.colour, saturation: accent.saturation)
                return [m] + companions(of: accent, in: vivid, main: m)
            }
            let grey = 0.16 + 0.32 * neutralLight / Double(max(neutrals, 1))
            let t = tinted(RGB(r: encoded(all.r / count), g: encoded(all.g / count), b: encoded(all.b / count)), as: grey)
            return [t, tone(t, by: 0.035), tone(t, by: -0.03)]
        }
        guard let m = main(of: coloured) else { return [fallback, tone(fallback, by: 0.035), tone(fallback, by: -0.03)] }
        let c = deep(m.colour, saturation: m.saturation)
        return [c] + companions(of: m, in: coloured, main: c)
    }

    struct Pixel {
        let h: Double, w: Double, c: RGB
    }

    /// A cover's main colour (`main(of:)`): the mean of its slice in linear light, how many pixels that is, their
    /// weight, the mean's hue as the eye sees it (degrees) and how saturated the slice's vivid part is (`vivid`).
    struct Cluster {
        let colour: RGB, pixels: Int, weight: Double, hue: Double, saturation: Double
    }

    /// The main colour among `pixels`: the 30° slice (smoothed with its neighbours) holding the most of them, and the
    /// mean (in linear light) of those within 25° of it, with how many those are.
    nonisolated static func main(of pixels: [Pixel]) -> Cluster? {
        guard !pixels.isEmpty else { return nil }
        var bins = [Double](repeating: 0, count: 12)
        for p in pixels { bins[Int(p.h * 12) % 12] += p.w }
        let smoothed = (0..<12).map { bins[($0 + 11) % 12] * 0.4 + bins[$0] + bins[($0 + 1) % 12] * 0.4 }
        let peak = smoothed.indices.max { smoothed[$0] < smoothed[$1] }!
        let centre = (Double(peak) + 0.5) / 12
        let inside = pixels.filter { var d = abs($0.h - centre); d = min(d, 1 - d); return d <= 25.0 / 360 }
        return cluster(inside)
    }

    /// The mean (in linear light) of `pixels`, weighted, with its count, weight, hue and vivid saturation.
    nonisolated static func cluster(_ pixels: [Pixel]) -> Cluster? {
        var mean = (r: 0.0, g: 0.0, b: 0.0), total = 0.0
        for p in pixels {
            mean = (mean.r + linear(p.c.r) * p.w, mean.g + linear(p.c.g) * p.w, mean.b + linear(p.c.b) * p.w)
            total += p.w
        }
        guard total > 0 else { return nil }
        let colour = RGB(r: encoded(mean.r / total), g: encoded(mean.g / total), b: encoded(mean.b / total))
        return Cluster(colour: colour, pixels: pixels.count, weight: total, hue: perceivedHue(colour), saturation: vivid(pixels))
    }

    /// How saturated the colour of `pixels` looks where it shows (owner, 11-07: "the colors look very muted"): the 70th
    /// percentile of their OKLab saturation (chroma over lightness), very dark pixels left out. A slice's mean in linear
    /// light is greyer than any of its pixels (shades of a hue average towards grey), so it can't be the measure: a
    /// person naming a cover's colour names its colourful part. A flat cover's is its own.
    nonisolated static func vivid(_ pixels: [Pixel]) -> Double {
        let s = pixels.compactMap { p -> Double? in
            let (l, a, b) = oklab(p.c)
            return l < 0.2 ? nil : (a * a + b * b).squareRoot() / l
        }.sorted()
        return s.isEmpty ? 0 : s[min(Int(Double(s.count) * 0.7), s.count - 1)]
    }

    /// The main colour's two companions (`stripPalette`): the cover's pixels 12–45° to either side of the main colour's
    /// hue (OKLab), each side's mean made deep when it holds at least 12% of the main slice's weight; a side without one
    /// gives a tone of the main colour instead, the first lighter, the second deeper.
    nonisolated static func companions(of m: Cluster, in pixels: [Pixel], main: RGB) -> [RGB] {
        var found = [RGB]()
        for side in [-1.0, 1.0] {
            let near = pixels.filter { p in
                var d = (perceivedHue(p.c) - m.hue) * side
                d = (d + 540).truncatingRemainder(dividingBy: 360) - 180
                return d > 12 && d <= 45
            }
            if let c = cluster(near), c.weight >= m.weight * 0.12 { found.append(deep(c.colour, saturation: c.saturation)) }
        }
        let tones = [tone(main, by: 0.05), tone(main, by: -0.045)]
        return (found + tones).prefix(2).map { $0 }
    }

    /// The depth of the strip's colours: OKLab lightness 0.33–0.39.
    nonisolated static let depth = 0.33...0.39

    /// `c` made a deep tone for the strip: in OKLab, its lightness brought into `depth` (lighter covers darkened, darker
    /// ones lifted, so every cover gets about the same depth and a dark one doesn't go black: the Jobim cover's warm
    /// browns came out near black), as saturated as the cover's colourful part (`saturation`, chroma over lightness: the
    /// slice's vivid part, never more than the cover's own) and its hue kept; brought into sRGB by taking chroma away,
    /// never by turning the hue. White menu text reads on it (`legible` holds it there when the strip is lit).
    nonisolated static func deep(_ c: RGB, saturation: Double = 0) -> RGB {
        let (l, a, b) = oklab(c)
        let chroma = (a * a + b * b).squareRoot()
        let target = min(max(l, depth.lowerBound), depth.upperBound)
        return inGamut(target, max(chroma / max(l, 0.001), saturation) * target, atan2(b, a))
    }

    /// `c` lighter (`by` > 0) or deeper in OKLab lightness, as saturated as it was, its hue kept.
    nonisolated static func tone(_ c: RGB, by dl: Double) -> RGB {
        let (l, a, b) = oklab(c)
        let target = max(l + dl, 0.05)
        return inGamut(target, (a * a + b * b).squareRoot() * target / max(l, 0.001), atan2(b, a))
    }

    /// A plain cover's tone: as light as the grey `grey` (sRGB), with `field`'s own tint (its chroma and hue, never more
    /// than 0.06 chroma: still a neutral, just not a dead grey).
    nonisolated static func tinted(_ field: RGB, as grey: Double) -> RGB {
        let (_, a, b) = oklab(field)
        let (l, _, _) = oklab(RGB(r: grey, g: grey, b: grey))
        return inGamut(l, min((a * a + b * b).squareRoot(), 0.06), atan2(b, a))
    }

    /// The colour of lightness `l`, chroma `chroma` and hue `hue` (OKLab), its chroma reduced until it's in sRGB.
    nonisolated static func inGamut(_ l: Double, _ chroma: Double, _ hue: Double) -> RGB {
        var k = chroma
        var out = rgb(fromOklab: l, k * cos(hue), k * sin(hue))
        while k > 0.001 && [out.r, out.g, out.b].contains(where: { $0 < 0 || $0 > 1 }) {
            k *= 0.97
            out = rgb(fromOklab: l, k * cos(hue), k * sin(hue))
        }
        return RGB(r: min(max(out.r, 0), 1), g: min(max(out.g, 0), 1), b: min(max(out.b, 0), 1))
    }

    nonisolated static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    nonisolated static func encoded(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// An sRGB colour in OKLab (L, a, b).
    nonisolated static func oklab(_ c: RGB) -> (Double, Double, Double) {
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab back to sRGB (may fall outside 0…1).
    nonisolated static func rgb(fromOklab l: Double, _ a: Double, _ b: Double) -> RGB {
        let l3 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m3 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s3 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func enc(_ v: Double) -> Double { v < 0 ? -encoded(-v) : v > 1 ? 1 + (v - 1) : encoded(v) }
        return RGB(r: enc(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
                   g: enc(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
                   b: enc(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))
    }

    /// A colour's hue as the eye sees it (OKLab), in degrees.
    nonisolated static func perceivedHue(_ c: RGB) -> Double {
        let (_, a, b) = oklab(c)
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    private func setContents(_ images: Images?, fade: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(fade ? 1.5 : 0)
        CATransaction.setDisableActions(!fade)
        for stage in stages {
            // A paused drift would hold the crossfade on its first frame (the old cover): there it changes at once.
            CATransaction.begin()
            if stage.layers.drift.speed == 0 { CATransaction.setDisableActions(true) }
            for copy in stage.copies { copy.contents = images?.cover }
            CATransaction.commit()
            paintStrips(stage, night: Self.isNight())
            setFlow(stage, fade: fade)
        }
        CATransaction.commit()
    }

    // MARK: - The windows

    private func show() {
        if stages.isEmpty { rebuild() }
        updateNight()
        nightCheck?.invalidate()
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateNight() } }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        nightCheck = t
        for stage in stages {
            stage.window.alphaValue = 0
            stage.window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 1.2; stage.window.animator().alphaValue = 1 }
        }
        updateClock()
    }

    private func hide() {
        glowOff()
        nightCheck?.invalidate()
        nightCheck = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 1.5
            for stage in stages { stage.window.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard !self.shown else { return }
                for stage in self.stages { stage.window.orderOut(nil) }
                self.updateClock()
            }
        })
    }

    /// One stage per screen (again when screens change).
    private func rebuild() {
        for stage in stages { stage.window.orderOut(nil) }
        stages = NSScreen.screens.map(makeStage)
        for stage in stages { stage.layers.band.opacity = fullscreen ? 0 : 1 }
        setContents(images, fade: false)
        if shown { for stage in stages { stage.window.alphaValue = 1; stage.window.orderFrontRegardless() } }
        updateClock()
    }

    /// The lock screen's background for a screen of `size` (owner, 11-07: "the wallpaper can be the blurry background
    /// like in the lock screen", then "it's still not the same … it's already done": it's the lock screen's own image,
    /// `SongBackground`), breathing very slowly (6% in and out over 40 s) so it's never quite still. (Before it, the
    /// drift: the cover turning round with two faint copies over it; then a blur of its own, sharper and more saturated.)
    private static func copies(in size: CGSize) -> [CALayer] {
        let l = CALayer()
        l.bounds = CGRect(origin: .zero, size: size)
        l.position = CGPoint(x: size.width / 2, y: size.height / 2)
        l.contentsGravity = .resizeAspectFill
        l.magnificationFilter = .linear
        l.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull()]
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1
        breathe.toValue = 1.06
        breathe.duration = 40
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
        l.add(breathe, forKey: "breathe")
        return [l]
    }

    /// A veil, darker at the top where the eye rests by the menu bar and darker still at night (owner, 11-07: "I'd dim
    /// it a little at the top so it doesn't give me eye strain, especially at night"); it keeps the icons legible too.
    /// The lock screen's image already has its 22% black, so the veil adds to it only up top: 50% dark in all at the top
    /// and 30% at 40% down, as before; nothing at the bottom, where it's the lock screen's exactly.
    private static func veil(_ size: CGSize, night: Bool) -> CAGradientLayer {
        let veil = CAGradientLayer()
        veil.frame = CGRect(origin: .zero, size: size)
        veil.startPoint = CGPoint(x: 0.5, y: 1)   // the top (layers aren't flipped)
        veil.endPoint = CGPoint(x: 0.5, y: 0)
        veil.locations = [0, 0.4, 1]
        paint(veil, night: night)
        return veil
    }

    private static func paint(_ veil: CAGradientLayer, night: Bool) {
        let extra = night ? 0.18 : 0
        veil.colors = [0.36 + extra, 0.1 + extra, extra].map { NSColor.black.withAlphaComponent($0).cgColor }
    }

    /// Night: from 8 pm to 7 am.
    nonisolated static func isNight(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 20 || hour < 7
    }

    private func updateNight() {
        let night = Self.isNight()
        CATransaction.begin()
        CATransaction.setAnimationDuration(3)
        for stage in stages {
            Self.paint(stage.veil, night: night)
            paintStrips(stage, night: night)
        }
        CATransaction.commit()
    }

    /// The menu bar strip, designed on its own (the strip is what shows behind the menu bar nearly all the time): the
    /// cover's deep tone, a shade lighter behind the notch (`across`), the same on both sides, so the black notch stands
    /// out against it (owner, 11-07: black fading in around the notch "looks dirty, the notch is supposed to be
    /// distinct"; one flat colour "a bit muted and ugly"), the album's colours moving along it while it plays (`flow`),
    /// then fading into the album's blur below over 90 pt. A lit version (45% lighter behind the notch, and lighter along
    /// the bar's top edge like light on glass) "looks artificial" (owner, 11-07): the strip should look like the cover's
    /// colour, not an effect.
    ///
    /// The strip's band: the bar's height and the 90 pt fade below it, masked (the mask flattens what's inside, so its
    /// layers are opaque and the band as a whole lets the album's blur through a little: 94%; it was 85%, which let the
    /// blur's other colours muddy the strip).
    private static func band(_ size: CGSize, bar: Double) -> CALayer {
        let fade = 90.0, height = bar + fade
        let band = CALayer()
        band.frame = CGRect(x: 0, y: size.height - height, width: size.width, height: height)
        let mask = CAGradientLayer()
        mask.frame = band.bounds
        mask.startPoint = CGPoint(x: 0.5, y: 1)   // the top (layers aren't flipped)
        mask.endPoint = CGPoint(x: 0.5, y: 0)
        let top = NSColor.white.withAlphaComponent(0.94).cgColor
        mask.colors = [top, top, NSColor.clear.cgColor]
        mask.locations = [0, NSNumber(value: bar / height), 1]
        band.mask = mask
        return band
    }

    /// A gradient across `frame`'s width, `count` evenly spaced stops.
    private static func across(_ frame: CGRect, stops count: Int) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.frame = frame
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.locations = (0..<count).map { NSNumber(value: Double($0) / Double(count - 1)) }
        g.colors = Array(repeating: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), count: count)
        return g
    }

    /// The strip's colour stops across the screen.
    private static let stops = 9
    /// The moving colours' stops (finer: their pools are ~200 pt wide).
    nonisolated static let flowStops = 17
    /// The glow's stops.
    nonisolated static let glowStops = 33

    /// The album's colours along the strip at `t` seconds (owner, 11-07: "before it was moving colors, not one static,
    /// I feel like it might be better, but it looked ugly on colorful album"): the main colour everywhere, and on each
    /// side of the notch two soft pools of the companions (`stripPalette`), the first swaying around a third of the way
    /// out over 60 s, the second around three quarters over 90 s, mirrored about the notch (the same on both sides, like
    /// the island). They mix in OKLab, so a pool passing over the main colour never goes through grey. At most ~16 pt a
    /// second: slow enough to read as the album's light, not as movement. Shaded like the still tone (`across`), held
    /// legible for the menu bar's text.
    nonisolated static func flow(_ palette: [RGB], at t: Double, width: Double, stops count: Int = flowStops) -> [RGB] {
        let main = oklab(palette[0]), one = oklab(palette[1 % palette.count]), two = oklab(palette[2 % palette.count])
        let half = width / 2
        let u1 = half * (0.3 + 0.17 * sin(2 * .pi * t / 60))
        let u2 = half * (0.74 + 0.2 * sin(2 * .pi * t / 90 + 2.1))
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ k: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k, a.2 + (b.2 - a.2) * k)
        }
        return (0..<count).map { i in
            let x = width * Double(i) / Double(count - 1), u = abs(x - half)
            var c = mix(main, one, 0.85 * exp(-pow((u - u1) / (half * 0.22), 2)))
            c = mix(c, two, 0.85 * exp(-pow((u - u2) / (half * 0.26), 2)))
            let m = across(x, width: width), o = rgb(fromOklab: c.0, c.1, c.2)
            return legible(RGB(r: min(max(o.r, 0), 1) * m, g: min(max(o.g, 0), 1) * m, b: min(max(o.b, 0), 1) * m))
        }
    }

    /// The flow's loop: 180 s (both pools' periods fit), a keyframe every 3 s (a pool moves under 50 pt between two).
    nonisolated static let flowLoop = 180.0
    nonisolated static let flowStep = 3.0

    private static func flowAnimation(_ palette: [RGB], width: Double) -> CAKeyframeAnimation {
        let frames = Int(flowLoop / flowStep)
        let a = CAKeyframeAnimation(keyPath: "colors")
        a.values = (0...frames).map { f in
            flow(palette, at: Double(f % frames) * flowStep, width: width).map(\.cg)
        }
        a.calculationMode = .linear
        a.duration = flowLoop
        a.repeatCount = .infinity
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
        return a
    }

    /// The glow's colour: the main colour 0.14 lighter in OKLab, as saturated (light, not another hue; owner: "just
    /// brightness, not hue").
    nonisolated static func glowColour(_ main: RGB) -> RGB { legible(tone(main, by: glowRise)) }
    nonisolated static let glowRise = 0.14

    /// How much of the glow shows at `x` on a screen `width` points wide: all of it beside the notch's 208 pt and under
    /// it, falling off over ~180 pt (a Gaussian), so it reads as light from the island, where the bars are (Siri's edge
    /// light rises from where it's called the same way), never as the whole bar flashing.
    nonisolated static func glowShape(_ x: Double, width: Double) -> Double {
        let d = max(abs(x - width / 2) - 104, 0) / 180
        return exp(-d * d)
    }

    /// The strip's shade at `x` on a screen `width` points wide: 8% lighter right beside the notch, fading out ~380 pt
    /// either side of its 208 pt, and 6% deeper at the screen's edges.
    nonisolated static func across(_ x: Double, width: Double) -> Double {
        let u = x / width, beside = max(abs(x - width / 2) - 104, 0)
        let behind = exp(-(beside / 380) * (beside / 380))
        return (0.94 + 0.04 * (1 - abs(u - 0.5) * 2)) * (1 + 0.08 * behind)
    }

    /// `c` darkened, its hue kept, until white text on it keeps 4.5:1 (relative luminance `limit`): the menu bar's text
    /// stays readable where the light falls on a light tone (a white cover's silver).
    nonisolated static func legible(_ c: RGB, limit: Double = 0.18) -> RGB {
        func luminance(_ c: RGB) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        guard luminance(c) > limit else { return c }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let k = (low + high) / 2
            if luminance(RGB(r: c.r * k, g: c.g * k, b: c.b * k)) > limit { high = k } else { low = k }
        }
        return RGB(r: c.r * low, g: c.g * low, b: c.b * low)
    }

    /// The still tone, shaded across the bar (`across`). Paused, it's muted: halfway to its own grey and a little darker.
    /// (Night is `dim`, over the whole band.)
    private static func paintStrip(_ band: CAGradientLayer, _ c: RGB?, paused: Bool = false) {
        let k = paused ? 0.85 : 1
        let width = Double(band.bounds.width)
        guard var c else { band.colors = Array(repeating: RGB(r: 0, g: 0, b: 0).cg, count: stops); return }
        if paused {
            let grey = (c.r + c.g + c.b) / 3
            c = RGB(r: (c.r + grey) / 2, g: (c.g + grey) / 2, b: (c.b + grey) / 2)
        }
        band.colors = (0..<stops).map { i in
            let m = k * across(width * Double(i) / Double(stops - 1), width: width)
            return legible(RGB(r: c.r * m, g: c.g * m, b: c.b * m)).cg
        }
    }

    /// The glow's light, its alpha shaped by `glowShape`.
    private static func paintGlow(_ glow: CAGradientLayer, _ c: RGB?) {
        let width = Double(glow.bounds.width)
        let lit = glowColour(c ?? RGB(r: 0, g: 0, b: 0)).cg
        glow.colors = (0..<glowStops).map { i in
            lit.copy(alpha: glowShape(width * Double(i) / Double(glowStops - 1), width: width)) ?? lit
        }
    }

    /// Night: the whole band 25% darker (the still tone, the colours and the glow alike).
    nonisolated static func nightDim(_ night: Bool) -> Float { night ? 0.25 : 0 }

    private func paintStrips(_ stage: Stage, night: Bool) {
        Self.paintStrip(stage.strip, images?.strip, paused: !playing)
        Self.paintGlow(stage.glow, images?.strip)
        stage.layers.dim.opacity = Self.nightDim(night)
    }

    /// The colours show only while the song plays; paused, they fade out over the muted still tone.
    private func showFlow(_ stage: Stage) {
        stage.layers.flowFade.opacity = playing && images != nil ? 1 : 0
    }

    /// The song's colours into the flow (`flowAnimation`). With `fade`, the old ones fade out over the still tone (which
    /// crossfades to the new song's), the new ones go in and fade in.
    private func setFlow(_ stage: Stage, fade: Bool) {
        let fadeIn = stage.layers.flowFade
        let install = { [weak self] in
            guard let self else { return }
            let flow = stage.layers.flow
            flow.removeAnimation(forKey: "flow")
            guard let palette = self.images?.palette else { return }
            let width = Double(flow.bounds.width)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            flow.colors = Self.flow(palette, at: 0, width: width).map(\.cg)
            CATransaction.commit()
            flow.add(Self.flowAnimation(palette, width: width), forKey: "flow")
        }
        guard fade, fadeIn.opacity > 0 else {
            install()
            showFlow(stage)
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.7)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                install()
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.8)
                self.showFlow(stage)
                CATransaction.commit()
            }
        }
        fadeIn.opacity = 0
        CATransaction.commit()
    }

    // MARK: - The beat

    /// How strongly the strip pulses now (owner, 11-07: "can't it pulse and not bug me? the strip? because desktop
    /// beating makes no sense"): wherever you are, while music plays, so gently it never distracts; held during a Focus
    /// and while presenting; half as strong while you type (a key in the last 20 s). It used to pulse only with the
    /// player or Finder in front and no key in 20 s, which held it nearly always ("I don't see the beats").
    nonisolated static func pulseScale(focusOn: Bool?, secondsSinceKey: Double, presenting: Bool) -> Double {
        guard focusOn != true, !presenting else { return 0 }
        return secondsSinceKey > 20 ? 1 : 0.6
    }

    /// The colours show a playing song: the bars listen for the strip's beats (wherever the song is on the island).
    var wantsBeats: Bool { shown && playing }

    /// The glow's opacity on a beat: 0.55, a little less while the grid is less sure (`BeatTracker.confidence`), 65% of
    /// that at night.
    nonisolated static func glowPeak(night: Bool) -> Double { 0.55 * (night ? 0.65 : 1) }

    /// How much lighter the strip gets right beside the notch at a beat's peak of `strength` (0…1), in OKLab lightness
    /// (owner, 11-07, of the first version: "i asked it to make faint glows under beats following the bars that wont bug
    /// or distract me to appear, nothing"): up to about 0.08 by day (a soft light you notice from the corner of your eye),
    /// falling off within ~180 pt (`glowShape`), nothing at the screen's edges. It was the whole strip +5% to +8% in
    /// brightness, about 0.015 in lightness: under what the eye notices off to the side.
    nonisolated static func beatLift(strength: Double, night: Bool) -> Double {
        glowRise * glowPeak(night: night) * min(max(strength, 0), 1)
    }

    /// The song's beat (`BeatTracker`), fed every analysis frame's onset, and the song it's for.
    private var tracker: BeatTracker?
    private var beatKey: String?
    /// The last beat already given a glow (the tracker's clock), and how many glows were scheduled.
    private var scheduledUpTo = -Double.infinity
    private var glows = 0
    /// The output's latency (`OutputLatency`), read now and then: a beat is lit when it's heard, not when it's sent.
    private var latency = (value: 0.0, readAt: -Double.infinity)
    /// The log's summary (`logBeats`).
    private var beatLog = (at: 0.0, frames: 0, locked: 0, glows: 0)

    /// One analysis frame (owner, 11-07: "its just not recognizing beats properly … try being smart about it"): its
    /// onset strength at `t` (`CACurrentMediaTime`), `rate` frames a second. The tracker finds the song's beat grid and
    /// predicts it; each predicted beat gets a glow scheduled in the render server for the moment it's heard (the
    /// output's latency added: AirPods play ~0.17 s after the Mac sends the sound), so it lands on the beat, quiet beats
    /// too, and nothing lights while the tracker isn't sure (a beatless piece, a break). The tracker always listens
    /// while the colours show a playing song, so the grid is ready when the glow may show again.
    func audioFrame(onset: Double, at t: Double, rate: Double) {
        guard shown && playing else { return }
        if tracker?.rate != rate { tracker = BeatTracker(rate: rate); scheduledUpTo = -.infinity }
        tracker!.feed(onset, at: t)
        logBeats(at: t)
        let scale = fullscreen ? 0 : pulseScale?() ?? 0
        guard scale > 0, let tracker, tracker.locked, let period = tracker.pulsePeriod else { return }
        if t - latency.readAt > 5 { latency = (OutputLatency.seconds(), t) }
        let now = CACurrentMediaTime()
        let due = Self.dueBeats(tracker, after: scheduledUpTo, now: now, latency: latency.value)
        guard let last = due.last else { return }
        scheduledUpTo = last
        let peak = Self.glowPeak(night: Self.isNight()) * scale * (0.7 + 0.3 * tracker.confidence)
        for beat in due {
            for stage in stages where stripSeen(stage) {
                Self.pulse(stage.glow, at: beat + latency.value, peak: Float(peak), period: period, n: glows)
            }
            glows += 1
        }
    }

    /// The beats to light now (the tracker's clock): those heard within the next 0.15 s that weren't lit yet (after
    /// `after`, the last one given a glow), never one already past, at most three. It always starts from now: starting
    /// from the last lit beat, `-infinity` before the first, asked the tracker for a beat after `-infinity` and got
    /// `-infinity` back forever (the main thread hung at 100% once a song's beat locked, 11-07).
    nonisolated static func dueBeats(_ tracker: BeatTracker, after: Double, now: Double, latency: Double) -> [Double] {
        guard let period = tracker.pulsePeriod, period > 0 else { return [] }
        var from = max(after.isFinite ? after + period * 0.5 : -Double.infinity, now - latency - 0.02)
        var due: [Double] = []
        while due.count < 3, let beat = tracker.nextPulse(after: from), beat.isFinite, beat > from,
              beat + latency - now < 0.15 {
            due.append(beat)
            from = beat + period * 0.5
        }
        return due
    }

    /// A glow on `layer` at `time` (`CACurrentMediaTime`): up in 50 ms, down over the rest of ~0.5 s (shorter between
    /// close beats), added to whatever the last one left (each its own animation, so a beat never cuts the one before).
    private static func pulse(_ layer: CALayer, at time: Double, peak: Float, period: Double, n: Int) {
        let duration = min(0.5, period * 0.8)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, peak, 0]
        a.keyTimes = [0, NSNumber(value: 0.05 / duration), 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)]
        a.duration = duration
        a.isAdditive = true
        a.beginTime = layer.convertTime(time, from: nil)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = true
        layer.add(a, forKey: "beat\(n % 8)")
    }

    /// The glow off (paused, hidden, fullscreen, a new song): what's scheduled goes, and the tracker starts afresh.
    private func glowOff() {
        tracker = nil
        scheduledUpTo = -.infinity
        for stage in stages { stage.glow.removeAllAnimations() }
    }

    /// The beat in the log (category `desktop`), a line every 30 s while a song plays: its tempo, how much of the time the
    /// glow followed it, how many glows.
    private func logBeats(at t: Double) {
        beatLog.frames += 1
        if tracker?.locked == true { beatLog.locked += 1 }
        guard t - beatLog.at >= 30 else { return }
        if beatLog.at > 0, let tracker {
            Self.log.notice("desktop beat: \(tracker.bpm.map { String(format: "%.1f", $0) } ?? "-", privacy: .public) BPM, locked \(100 * self.beatLog.locked / max(self.beatLog.frames, 1))% of 30 s, \(self.glows - self.beatLog.glows) glows, salience \(String(format: "%.1f", tracker.salience), privacy: .public)")
        }
        beatLog = (t, 0, 0, glows)
    }

    /// The menu bar's height on `screen`: the notch's on a notched screen.
    private static func menuBar(_ screen: NSScreen) -> Double {
        max(Double(screen.safeAreaInsets.top), Double(NSStatusBar.system.thickness))
    }

    private func makeStage(on screen: NSScreen) -> Stage {
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        // Just above the wallpaper, under the desktop's icons and every window; on every Space, never in fullscreen ones.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.setFrame(screen.frame, display: false)

        let size = screen.frame.size
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        let layers = Self.layers(size: size, bar: Self.menuBar(screen))
        view.layer = layers.root
        view.wantsLayer = true
        w.contentView = view

        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        })
        return Stage(window: w, layers: layers)
    }

    /// The layers for a screen of `size` with a menu bar `bar` points high: on black, the drift (the breathing cover),
    /// then the veil and the strip's band: its still tone, the moving colours, the glow (hidden until a beat) and the
    /// night's dim.
    static func layers(size: CGSize, bar: Double, night: Bool = isNight()) -> Layers {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor.black.cgColor
        let drift = CALayer()
        drift.frame = root.bounds
        root.addSublayer(drift)
        let copies = Self.copies(in: size)
        for l in copies { drift.addSublayer(l) }
        let veil = Self.veil(size, night: night)
        root.addSublayer(veil)
        let band = Self.band(size, bar: bar)
        root.addSublayer(band)
        let strip = Self.across(band.bounds, stops: stops)
        band.addSublayer(strip)
        let flowFade = CALayer(), flowClock = CALayer()
        for l in [flowFade, flowClock] { l.frame = band.bounds }
        flowFade.opacity = 0
        band.addSublayer(flowFade)
        flowFade.addSublayer(flowClock)
        let flow = Self.across(band.bounds, stops: flowStops)
        flowClock.addSublayer(flow)
        let glow = Self.across(band.bounds, stops: glowStops)
        glow.opacity = 0
        band.addSublayer(glow)
        let dim = CALayer()
        dim.frame = band.bounds
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = nightDim(night)
        band.addSublayer(dim)
        return Layers(root: root, drift: drift, copies: copies, veil: veil, band: band, strip: strip,
                      flowFade: flowFade, flowClock: flowClock, flow: flow, glow: glow, dim: dim)
    }

    /// A still of the colours on a screen of `size` (the snapshot sheet): the background where it starts. Without the
    /// strip: `render(in:)` skips masked layers (strip stills are drawn with Core Graphics, see AGENTS.md).
    static func still(size: CGSize, art: CGImage) -> CGImage? {
        let l = layers(size: size, bar: 37.5, night: false)
        let cover = LockWallpaper.back(art: art, size: size)
        for copy in l.copies { copy.removeAllAnimations(); copy.contents = cover }
        paintStrip(l.strip, stripColour(art))
        guard let c = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        l.root.render(in: c)
        return c.makeImage()
    }

    // MARK: - The clock

    /// The cover breathes and the strip's colours move only while the song plays and some of the desktop shows (windows
    /// cover it, a fullscreen app, the lock screen: the window isn't visible then). Only the drift and the flow's clock
    /// pause (`Layers`). Under Reduce Motion the colours hold still (the beat's light is a fade, so it stays).
    private func updateClock() {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for stage in stages {
            let drift = stage.layers.drift
            let moving = shown && playing && stage.window.occlusionState.contains(.visible)
            if moving == (drift.speed == 0) {
                Self.log.notice("desktop colours \(moving ? "moving" : "still", privacy: .public) (shown \(self.shown), song on \(self.songOn), playing \(self.playing), visible \(stage.window.occlusionState.contains(.visible)))")
            }
            Self.run(drift, moving)
            Self.run(stage.layers.flowClock, shown && playing && stripSeen(stage) && !still && !fullscreen)
        }
    }

    /// The strip can be seen: the window shows, or it's on the Space in front and nothing is fullscreen. The menu bar
    /// shows the strip through it, but with your windows over the rest of the desktop the window counts as covered (seen
    /// 11-07: a maximised Chrome and the Mac Suite dock left only the bar, and the window read "not visible"), so on
    /// occlusion alone the beat and the colours' motion were held most of the time.
    private func stripSeen(_ stage: Stage) -> Bool {
        stage.window.occlusionState.contains(.visible) || stage.window.isOnActiveSpace && !fullscreen
    }

    /// Starts or stops `layer`'s clock where it is.
    private static func run(_ layer: CALayer, _ moving: Bool) {
        let paused = layer.speed == 0
        if moving && paused {
            let at = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - at
        } else if !moving && !paused {
            let at = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = at
        }
    }

    private struct Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}
