//
//  WallpaperImpactEstimator.swift
//  Wallwright
//
//  Estimates a wallpaper's relative system impact (CPU/RAM/battery combined) from static
//  properties already on disk — type, resolution, audio, package size. This is a heuristic proxy
//  computed instantly, NOT a real measurement: nothing on macOS exposes reliable per-wallpaper
//  CPU/GPU/battery readings without actually playing it, so this intentionally reports one
//  combined "estimated impact" level rather than fabricating separate CPU%/GPU%/battery numbers
//  that would imply precision the app doesn't have.
//
//  Deliberately kept to pure arithmetic over fields already sitting in `project.json` — no file
//  I/O, no AVAsset probing, nothing async — since this runs for every wallpaper in the grid on
//  every sort/filter. The one thing that's genuinely expensive (reading the real video
//  resolution/audio-track presence) is probed once at import time by VideoImporter and persisted,
//  not redone here.
//

import SwiftUI

enum WallpaperImpactLevel: Int, Comparable, CaseIterable {
    case low = 0, medium = 1, high = 2, veryHigh = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .veryHigh: return "Very High"
        }
    }

    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .veryHigh: return .red
        }
    }
}

enum WallpaperImpactEstimator {
    static func estimate(for wallpaper: WEWallpaper) -> WallpaperImpactLevel {
        var score: Double

        if wallpaper.project.type.lowercased() == "image" {
            // A static image has no ongoing decode cost the way continuously-played video does —
            // a 4K photo costs about the same to display as a 1080p one, unlike 4K vs 1080p video
            // *decode*. Skip the resolution multiplier and audio bump entirely (neither applies)
            // and start from a lower base; only file size (GPU/disk footprint) contributes below.
            score = 0.5
        } else {
            score = 1.0
            let pixelCount = realPixelCount(for: wallpaper.project) ?? resolutionHint(in: wallpaper.project.file)
            if let pixelCount {
                if pixelCount >= 3840 * 2160 {
                    score *= 1.5
                } else if pixelCount >= 1920 * 1080 {
                    score *= 1.0
                } else {
                    score *= 0.7
                }
            }

            // A modest flat bump, not a multiplier — audio decode/mixing is real but secondary
            // compared to video decode, shouldn't dominate the estimate on its own.
            if wallpaper.project.hasAudio == true {
                score += 0.3
            }
        }

        let sizeMB = Double(wallpaper.wallpaperSize) / 1_000_000
        score += sizeMB * 0.02

        switch score {
        case ..<1.5: return .low
        case ..<2.5: return .medium
        case ..<4.0: return .high
        default: return .veryHigh
        }
    }

    private static func realPixelCount(for project: WEProject) -> Int? {
        guard let width = project.videoWidth, let height = project.videoHeight else { return nil }
        return width * height
    }

    /// Fallback for wallpapers imported before real resolution was persisted — looks for a
    /// "WIDTHxHEIGHT" pattern in the filename (common in this app's own asset naming, e.g.
    /// "azure-horizon.3840x2160.mp4") and returns width * height if found.
    private static let resolutionRegex = try? NSRegularExpression(pattern: #"(\d{3,5})x(\d{3,5})"#)

    private static func resolutionHint(in filename: String) -> Int? {
        guard let regex = resolutionRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              let widthRange = Range(match.range(at: 1), in: filename),
              let heightRange = Range(match.range(at: 2), in: filename),
              let width = Int(filename[widthRange]),
              let height = Int(filename[heightRange])
        else { return nil }
        return width * height
    }
}
