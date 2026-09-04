//
//  DynamicDesktopHEIC.swift
//  Wallwright
//
//  Detects and picks frames from a macOS "Dynamic Desktop" HEIC — a single HEIF file containing
//  multiple images (one per time-of-day/sun-angle bucket), tagged with Apple's private
//  `apple_desktop:*` XMP metadata (solar altitude/azimuth and/or simple time-of-day mappings) so
//  System Settings can cycle the desktop picture across the day. Confirmed live (2026-07-30) via
//  a real sample: 16 frames, an `apple_desktop:solar` tag on frame 0 whose per-frame altitude
//  rises then falls across the index range — i.e. frames are stored in chronological order.
//

import ImageIO
import Foundation
import AppKit

enum DynamicDesktopHEIC {
    private static let appleDesktopNamespace = "http://ns.apple.com/namespace/1.0/"

    /// True if `url` is a Dynamic Desktop HEIC — only checks for the tag's presence, not its
    /// contents. Frame selection (`currentFrameIndex`) doesn't need to parse the embedded solar
    /// data at all (see its own doc comment for why).
    static func isDynamicDesktop(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 1,
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]
        else { return false }
        return tags.contains { (CGImageMetadataTagCopyNamespace($0) as String?) == appleDesktopNamespace }
    }

    /// Picks which embedded frame should be showing right now. Frames are evenly spaced across a
    /// 24-hour day in chronological index order (confirmed above) — this maps the current local
    /// clock time directly onto that index range, rather than parsing the embedded solar
    /// altitude/azimuth data and computing true sun position for the user's real location,
    /// which would need a location source (a permission prompt, or a third-party geolocation
    /// lookup) for a visual difference that's negligible for a desktop wallpaper's purposes.
    static func currentFrameIndex(frameCount: Int, now: Date = Date()) -> Int {
        guard frameCount > 0 else { return 0 }
        // A 2-frame Dynamic Desktop is Apple's plain Light/Dark appearance toggle (tagged
        // `apple_desktop:apr`), not a chronological solar cycle — confirmed by directly decoding
        // the real `apple_desktop:apr` metadata on a genuine 2-frame Apple wallpaper
        // (/System/Library/Desktop Pictures/Sonoma.heic): its own appearance map is
        // `{"l": 0, "d": 1}`, light is frame 0, dark is frame 1. The generic "evenly divide 24
        // hours across frameCount" formula below is correct for a real chronological solar set
        // (confirmed separately: frame 0's own solar-altitude tag is the lowest, rising then
        // falling across the index range) but silently inverts a 2-frame file — every daylight
        // hour after noon would show the dark frame and vice versa. Matched to the system's
        // actual current appearance instead, not time of day at all, since that's what the "apr"
        // tag itself encodes and a user's light/dark setting doesn't necessarily track daylight.
        guard frameCount != 2 else {
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 1 : 0
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let dayFraction = (Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60) / 24
        return min(frameCount - 1, Int(dayFraction * Double(frameCount)))
    }

    /// Extracts the frame at `index` as a `CGImage`, or `nil` if the file can't be read or the
    /// index is out of range. `maxPixelSize`, when given, decodes at that size directly via
    /// `CGImageSourceCreateThumbnailAtIndex` rather than the source's full native resolution —
    /// same reasoning as `ThumbnailDownsampler.decodedForScreen`: a screen can't display more
    /// pixels than it has, so decoding a Dynamic Desktop frame larger than the screen's own native
    /// resolution just burns memory on undisplayable detail.
    static func frame(at index: Int, in url: URL, maxPixelSize: CGFloat? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), index >= 0, index < CGImageSourceGetCount(source) else {
            return nil
        }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    static func frameCount(in url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }
}
