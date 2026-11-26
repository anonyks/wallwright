//
//  ColorBand.swift
//  Wallwright
//
//  The library's "filter by color" bands, and how a wallpaper's preview is sorted into them.
//

import CoreGraphics
import Foundation
import ImageIO

enum ColorBand: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, cyan, blue, purple, pink
    /// Next to no color anywhere: black, white and gray images.
    case monochrome

    var id: Self { self }

    var label: String {
        self == .monochrome ? "Black & White" : rawValue.capitalized
    }

    /// Share of the whole image a color needs before the wallpaper counts as that color, so a
    /// small highlight doesn't put it in a band. A wallpaper can be in several.
    private static let minimumShare = 0.08
    /// Below this share of colored pixels in total, the wallpaper is monochrome.
    private static let monochromeLimit = 0.06
    private static let sampleDimension = 48

    /// `hue` in degrees, 0..<360.
    private static func band(forHue hue: Double) -> ColorBand {
        switch hue {
        case 15..<42: return .orange
        case 42..<70: return .yellow
        case 70..<165: return .green
        case 165..<195: return .cyan
        case 195..<255: return .blue
        case 255..<290: return .purple
        case 290..<345: return .pink
        default: return .red
        }
    }

    /// Nil if the image can't be read.
    static func bands(ofImageAt url: URL) -> Set<ColorBand>? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width * height > 0 else { return nil }

        var counts: [ColorBand: Int] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[offset]) / 255, g = Double(pixels[offset + 1]) / 255, b = Double(pixels[offset + 2]) / 255
            let high = max(r, g, b), delta = high - min(r, g, b)
            // Dark and washed-out pixels read as black, gray or white whatever their hue says.
            guard high >= 0.2, delta / high >= 0.3 else { continue }
            var sector: Double
            if high == r { sector = (g - b) / delta }
            else if high == g { sector = (b - r) / delta + 2 }
            else { sector = (r - g) / delta + 4 }
            if sector < 0 { sector += 6 }
            counts[band(forHue: sector * 60), default: 0] += 1
        }

        let total = Double(width * height)
        if Double(counts.values.reduce(0, +)) / total < monochromeLimit { return [.monochrome] }
        let matches = Set(counts.filter { Double($0.value) / total >= minimumShare }.keys)
        // Colored, but spread so thinly that nothing reaches the share: use the largest.
        if matches.isEmpty, let largest = counts.max(by: { $0.value < $1.value })?.key { return [largest] }
        return matches
    }
}
