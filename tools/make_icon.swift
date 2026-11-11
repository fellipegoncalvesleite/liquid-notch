// Draws the app icon: a black liquid island with a ball budding off its side on a liquid bridge (the same
// smooth-union SDF the shader uses, the way a second activity separates), a cover and music bars inside, over the
// album glow on a night background. Full-bleed square
// artwork: macOS masks it. Run: swift tools/make_icon.swift <out-dir>  → AppIcon.png (1024) + AppIcon.icns
import AppKit
import CoreGraphics

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

func smin(_ a: Double, _ b: Double, _ k: Double) -> Double {
    let h = max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k * 0.25
}
func roundBox(_ px: Double, _ py: Double, _ cx: Double, _ cy: Double, _ hw: Double, _ hh: Double, _ r: Double) -> Double {
    let qx = abs(px - cx) - hw + r, qy = abs(py - cy) - hh + r
    return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
}
func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}
func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(max((x - e0) / (e1 - e0), 0), 1); return t * t * (3 - 2 * t)
}

// Geometry (y down, in 1024 px).
let island = (cx: 404.0, cy: 512.0, hw: 262.0, hh: 112.0, r: 112.0)
let drop = (cx: 788.0, cy: 512.0, r: 84.0)
let blend = 104.0

func shape(_ x: Double, _ y: Double) -> Double {
    smin(roundBox(x, y, island.cx, island.cy, island.hw, island.hh, island.r),
         hypot(x - drop.cx, y - drop.cy) - drop.r, blend)
}

let night0 = (0.035, 0.047, 0.110), night1 = (0.090, 0.050, 0.180)
let glowA = (1.0, 0.24, 0.50), glowB = (1.0, 0.62, 0.26)

var px = [UInt8](repeating: 0, count: size * size * 4)
for j in 0..<size {
    for i in 0..<size {
        let x = Double(i) + 0.5, y = Double(j) + 0.5
        // Night, a little lighter low down.
        var c = mix(night0, night1, y / Double(size))
        // The album glow under the island: warm, soft, mostly below it.
        let gx = (x - 512) / 470, gy = (y - 560) / 360
        let g = exp(-(gx * gx + gy * gy) * 2.2)
        let hue = min(max((x - 260) / 520, 0), 1)
        c = mix(c, mix(glowA, glowB, hue), g * 0.95)
        // The liquid: black, its edge anti-aliased, a faint rim of light along the top.
        let d = shape(x, y)
        let cover = 1 - smooth(-0.8, 0.8, d)
        let rim = (1 - smooth(0, 3.5, abs(d + 2))) * smooth(560, 400, y) * 0.18
        c = mix(c, (0.0, 0.0, 0.0), cover)
        c = mix(c, (1, 1, 1), rim * cover)
        let k = (j * size + i) * 4
        px[k] = UInt8(min(max(c.0, 0), 1) * 255); px[k + 1] = UInt8(min(max(c.1, 0), 1) * 255)
        px[k + 2] = UInt8(min(max(c.2, 0), 1) * 255); px[k + 3] = 255
    }
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// CoreGraphics is y up: flip so the vector parts use the same coordinates as above.
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

// The cover, in the island's left ear: the glow's own colours.
let art = CGRect(x: 174, y: 446, width: 132, height: 132)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: art, cornerWidth: 32, cornerHeight: 32, transform: nil)); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 1, green: 0.30, blue: 0.55, alpha: 1),
                                                CGColor(srgbRed: 1, green: 0.66, blue: 0.30, alpha: 1)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: art.minX, y: art.minY), end: CGPoint(x: art.maxX, y: art.maxY), options: [])
ctx.restoreGState()

// The bars, in the right ear: four, white, rounded.
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
let heights: [CGFloat] = [76, 128, 58, 100], bw: CGFloat = 24, gap: CGFloat = 18
var bx: CGFloat = 628 - (bw * 4 + gap * 3)
for h in heights {
    let r = CGRect(x: bx, y: 512 - h / 2, width: bw, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil))
    bx += bw + gap
}
ctx.fillPath()

let image = ctx.makeImage()!
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func png(_ img: CGImage, _ px: Int, _ url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    g.imageInterpolation = .high
    NSGraphicsContext.current = g
    g.cgContext.draw(img, in: CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}
png(image, 1024, out.appendingPathComponent("AppIcon.png"))

// The .icns, through iconutil.
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    png(image, s, set.appendingPathComponent("icon_\(s)x\(s).png"))
    png(image, s * 2, set.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("wrote \(out.path)/AppIcon.png and AppIcon.icns")
