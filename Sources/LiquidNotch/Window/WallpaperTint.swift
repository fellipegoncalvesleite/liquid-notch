import AppKit

/// The dim bloom's tint from the desktop picture (the sim's `WALL_TINT`, which it picks per sample wallpaper): the
/// wallpaper's hue, kept light and soft (OKLab L 0.74, chroma 0.05–0.09), so it reads as the screen's own light; a grey
/// or black wallpaper gets the sim's periwinkle. Read on launch and when the Space changes; nil until it can be read.
enum WallpaperTint {
    static let neutral = "#9AA3FF"

    static func tint(url: URL) -> String? {
        average(url).map { tint(average: $0) }
    }

    /// The tint for an average wallpaper colour (sRGB 0…1).
    static func tint(average c: SIMD3<Double>) -> String {
        let lab = OKLab.fromSRGB(c)
        let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        guard chroma >= 0.02 else { return neutral }
        let k = min(max(chroma, 0.05), 0.09) / chroma
        return SRGB.hex(OKLab.toSRGB(L: 0.74, a: lab.y * k, b: lab.z * k))
    }

    /// The picture's average colour, from a 16 × 16 thumbnail (a dynamic wallpaper's HEIC gives its first frame).
    private static func average(_ url: URL) -> SIMD3<Double>? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 16] as CFDictionary)
        else { return nil }
        let w = 16, h = 16
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = SIMD3<Double>(0, 0, 0)
        for i in stride(from: 0, to: px.count, by: 4) { sum += SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255 }
        return sum / Double(w * h)
    }
}
