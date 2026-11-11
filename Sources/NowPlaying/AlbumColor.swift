import CoreGraphics
import Foundation
import ImageIO

/// The album's colour for the bars: the saturated colours of the cover, averaged and lifted
/// so they read on black. Nil for a grey cover (the caller picks a fallback).
public enum AlbumColor {
    public static func hex(from artwork: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(artwork as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) else { return nil }
        return hex(from: thumb)
    }

    public static func hex(from image: CGImage) -> String? {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var sum = (r: 0.0, g: 0.0, b: 0.0), weight = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
            let mx = max(r, g, b), mn = min(r, g, b)
            let saturation = mx > 0 ? (mx - mn) / mx : 0
            // Vivid, not too dark: those carry the cover's colour.
            let w = saturation * saturation * mx
            sum.r += r * w; sum.g += g * w; sum.b += b * w
            weight += w
        }
        guard weight > 0.6 else { return nil }
        var c = (r: sum.r / weight, g: sum.g / weight, b: sum.b / weight)
        // Lift it so the brightest channel is at least 0.85: the bars sit on black.
        let mx = max(c.r, c.g, c.b)
        if mx > 0 && mx < 0.85 { let k = 0.85 / mx; c = (c.r * k, c.g * k, c.b * k) }
        let q = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", q(c.r), q(c.g), q(c.b))
    }
}
