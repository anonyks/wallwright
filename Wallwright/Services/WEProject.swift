//
//  WEProject.swift
//  Wallwright
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI
import ImageIO

struct WEProjectPropertyOption: Codable, Equatable, Hashable {
    var label: String
    var value: String
}

struct WEProjectProperty: Codable, Equatable, Hashable {
    // optional
    var condition: String?
    var index: Int?
    var options: [WEProjectPropertyOption]?
    var order: Int?
    
    // must have
    var text: String
    var type: String
    var value: String
}

struct WEProjectProperties: Codable, Equatable, Hashable {
    var schemecolor: WEProjectProperty?
}

struct WEProjectGeneral: Codable, Equatable, Hashable {
    var properties: WEProjectProperties
}

enum WorkshopId: Codable, Equatable, Hashable, RawRepresentable {
    case int(Int)
    case string(String)
    
    var rawValue: String {
        switch self {
        case .int(let x):
            return String(x)
        case .string(let x):
            return x
        }
    }
    
    init?(rawValue: String) {
        guard rawValue.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self = .string(rawValue)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(Int.self) {
            self = .int(x)
            return
        }
        if let x = try? container.decode(String.self) {
            self = .string(x)
            return
        }
        throw DecodingError.typeMismatch(Self.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for Workshop ID"))
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let x):
            try container.encode(x)
        case .string(let x):
            try container.encode(x)
        }
    }
}

struct WEProject: Codable, Equatable, Hashable {
    var approved: Bool?
    var contentrating: String?
    var description: String?
    var file: String
    var general: WEProjectGeneral?
    var preview: String
    var tags: [String]?
    var title: String
    var visibility: String?
    var workshopid: WorkshopId?
    var workshopurl: String?
    var type: String
    var version: Int?

    /// Wallpaper types Wallwright can actually import and render — video (AVFoundation playback)
    /// and image (static). Anything else (e.g. "scene"/"web" from a Steam Workshop package) is
    /// rejected at import and excluded from the library, since there's no renderer for it.
    static let supportedTypes: Set<String> = ["video", "image"]
    var isSupportedType: Bool { Self.supportedTypes.contains(type.lowercased()) }

    /// Where this wallpaper came from, when it wasn't added manually (e.g. "motionbgs"). Lets
    /// us detect "you already have this" before re-downloading it and wasting storage/bandwidth.
    var sourceProvider: String?
    /// The item's ID at the source provider (e.g. MotionBgs' numeric media ID).
    var sourceId: String?
    /// When this wallpaper was imported, in ISO 8601 form.
    var dateAdded: String?

    /// Real pixel dimensions of the media — for video, probed via AVAsset; for a static image,
    /// read directly from the file. Reused across both types (rather than a parallel
    /// imageWidth/imageHeight pair) since every consumer (`WallpaperPreview`'s resolution row,
    /// `WallpaperImpactEstimator`) already just wants "how big is this, regardless of type."
    /// Persisted at import time so nothing has to re-probe the file on every estimate/display.
    /// Nil for wallpapers imported before this existed — the estimator falls back to its old
    /// filename-hint guess then. `hasAudio` stays video-only; always nil for images.
    var videoWidth: Int?
    var videoHeight: Int?
    var hasAudio: Bool?

    /// The video's duration in seconds, probed at import time alongside `videoWidth`/`videoHeight`.
    /// Nil for wallpapers imported before this existed, or non-video types.
    var videoDuration: Double?

    /// True if this "image" wallpaper is actually a macOS "Dynamic Desktop" HEIC — a single file
    /// containing multiple time-of-day frames — probed once at import time (see
    /// `DynamicDesktopHEIC.isDynamicDesktop`) and persisted so nothing has to re-open the file to
    /// check on every render. Nil/false means "render as one static image," same as before this
    /// existed. Always nil for `type == "video"`.
    var isDynamicDesktop: Bool?

    /// The frame (offset in seconds into the video) the user explicitly picked to represent this
    /// wallpaper — the source frame for `preview.jpg` (read by the grid, sidebar preview, and Edit
    /// sheet) and the frame the live wallpaper seeds in when it starts already paused (see
    /// VideoWallpaperViewModel.seedInitialFrameIfStartingPaused). Nil means "no explicit choice"
    /// and leaves both paths exactly as they behave today.
    var thumbnailTimestamp: Double?

    /// Playback trim range in seconds into the file — when both are set, the live wallpaper starts
    /// and loops within `trimStart...trimEnd` instead of the whole file. Nil means "no trim, use
    /// the whole file," same convention as `thumbnailTimestamp`. Purely a playback bound — never
    /// rewrites or re-encodes the underlying video file.
    var trimStart: Double?
    var trimEnd: Double?

    /// Package size in bytes, computed once at import time from a cheap file stat (not a
    /// directory walk) — see `WEWallpaper.wallpaperSize`, which prefers this over recomputing it
    /// live. Nil for wallpapers imported before this existed.
    var packageSizeBytes: Int64?

    /// "M:SS" formatted `videoDuration`, or nil if it hasn't been probed.
    var durationText: String? {
        guard let videoDuration, videoDuration.isFinite, videoDuration > 0 else { return nil }
        let totalSeconds = Int(videoDuration.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    static let invalid = Self(file: "",
                              preview: "",
                              title: "Error",
                              type: "video")
}

struct WEWallpaper: Codable, RawRepresentable, Identifiable {
    
    var id: Int { self.project.hashValue }
    var rawValue: String {
        do {
            let rawValueData = try JSONEncoder().encode(self)
            return String(data: rawValueData, encoding: .utf8)!
        } catch {
            print(error)
            return ""
        }
    }
    
    var wallpaperDirectory: URL
    var project: WEProject
    
    /// Prefers `project.packageSizeBytes` (computed once at import time) over a live directory
    /// walk — this is read for every wallpaper on every sort/filter, so recomputing it from disk
    /// each time is real, avoidable I/O. Only wallpapers imported before that field existed fall
    /// back to the live walk.
    var wallpaperSize: Int {
        if let cached = project.packageSizeBytes { return Int(cached) }
        guard let sizeBytes = try? self.wallpaperDirectory.directoryTotalAllocatedSize(includingSubfolders: true)
        else { return 0 }
        return sizeBytes
    }

    /// When this wallpaper was added to the library, used for the "Recently Added" sort. Prefers
    /// `project.dateAdded` (set by every importer at commit time) — falls back to the package
    /// directory's filesystem creation date only for wallpapers imported before that field existed.
    var dateAdded: Date? {
        if let raw = project.dateAdded, let parsed = ISO8601DateFormatter().date(from: raw) {
            return parsed
        }
        return try? wallpaperDirectory.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    init(using project: WEProject, where url: URL) {
        self.wallpaperDirectory = url
        self.project = project
    }
    
    enum CodingKeys: CodingKey {
        case wallpaperDirectory
        case project
        // <all the other elements too>
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.wallpaperDirectory = try container.decode(URL.self, forKey: .wallpaperDirectory)
        self.project = try container.decode(WEProject.self, forKey: .project)
        // <and so on>
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallpaperDirectory, forKey: .wallpaperDirectory)
        try container.encode(project, forKey: .project)
        // <and so on>
    }
    
    init?(rawValue: String) {
        if let rawValueData = rawValue.data(using: .utf8),
           let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: rawValueData) {
            self = wallpaper
        } else {
            return nil
        }
    }
}

enum WEWallpaperSortingMethod: String, CaseIterable, Identifiable {
    var id: Self { self }

    case name = "Name"
    case fileSize = "File Size"
    case estimatedImpact = "Estimated Impact"
    case recentlyAdded = "Recently Added"
}

enum WEWallpaperSortingSequence: Int {
    case decrease = 0, increase = 1
}

enum WEInitError: Error {
    enum WEJSONProjectInitError: Error {
        case notFound, corrupted, mismatched, unkownError
    }
    
    enum WEResourcesInitError: Error {
        case notFound, mismatchedFormat, corrupted, unkownError
    }
    
    enum WEPreviewInitError: Error {
        case notFound, notImage, unkownError
    }
    
    case badDirectoryPath
    case JSONProject(was: WEJSONProjectInitError)
    case resources(was: WEResourcesInitError)
    case preview(was: WEPreviewInitError)
}
