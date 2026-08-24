//
//  ThumbnailDownsampler.swift
//  Wallwright
//
//  Confirmed live (2026-08-09) via `vmmap` on a freshly-launched, otherwise-idle process: four
//  IOSurfaces at 7652x4073 and 8000x3196 (tagged 'CMPhoto RGB' by ImageIO), ~455MB combined out of
//  an 852MB physical footprint. Root cause: both import pipelines generated/loaded thumbnails at
//  full source resolution with zero downsampling — ImageImporter set `project.preview` to the
//  original full-size file itself, and VideoImporter saved `preview.jpg` from the raw
//  AVAssetImageGenerator frame (whatever the source video's native resolution is). Every grid
//  cell, hover preview, and review sheet — none of which ever displays larger than a few hundred
//  points — was decoding that full-size file from scratch on every appearance.
//
//  `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways` does
//  an efficient decode-at-target-size directly from the source, never materializing the full-size
//  bitmap in memory at all — the tool this file's static-image helpers are built on. Video's own
//  thumbnail generation (`VideoImporter`) uses the equivalent `AVAssetImageGenerator.maximumSize`
//  instead, for the same reason: decode at the target size directly, not full-size-then-resize.
//

import AppKit
import ImageIO

enum ThumbnailDownsampler {
    /// Comfortably larger than any place a generated thumbnail is actually displayed (grid cells,
    /// the 420pt-wide import review sheet, hover previews) while avoiding ever holding or writing
    /// a full 4K/8K decode just to show one.
    static let maxDimension: CGFloat = 1024

    /// For rendering a static image wallpaper on an actual screen — not a thumbnail, so this
    /// intentionally decodes much larger than `maxDimension`, capped to the screen's own native
    /// pixel resolution rather than an arbitrary small size. Mirrors
    /// `VideoWallpaperViewModel.nativeScreenResolution()`'s reasoning for video: a Retina MacBook
    /// screen tops out around 3-4K native pixels, so decoding an 8K+ source wallpaper at its full
    /// resolution burns real memory and CPU on detail the screen physically cannot display, exactly
    /// the same waste `preferredMaximumResolution` already prevents for video.
    static func decodedForScreen(at url: URL, screen: NSScreen) -> CGImage? {
        let scale = screen.backingScaleFactor
        let maxPixels = max(screen.frame.width, screen.frame.height) * scale
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Efficient decode-at-size straight from a source file — never fully decodes the original
    /// into memory. Also returns the real, undownsampled pixel dimensions (read from metadata, not
    /// a second full decode) for callers that need to persist the source's true resolution.
    static func downsampledThumbnail(at url: URL, maxDimension: CGFloat = maxDimension) -> (image: NSImage, pixelsWide: Int, pixelsHigh: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let realSize = imagePixelSize(source)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let image = NSImage(cgImage: cgThumbnail, size: .zero)
        let pixelsWide = realSize?.width ?? cgThumbnail.width
        let pixelsHigh = realSize?.height ?? cgThumbnail.height
        return (image, pixelsWide, pixelsHigh)
    }

    /// Reads pixel dimensions from the source's own metadata — no pixel data is decoded.
    private static func imagePixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Same efficient decode-at-size as `downsampledThumbnail(at:)`, for bytes already in memory
    /// (e.g. a browse-tab source image just downloaded via `URLSession`) rather than a file on
    /// disk — used by `RetryingAsyncImage`'s manual-fetch path, which previously decoded the raw
    /// downloaded bytes at full resolution via `NSImage(data:)`. Confirmed live (2026-08-09): a
    /// remote source's hero image at 7652x4073 showed up as the exact same ~119MB IOSurface across
    /// separate app launches, pointing at one specific recurring image rather than local library
    /// content.
    static func downsampledImage(from data: Data, maxDimension: CGFloat = maxDimension) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgThumbnail, size: .zero)
    }
}

extension NSImage {
    /// 0.85 rather than the implicit 1.0 default `NSBitmapImageRep.representation` otherwise
    /// uses — visually indistinguishable at thumbnail size, meaningfully smaller `preview.jpg`
    /// files on disk (less to read back on every future grid render, too).
    var jpegData: Data? {
        guard let tiffData = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
