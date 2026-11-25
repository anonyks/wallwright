//
//  PaletteExporter.swift
//  Wallwright
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Writes the active wallpaper's extracted colors to `~/.config/wallwright/palettes/current.json`
/// on every wallpaper change, for ricing tools (SketchyBar, Ghostty, Kitty, Raycast, ...) that
/// want to theme themselves off the current desktop. Called from the same background-queue call
/// sites as `WallpaperChangeHook`.
///
/// Also keeps the same extraction available in-process as real `NSColor`s (`current`), read
/// directly by `GlobalSettings.resolvedClockGradient` for the clock overlay's "Dynamic Wallpaper
/// Match" color — that path doesn't need to re-parse hex strings back out of the JSON file this
/// same extraction already wrote.
enum PaletteExporter {
    struct Palette: Codable, Equatable {
        let dominant: String
        let accent: String
        let vibrant: String
        let surface: String
        let isDark: Bool
    }

    struct ResolvedColors {
        /// `WEWallpaper.id` of the wallpaper these colors were extracted from — lets a caller
        /// (`GlobalSettings.resolvedClockGradient`) key a per-wallpaper override to the exact
        /// wallpaper this extraction actually ran against, rather than separately asking some
        /// other subsystem "what's the current wallpaper" and risking the two disagreeing.
        let wallpaperId: String
        let dominant: NSColor
        let accent: NSColor
        let vibrant: NSColor
        let surface: NSColor
        let isDark: Bool
    }

    /// Only ever assigned on the main queue (see `export(for:)` below), even though extraction
    /// itself runs on a background queue — safe to read from the main thread at any time,
    /// including mid-draw from `ClockOverlayView`.
    static private(set) var current: ResolvedColors?

    /// Posted on the main queue right after `current` updates — lets `ClockOverlayView` redraw
    /// immediately when "Dynamic Wallpaper Match" is selected, instead of waiting for its own
    /// periodic tick (up to a minute away with seconds display off).
    static let didUpdateNotification = Notification.Name("Wallwright.paletteDidUpdate")

    private static let outputURL = URL(
        fileURLWithPath: ("~/.config/wallwright/palettes/current.json" as NSString).expandingTildeInPath
    )

    /// Downsampled sample size — large enough to capture the image's real color distribution,
    /// small enough that extraction runs in low-single-digit milliseconds even though every call
    /// site already dispatches this to a background `.utility` queue anyway.
    private static let sampleDimension = 24

    static func export(for wallpaper: WEWallpaper) {
        guard !wallpaper.project.preview.isEmpty else { return }
        let previewURL = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.preview)
        guard let raw = extractRawPalette(from: previewURL) else { return }

        let resolved = ResolvedColors(
            wallpaperId: wallpaper.id,
            dominant: nsColor(raw.dominant), accent: nsColor(raw.accent),
            vibrant: nsColor(raw.vibrant), surface: nsColor(raw.surface), isDark: raw.isDark
        )
        DispatchQueue.main.async {
            current = resolved
            NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        }
        WWLog.settings.notice(
            "PaletteExporter: dominant=\(hexString(raw.dominant), privacy: .public) accent=\(hexString(raw.accent), privacy: .public) vibrant=\(hexString(raw.vibrant), privacy: .public) surface=\(hexString(raw.surface), privacy: .public) isDark=\(raw.isDark, privacy: .public) for \(wallpaper.project.title, privacy: .public)"
        )

        let palette = Palette(
            dominant: hexString(raw.dominant), accent: hexString(raw.accent),
            vibrant: hexString(raw.vibrant), surface: hexString(raw.surface), isDark: raw.isDark
        )
        guard let data = try? JSONEncoder().encode(palette) else { return }
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: outputURL, options: .atomic)
    }

    private static func nsColor(_ color: (r: Int, g: Int, b: Int)) -> NSColor {
        NSColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    private typealias RawPalette = (
        dominant: (r: Int, g: Int, b: Int), accent: (r: Int, g: Int, b: Int),
        vibrant: (r: Int, g: Int, b: Int), surface: (r: Int, g: Int, b: Int), isDark: Bool
    )

    private struct ColorBucket {
        var count = 0
        var rSum = 0
        var gSum = 0
        var bSum = 0
        var averageColor: (r: Int, g: Int, b: Int) {
            (rSum / max(count, 1), gSum / max(count, 1), bSum / max(count, 1))
        }
    }

    private static func extractRawPalette(from url: URL) -> RawPalette? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 4 levels per channel (64 buckets total) — coarse enough that compression noise and
        // gradient banding collapse into the same bucket, fine enough to tell genuinely different
        // hues apart.
        var buckets: [Int: ColorBucket] = [:]
        var luminanceSum = 0.0
        let totalPixels = width * height

        for pixelIndex in 0..<totalPixels {
            let offset = pixelIndex * bytesPerPixel
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            luminanceSum += luminance((r, g, b))
            let key = (r / 64) * 16 + (g / 64) * 4 + (b / 64)
            var bucket = buckets[key] ?? ColorBucket()
            bucket.count += 1
            bucket.rSum += r
            bucket.gSum += g
            bucket.bSum += b
            buckets[key] = bucket
        }

        guard !buckets.isEmpty else { return nil }

        // Ignore buckets that are just a handful of outlier pixels (a single bright highlight,
        // compression artifacts) — they'd otherwise win "most vibrant" or "darkest" by chance
        // rather than representing anything visually significant in the image.
        let minimumSignificantCount = max(2, totalPixels / 200)
        let significant = buckets.values.filter { $0.count >= minimumSignificantCount }
        let candidates = significant.isEmpty ? Array(buckets.values) : significant

        let byFrequency = candidates.sorted { $0.count > $1.count }
        let dominant = byFrequency[0].averageColor
        // The next-most-frequent bucket that's actually a different color from `dominant` — a
        // second shade of the same color (common in near-flat backgrounds) shouldn't masquerade
        // as a distinct accent tone. 40 is an RGB-space Euclidean threshold found by eye against
        // real wallpaper previews — "same color, different shade" sits well under it.
        let accent = byFrequency.first { colorDistance($0.averageColor, dominant) > 40 }?.averageColor
            ?? (byFrequency.count > 1 ? byFrequency[1].averageColor : dominant)
        let vibrant = candidates.max { saturation($0.averageColor) < saturation($1.averageColor) }?.averageColor
            ?? dominant
        let surface = candidates.min { luminance($0.averageColor) < luminance($1.averageColor) }?.averageColor
            ?? dominant

        let overallLuminance = luminanceSum / Double(totalPixels)

        return (dominant: dominant, accent: accent, vibrant: vibrant, surface: surface, isDark: overallLuminance < 128)
    }

    /// Perceived luminance, 0-255 scale — the same weighting the roadmap's own WCAG-guarding note
    /// specifies (`L = 0.299R + 0.587G + 0.114B`).
    private static func luminance(_ color: (r: Int, g: Int, b: Int)) -> Double {
        0.299 * Double(color.r) + 0.587 * Double(color.g) + 0.114 * Double(color.b)
    }

    private static func saturation(_ color: (r: Int, g: Int, b: Int)) -> Double {
        let maxChannel = Double(max(color.r, color.g, color.b))
        let minChannel = Double(min(color.r, color.g, color.b))
        guard maxChannel > 0 else { return 0 }
        return (maxChannel - minChannel) / maxChannel
    }

    private static func colorDistance(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Double {
        let dr = Double(a.r - b.r)
        let dg = Double(a.g - b.g)
        let db = Double(a.b - b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private static func hexString(_ color: (r: Int, g: Int, b: Int)) -> String {
        String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    }
}
