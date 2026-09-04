//
//  VideoImporter.swift
//  Wallwright
//

import AVFoundation
import AppKit

/// A video import that's been prepared (thumbnail generated, default title derived) but not yet
/// written into the wallpapers directory — lets the user review/edit the title and tags first.
struct PendingVideoImport: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var title: String
    var tags: [String] = []
    let thumbnail: NSImage
    /// Set when the source wasn't natively playable and had to be converted first — surfaced in
    /// the review sheet the same way YouTube imports show it, rather than converting silently.
    let transcodedFrom: VideoFileInfo?
    /// Probed once here (reusing the same AVAsset load already done for the thumbnail) and
    /// carried through to `WEProject` on commit — see the doc comment there for why.
    let videoWidth: Int?
    let videoHeight: Int?
    let hasAudio: Bool
    let videoDuration: Double?
}

enum VideoImportPreparationError: LocalizedError {
    case notARegularFile
    case thumbnailFailed
    case transcodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "That doesn't look like a readable video file"
        case .thumbnailFailed:
            return "Couldn't read this video — it may be corrupt or use an unsupported codec"
        case .transcodeFailed(let message):
            return message
        }
    }
}

enum VideoImporter {
    /// Posted after a wallpaper is added, removed, or edited on disk — the one thing every one
    /// of those call sites (this file, ZipImporter, the folder-copy paths in ImportPanels/
    /// ContentViewModel, the delete confirmations in ContentView, WallpaperPreview's title/tag
    /// edits) needs to do, so `ContentViewModel` can be the single place that reacts to it rather
    /// than each of those call sites needing a direct reference to refresh the grid itself.
    static let wallpaperLibraryDidChangeNotification = Notification.Name("Wallwright.wallpaperLibraryDidChange")

    static func notifyLibraryChanged() {
        NotificationCenter.default.post(name: wallpaperLibraryDidChangeNotification, object: nil)
    }

    /// Containers AVFoundation opens natively, without needing any conversion first.
    static let nativeExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// Everything else accepted at the file-picker/drag-and-drop gate — ffmpeg reads all of these,
    /// and `prepareImport` converts them to a native container/codec before anything touches
    /// AVFoundation. Kept as an explicit allowlist (rather than accepting any extension) so a
    /// stray non-video file dropped in doesn't get treated as an import attempt.
    static let importableExtensions: Set<String> = nativeExtensions.union([
        "mkv", "avi", "webm", "flv", "wmv", "mpg", "mpeg", "m2ts", "ts", "3gp", "ogv",
    ])

    /// Generates a thumbnail and default title for `url` without touching the wallpapers
    /// directory yet — the result is only committed once the caller confirms it (see
    /// `commitImport`), so the user gets a chance to fix a messy filename-derived title or add
    /// tags before anything is actually copied in. Converts the source first if it isn't already
    /// something AVFoundation can decode (wrong container, or a codec like AV1/VP9).
    static func prepareImport(at url: URL) async throws -> PendingVideoImport {
        guard let wrapper = try? FileWrapper(url: url), wrapper.isRegularFile else {
            throw VideoImportPreparationError.notARegularFile
        }

        // A converted copy is written into our own scratch directory, never next to (or over)
        // the user's original file, and the original is never deleted — it's their file, sitting
        // wherever they picked it from (Downloads, an external drive, etc.), not ours to touch.
        let scratchDir = FileManager.default.temporaryDirectory.appending(path: "wallwright-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        // Cleanup only happens on the SUCCESS path elsewhere (`ContentViewModel.cleanupScratchSource`,
        // called from `commitCurrentImport`/`skipCurrentImport` once a `PendingVideoImport` exists to
        // call it on) — if this function itself throws below (a corrupt/malformed source video,
        // reachable via ordinary drag-and-drop), no `PendingVideoImport` is ever returned, so nothing
        // outside this function has a reference to clean up what can already be a fully re-encoded,
        // multi-hundred-MB scratch file at that point. `didSucceed` guards against removing it out
        // from under a genuinely successful return.
        var didSucceed = false
        defer { if !didSucceed { try? FileManager.default.removeItem(at: scratchDir) } }

        let (playableURL, transcodedFrom): (URL, VideoFileInfo?)
        do {
            (playableURL, transcodedFrom) = try await VideoTranscoder.ensureCompatible(
                url, outputDirectory: scratchDir, deleteSourceOnSuccess: false
            )
        } catch let error as VideoTranscoderError {
            throw VideoImportPreparationError.transcodeFailed(error.errorDescription ?? "Conversion failed")
        }
        // `ensureCompatible` returns the ORIGINAL `url` untouched (never writing into
        // `outputDirectory` at all) when the source is already natively playable — `scratchDir`
        // was created above just in case, but stays permanently empty in that case, and nothing
        // downstream ever gets a reference to it to clean up later (the returned `sourceURL` is the
        // user's own original file, which `cleanupScratchSource` correctly never touches). Removing
        // it here, the one place that still knows its path, is the only chance to avoid leaking one
        // empty UUID-named directory in `/tmp` per compatible import.
        if !playableURL.path.hasPrefix(scratchDir.path) {
            try? FileManager.default.removeItem(at: scratchDir)
        }

        let asset = AVURLAsset(url: playableURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        // Decodes directly at this size instead of decoding the full frame (up to the source
        // video's native resolution — 4K/8K isn't unusual) and resizing after. `.zero` in either
        // dimension means "unconstrained" to AVFoundation, so this only bounds the larger side,
        // same as ThumbnailDownsampler's own maxDimension.
        imageGenerator.maximumSize = CGSize(width: ThumbnailDownsampler.maxDimension, height: ThumbnailDownsampler.maxDimension)
        let time = CMTimeMake(value: 1, timescale: 1)

        guard let cgImage = try? await imageGenerator.image(at: time).image else {
            throw VideoImportPreparationError.thumbnailFailed
        }
        let thumbnail = NSImage(cgImage: cgImage, size: .zero)
        let metadata = await probeVideoMetadata(asset: asset)

        didSucceed = true
        return PendingVideoImport(
            sourceURL: playableURL,
            title: url.deletingPathExtension().lastPathComponent,
            thumbnail: thumbnail,
            transcodedFrom: transcodedFrom,
            videoWidth: metadata.width,
            videoHeight: metadata.height,
            hasAudio: metadata.hasAudio,
            videoDuration: metadata.duration
        )
    }

    /// Writes a reviewed `PendingVideoImport` into the wallpapers directory using its (possibly
    /// user-edited) title and tags, reusing the thumbnail already generated by `prepareImport`.
    static func commitImport(
        _ pending: PendingVideoImport,
        sourceProvider: String? = nil,
        sourceId: String? = nil
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pending.sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        guard let previewData = pending.thumbnail.jpegData else { return false }

        let filename = pending.sourceURL.lastPathComponent
        let title = pending.title.isEmpty ? pending.sourceURL.deletingPathExtension().lastPathComponent : pending.title

        var projectData = WEProject(file: filename, preview: "preview.jpg", title: title, type: "video")
        projectData.tags = pending.tags.isEmpty ? nil : pending.tags
        projectData.sourceProvider = sourceProvider
        projectData.sourceId = sourceId
        projectData.dateAdded = ISO8601DateFormatter().string(from: Date())
        projectData.videoWidth = pending.videoWidth
        projectData.videoHeight = pending.videoHeight
        projectData.hasAudio = pending.hasAudio
        projectData.videoDuration = pending.videoDuration
        // A cheap stat call, not a directory walk — good enough for the size Estimated Impact
        // and the detail panel need, and means neither has to touch the filesystem again later.
        let videoAttributes = try? FileManager.default.attributesOfItem(atPath: pending.sourceURL.path)
        let videoBytes = (videoAttributes?[.size] as? Int64) ?? 0
        projectData.packageSizeBytes = videoBytes + Int64(previewData.count)

        // `FileManager.copyItem` + direct `Data.write`, not `FileWrapper` — see
        // `VideoImporter.importVideoFile`'s identical fix and doc comment for why (measured RSS
        // spike matching the source file's full size, and no APFS `clonefile` fast path). This is
        // the review-and-commit path (File > Open, drag-and-drop, YouTube, Direct URL all funnel
        // through `prepareImport` then here) — missed when `importVideoFile`'s one-shot sibling
        // was fixed, since the two look similar but are separate functions.
        let destination = FileManager.default.uniqueWallpaperDestination(forTitle: title)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pending.sourceURL, to: destination.appending(path: filename))
            try previewData.write(to: destination.appending(path: "preview.jpg"), options: .atomic)
            try JSONEncoder().encode(projectData).write(to: destination.appending(path: "project.json"), options: .atomic)
            notifyLibraryChanged()
            return true
        } catch {
            // A failure partway through (realistically: running out of disk space while copying
            // the video file) can leave some of the destination's contents already written. Clean
            // those up rather than leaving a broken, permanently-invisible directory behind
            // (`ContentViewModel.refresh()` just silently skips anything without a valid
            // project.json — it never deletes it), same as `PackageImporter.commitImport`'s own
            // failure path.
            print("VideoImporter: write failed: \(error)")
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }

    /// Wraps a bare video file into a wallpaper package (video + generated thumbnail + project.json)
    /// and writes it into the wallpapers directory directly, skipping review — used by sources that
    /// already supply a proper title/tags of their own (e.g. MotionBgs), where a review step would
    /// just be friction. Completion is called on the main queue.
    /// - Parameters:
    ///   - title: Display title and destination folder name. Defaults to the video's filename
    ///     (sans extension) when not provided.
    ///   - tags: Tags to record for the wallpaper (e.g. a source's own category/tag data), if any.
    ///   - sourceProvider: Identifies where this came from (e.g. "motionbgs"), if not a manual import.
    ///     Recorded in project.json so a source can check "do I already have this?" before re-downloading.
    ///   - sourceId: The item's ID at that source provider.
    static func importVideoFile(
        at url: URL,
        title: String? = nil,
        tags: [String]? = nil,
        sourceProvider: String? = nil,
        sourceId: String? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let filename = url.lastPathComponent
        let title = title ?? url.deletingPathExtension().lastPathComponent

        // `FileManager.copyItem`, not `FileWrapper` — confirmed live: building a `FileWrapper`
        // around the source file and writing the whole directory wrapper out reads the entire
        // video into resident memory (measured a 200MB source file inflating RSS by ~200MB during
        // the write) and bypasses APFS's `clonefile` fast path entirely (measured ~1500x slower
        // than `copyItem` for the same file — clonefile is a near-instant pointer copy, this was a
        // genuine byte-for-byte write). For a real multi-GB 4K source, that's real memory pressure
        // and many extra seconds on every video import for no benefit — `FileWrapper` exists for
        // building an in-memory document package, not for relocating an already-on-disk file.
        let destination = FileManager.default.uniqueWallpaperDestination(forTitle: title)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination.appending(path: filename))
        } catch {
            print("VideoImporter: copy failed: \(error)")
            try? FileManager.default.removeItem(at: destination)
            DispatchQueue.main.async { completion(false) }
            return
        }

        var projectData = WEProject(file: filename, preview: "preview.jpg", title: title, type: "video")
        projectData.tags = (tags?.isEmpty == false) ? tags : nil
        projectData.sourceProvider = sourceProvider
        projectData.sourceId = sourceId
        projectData.dateAdded = ISO8601DateFormatter().string(from: Date())

        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: ThumbnailDownsampler.maxDimension, height: ThumbnailDownsampler.maxDimension)
        let time = CMTimeMake(value: 1, timescale: 1)
        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
            guard error == nil, let cgImage = cgImage,
                  let data = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            else {
                try? FileManager.default.removeItem(at: destination)
                DispatchQueue.main.async { completion(false) }
                return
            }
            Task {
                let metadata = await probeVideoMetadata(asset: asset)
                projectData.videoWidth = metadata.width
                projectData.videoHeight = metadata.height
                projectData.hasAudio = metadata.hasAudio
                projectData.videoDuration = metadata.duration
                let videoAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let videoBytes = (videoAttributes?[.size] as? Int64) ?? 0
                projectData.packageSizeBytes = videoBytes + Int64(data.count)

                await MainActor.run {
                    do {
                        try data.write(to: destination.appending(path: "preview.jpg"), options: .atomic)
                        try JSONEncoder().encode(projectData).write(to: destination.appending(path: "project.json"), options: .atomic)
                        notifyLibraryChanged()
                        completion(true)
                    } catch {
                        print("VideoImporter: write failed: \(error)")
                        try? FileManager.default.removeItem(at: destination)
                        completion(false)
                    }
                }
            }
        }
    }

    /// Fills in whichever of `videoWidth`/`videoHeight`/`hasAudio`/`videoDuration` are still nil on
    /// a wallpaper imported before those fields existed, persisting the result to `project.json` so
    /// this only ever runs once per wallpaper — called lazily (e.g. `ExplorerItem`'s `.task`,
    /// `WallpaperPreview`'s detail load) rather than eagerly for the whole library at once, so it
    /// only costs anything for wallpapers actually scrolled into view or opened.
    /// Returns the updated project, or nil if there was nothing to backfill (already complete, not
    /// a video, or the probe/write failed).
    @discardableResult
    static func backfillMetadataIfNeeded(for wallpaper: WEWallpaper) async -> WEProject? {
        guard wallpaper.project.type.lowercased() == "video" else { return nil }
        var project = wallpaper.project
        guard project.videoWidth == nil || project.videoHeight == nil
            || project.hasAudio == nil || project.videoDuration == nil
        else { return nil }

        let videoURL = wallpaper.wallpaperDirectory.appending(path: project.file)
        let metadata = await probeVideoMetadata(asset: AVURLAsset(url: videoURL))
        guard metadata.width != nil || metadata.duration != nil else { return nil }

        project.videoWidth = project.videoWidth ?? metadata.width
        project.videoHeight = project.videoHeight ?? metadata.height
        project.hasAudio = project.hasAudio ?? metadata.hasAudio
        project.videoDuration = project.videoDuration ?? metadata.duration

        guard let data = try? JSONEncoder().encode(project) else { return nil }
        try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)
        // `updateWallpaperInPlace`, not `notifyLibraryChanged()` — this already knows exactly which
        // one wallpaper changed and what its new value is, so there's no reason to fall back to the
        // heavy, debounced path meant for "something changed somewhere, go find out what": that
        // notification's own subscriber (`ContentViewModel.init`) responds to it with a full
        // `refresh()` — a complete rescan of the wallpapers directory re-decoding every project.json
        // on disk. Called from `ExplorerItem`'s `.task(id:)` for every visible grid card missing
        // metadata, a scroll through an unmigrated library could trigger that full rescan repeatedly.
        // Dispatched onto the main actor explicitly — this function isn't itself actor-isolated (the
        // `await probeVideoMetadata` above can resume off-main), but `ContentViewModel.wallpapers` is
        // an `@Published` property SwiftUI expects mutated only from the main thread.
        let updatedWallpaper = WEWallpaper(using: project, where: wallpaper.wallpaperDirectory)
        await MainActor.run {
            AppDelegate.shared.contentViewModel.updateWallpaperInPlace(updatedWallpaper)
        }
        return project
    }

    /// Regenerates `preview.jpg` from the exact frame at `timestamp` seconds into the video (picked
    /// via EditWallpaperSheet's frame chooser), persists `timestamp` to `project.json` as
    /// `thumbnailTimestamp`, and notifies the library so the grid/sidebar/edit-sheet previews (all
    /// of which just re-read `preview.jpg` off disk) pick it up. Returns nil, leaving the old
    /// preview in place, if the asset can't produce a frame at that timestamp.
    @discardableResult
    static func regenerateThumbnail(for wallpaper: WEWallpaper, atSeconds timestamp: Double) async -> WEProject? {
        guard wallpaper.project.type.lowercased() == "video" else { return nil }

        let videoURL = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        // Exact frame, not "nearest cheap keyframe" — the whole point is the precise moment the
        // user picked, unlike the two fixed-1-second call sites above which never needed this.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Bounds decode resolution only — orthogonal to the exact-timing tolerance above, which is
        // about which moment in time gets decoded, not how large the resulting frame is.
        generator.maximumSize = CGSize(width: ThumbnailDownsampler.maxDimension, height: ThumbnailDownsampler.maxDimension)

        let time = CMTime(seconds: timestamp, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image,
              let previewData = NSImage(cgImage: cgImage, size: .zero).jpegData
        else { return nil }

        try? previewData.write(to: wallpaper.wallpaperDirectory.appending(path: "preview.jpg"), options: .atomic)

        var project = wallpaper.project
        // Without this, a wallpaper whose `preview` field pointed at something other than
        // "preview.jpg" (e.g. a Steam Workshop package that ships its own "preview.gif") kept
        // silently loading that stale original file forever — the frame above always gets written
        // to "preview.jpg" regardless, but nothing ever pointed the project at it. Confirmed live
        // (2026-08-07) on a real imported wallpaper stuck exactly this way.
        project.preview = "preview.jpg"
        project.thumbnailTimestamp = timestamp
        guard let data = try? JSONEncoder().encode(project) else { return nil }
        try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)
        notifyLibraryChanged()
        return project
    }

    /// Detects and removes black bars baked into the video's own pixel content (see
    /// VideoCropDetector's header). Returns nil, leaving the file untouched, if no real bars were
    /// found or the crop/re-encode failed.
    @discardableResult
    static func detectAndCropBlackBars(for wallpaper: WEWallpaper) async -> WEProject? {
        guard wallpaper.project.type.lowercased() == "video" else { return nil }
        let videoURL = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
        let nativeWidth = wallpaper.project.videoWidth ?? 0
        let nativeHeight = wallpaper.project.videoHeight ?? 0
        guard let crop = await VideoCropDetector.detectBlackBars(at: videoURL, nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        else { return nil }
        return await applyCrop(crop, for: wallpaper)
    }

    /// Same re-encode-in-place path as `detectAndCropBlackBars`, but for a rectangle the user drew
    /// themselves (EditWallpaperSheet's manual crop overlay) rather than one ffmpeg detected —
    /// useful for framing/composition, not just removing bars, so no "is this a real border"
    /// threshold applies here.
    @discardableResult
    static func cropManually(for wallpaper: WEWallpaper, to rect: VideoCropRect) async -> WEProject? {
        guard wallpaper.project.type.lowercased() == "video" else { return nil }
        return await applyCrop(rect, for: wallpaper)
    }

    /// Shared tail end of both crop entry points above: re-encodes the file in place (same
    /// filename unless the container needed to change to `.mp4` — see `targetURL` below),
    /// regenerates `preview.jpg` from the now-cropped frame, and updates the persisted width/height.
    private static func applyCrop(_ crop: VideoCropRect, for wallpaper: WEWallpaper) async -> WEProject? {
        let videoURL = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
        let croppedURL = wallpaper.wallpaperDirectory.appending(path: "cropped-\(UUID().uuidString).mp4")
        // Clamped here, the one choke point both crop entry points (auto black-bar detection and
        // EditWallpaperSheet's manual overlay) already funnel through — ffmpeg's crop filter
        // strictly requires x + width <= in_w (and the same for y/height), aborting the whole
        // crop otherwise. EditWallpaperSheet computes x/width from independent `.rounded()` calls
        // on normalized [0...1] coordinates, which can sum to nativeWidth + 1 in edge cases
        // (dragging a crop handle flush to an edge is the easy way to hit this) — confirmed live:
        // "Invalid position or size for width 960 and position 961" on exactly that kind of
        // off-by-one. Width/height are capped to the frame first, then x/y clamped against the
        // now-safe width/height, so this holds even if width/height themselves were oversized.
        let safeCrop: VideoCropRect
        if let nativeWidth = wallpaper.project.videoWidth, let nativeHeight = wallpaper.project.videoHeight,
           nativeWidth > 0, nativeHeight > 0 {
            let safeWidth = min(crop.width, nativeWidth)
            let safeHeight = min(crop.height, nativeHeight)
            let safeX = max(0, min(crop.x, nativeWidth - safeWidth))
            let safeY = max(0, min(crop.y, nativeHeight - safeHeight))
            safeCrop = VideoCropRect(x: safeX, y: safeY, width: safeWidth, height: safeHeight)
        } else {
            safeCrop = crop
        }
        let encodedSize: (width: Int, height: Int)
        // `VideoCropDetector.crop` always writes an `.mp4` (`h264_videotoolbox` into an MP4
        // container) — if the source was a different native container (`.mov` is also accepted
        // unconverted at import time, see `VideoTranscoder`), replacing at `videoURL`'s original
        // path via `replaceItemAt` would leave a file whose extension no longer matches what's
        // actually inside it. Renaming to `.mp4` when they differ keeps `project.file` honest about
        // the real container instead of relying on AVFoundation's tolerance for the mismatch.
        let targetURL = videoURL.deletingPathExtension().appendingPathExtension("mp4")
        do {
            encodedSize = try await VideoCropDetector.crop(videoURL, to: safeCrop, destination: croppedURL)
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: croppedURL)
            if targetURL != videoURL {
                try? FileManager.default.removeItem(at: videoURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: croppedURL)
            return nil
        }

        var project = wallpaper.project
        if targetURL != videoURL {
            project.file = targetURL.lastPathComponent
        }
        // The actual encoded dimensions (`VideoCropDetector.crop`'s own even-rounded width/height,
        // and after `safeCrop`'s clamping), not the raw, possibly-odd or possibly-out-of-bounds
        // `crop.width`/`crop.height` the UI requested — those two values already might not match
        // the file's real dimensions before this fix (see `VideoCropDetector.crop`'s own doc
        // comment for why an odd request is a real, reachable case), and `EditWallpaperSheet`'s own
        // "Invalid position or size" clamping edge case would make it worse (persisting a size that
        // was never actually encoded at all).
        project.videoWidth = encodedSize.width
        project.videoHeight = encodedSize.height

        // Regenerates the thumbnail from the now-cropped file so the grid/preview stop showing the
        // old bars too — same frame-grab-and-downsample `regenerateThumbnail` above uses, at
        // whatever timestamp was already chosen (or 1s, `prepareImport`'s own default) if none was.
        // `targetURL`, not `videoURL` — when the extension changed, `videoURL`'s file no longer
        // exists on disk (removed above).
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: targetURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: ThumbnailDownsampler.maxDimension, height: ThumbnailDownsampler.maxDimension)
        let time = CMTimeMake(value: Int64(wallpaper.project.thumbnailTimestamp ?? 1), timescale: 1)
        if let cgImage = try? await generator.image(at: time).image,
           let previewData = NSImage(cgImage: cgImage, size: .zero).jpegData {
            try? previewData.write(to: wallpaper.wallpaperDirectory.appending(path: "preview.jpg"), options: .atomic)
            project.preview = "preview.jpg"
        }

        guard let data = try? JSONEncoder().encode(project) else { return nil }
        try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)
        notifyLibraryChanged()
        return project
    }

    /// Real pixel dimensions (orientation-corrected) and audio-track presence, probed directly
    /// off the asset — the same technique `WallpaperPreview.loadResolution()` uses for display,
    /// but done once at import time and persisted so nothing has to re-probe the file later. Not
    /// private — `PackageImporter.commitImport` reuses this for the exact same reason after its own
    /// transcode step.
    static func probeVideoMetadata(asset: AVAsset) async -> (width: Int?, height: Int?, hasAudio: Bool, duration: Double?) {
        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
        let duration: Double?
        if let cmDuration = try? await asset.load(.duration), cmDuration.isNumeric {
            duration = CMTimeGetSeconds(cmDuration)
        } else {
            duration = nil
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else {
            return (nil, nil, hasAudio, duration)
        }
        let size = naturalSize.applying(transform)
        return (Int(abs(size.width)), Int(abs(size.height)), hasAudio, duration)
    }
}

