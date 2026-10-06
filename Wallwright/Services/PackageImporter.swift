//
//  PackageImporter.swift
//  Wallwright
//
//  Imports an already-formed Wallpaper Engine package (a folder with its own project.json, preview
//  image, and asset files) into the wallpapers directory — as opposed to VideoImporter, which wraps
//  a single bare video file into that shape itself. Used by SteamWorkshopService's downloads, and
//  any other future source that hands over a complete package rather than raw media. Video/image
//  packages are imported as-is; scene packages are downgraded to a static image via SceneFallback
//  (see its own doc comment); anything else is rejected: see `preparePending`'s type check,
//  `WEProject.isSupportedType`/`isImportableType`.
//

import AppKit
import AVFoundation

/// A package import that's been prepared (project.json read, preview loaded) but not yet copied
/// into the wallpapers directory — lets the user review/edit the title and tags first, same as
/// PendingVideoImport does for manual video imports.
struct PendingPackageImport: Identifiable {
    let id = UUID()
    let sourceDirectory: URL
    var title: String
    var tags: [String]
    let thumbnail: NSImage
    /// WEProject.type ("video", "scene", ...) — shown in the review sheet so it's clear what kind
    /// of wallpaper this is before committing.
    let type: String
    let sourceId: String?
    /// Written to `project.sourceProvider` on commit — `nil` for a package that didn't come from any
    /// tracked source (e.g. a folder dragged straight into the library window from Finder).
    let sourceProvider: String?
    /// For a scene wallpaper with more than one plausible background-art texture: every candidate
    /// `SceneArtExtractor` could actually decode, most-likely-background first — lets the review
    /// sheet show a picker instead of silently committing to whichever one happened to resolve
    /// first. Empty for non-scene imports, or when extraction found 0 or 1 usable candidates
    /// (nothing worth choosing between).
    var sceneArtCandidates: [SceneArtExtractor.Candidate] = []
    /// Index into `sceneArtCandidates` the user has picked (or the default, index 0 — the
    /// resolver's own best guess — until they pick something else).
    var selectedSceneArtIndex: Int = 0
}

enum PackageImportError: LocalizedError {
    case missingProjectFile
    case previewLoadFailed
    case unsupportedType(String)

    var errorDescription: String? {
        switch self {
        case .missingProjectFile:
            return "This download doesn't contain a valid project.json"
        case .previewLoadFailed:
            return "Couldn't load this wallpaper's preview image"
        case .unsupportedType(let type):
            return "This wallpaper is a \"\(type)\" type — Wallwright only supports video and image wallpapers."
        }
    }
}

enum PackageImporter {
    /// `project`/`directory` are usually already available from the caller (e.g.
    /// `SteamWorkshopResult`), so this only re-reads from disk for the preview image. `async`
    /// because a scene import decodes every plausible background-art candidate here (see
    /// `sceneArtCandidates`), so the review sheet can offer a picker rather than the old silent
    /// first-match behavior — real scenes can take a moment for this (DXT/LZ4 decode), but it's a
    /// one-time cost before the review sheet appears, not a repeating one.
    static func preparePending(project: WEProject, directory: URL, sourceId: String? = nil, sourceProvider: String? = nil) async throws -> PendingPackageImport {
        guard project.isImportableType else {
            throw PackageImportError.unsupportedType(project.type)
        }
        // Downsampled at decode time, not loaded full-size — a third-party package (e.g. a Steam
        // Workshop download) ships its own preview image, which can be arbitrarily large and isn't
        // something this app generated or controls the size of.
        guard let thumbnail = ThumbnailDownsampler.downsampledThumbnail(at: directory.appending(path: project.preview))?.image else {
            throw PackageImportError.previewLoadFailed
        }
        let baseTitle = project.title.isEmpty ? directory.lastPathComponent : project.title
        // Flagged here, not inside SceneFallback (which runs later, at commit time): this is the
        // title the user actually sees and can edit in the review sheet, so the marker needs to be
        // visible and removable before anything is committed, not silently appended afterward.
        let title = WEProject.fallbackTypes.contains(project.type.lowercased())
            && !baseTitle.localizedCaseInsensitiveContains("scene preview")
            ? "\(baseTitle) (Scene Preview)" : baseTitle

        var candidates: [SceneArtExtractor.Candidate] = []
        if WEProject.fallbackTypes.contains(project.type.lowercased()) {
            candidates = await SceneArtExtractor.extractCandidates(directory: directory)
        }

        return PendingPackageImport(
            sourceDirectory: directory,
            title: title,
            tags: project.tags ?? [],
            thumbnail: thumbnail,
            type: project.type,
            sourceId: sourceId,
            sourceProvider: sourceProvider,
            sceneArtCandidates: candidates
        )
    }

    /// Reads project.json fresh off disk — used when a caller only has a bare directory (no
    /// already-parsed WEProject on hand).
    static func preparePending(at directory: URL, sourceId: String? = nil, sourceProvider: String? = nil) async throws -> PendingPackageImport {
        guard let data = try? Data(contentsOf: directory.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: data)
        else { throw PackageImportError.missingProjectFile }
        return try await preparePending(project: project, directory: directory, sourceId: sourceId, sourceProvider: sourceProvider)
    }

    /// Copies the package into the wallpapers directory under the (possibly user-edited) title,
    /// rewriting project.json's title/tags/import-metadata fields on the copy — the source
    /// directory itself (e.g. Steam's own Workshop cache) is left untouched.
    @discardableResult
    static func commitImport(_ pending: PendingPackageImport) async -> Bool {
        let fm = FileManager.default
        let trimmedTitle = pending.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? pending.sourceDirectory.lastPathComponent : trimmedTitle
        let destination = fm.uniqueWallpaperDestination(forTitle: finalTitle)

        do {
            try fm.copyItem(at: pending.sourceDirectory, to: destination)

            let projectURL = destination.appending(path: "project.json")
            guard let data = try? Data(contentsOf: projectURL),
                  var project = try? JSONDecoder().decode(WEProject.self, from: data)
            else {
                try? fm.removeItem(at: destination)
                return false
            }
            project.title = finalTitle
            project.tags = pending.tags.isEmpty ? nil : pending.tags
            project.sourceProvider = pending.sourceProvider
            project.sourceId = pending.sourceId
            project.dateAdded = ISO8601DateFormatter().string(from: Date())

            // Downgrades a scene to a static image using its own bundled preview, since this app
            // can't render Wallpaper Engine scenes directly: see SceneFallback's own doc comment.
            // Must run before the video-type check below: it rewrites `project.type` to "image",
            // so by the time that check runs for a former scene, it's correctly skipped.
            if WEProject.fallbackTypes.contains(project.type.lowercased()) {
                do {
                    // `pending.selectedSceneArtIndex` defaults to 0 (the resolver's own best
                    // guess) when the user never touched the picker, or when there was nothing to
                    // pick between — either way this is exactly what SceneFallback would have
                    // extracted on its own, just not re-decoded a second time here.
                    let candidates = pending.sceneArtCandidates
                    let chosenArt = candidates.indices.contains(pending.selectedSceneArtIndex)
                        ? candidates[pending.selectedSceneArtIndex].extracted : nil
                    project = try await SceneFallback.apply(to: project, in: destination, chosenArt: chosenArt)
                } catch {
                    WWLog.importing.error("PackageImporter: scene fallback failed: \(error)")
                    try? fm.removeItem(at: destination)
                    return false
                }
            }

            // Unlike VideoImporter's manual-file path, a package import never checked whether its
            // video is actually playable on macOS at all — a Steam Workshop/Wallpaper Engine
            // package can ship VP8/VP9/AV1 or an MKV/WebM container (all fine on Windows, none of
            // them decodable by AVFoundation), which previously imported "successfully" and then
            // showed a frozen or black desktop the moment it was set. Same `ensureCompatible` check
            // `VideoImporter.prepareImport` already runs, against the just-copied file (not the
            // source directory, which stays untouched either way) — `deleteSourceOnSuccess: true`
            // here, unlike VideoImporter's `false`, since this copy is already ours to manage, not
            // the user's own original file living somewhere else.
            if project.isSupportedType, project.type.lowercased() == "video" {
                // Captured before `project.preview` is overwritten below, so the source package's
                // own now-unused preview file can be cleaned up afterward — see "keeping things we
                // need only" at that cleanup's own call site.
                let originalPreviewFilename = project.preview
                let videoURL = destination.appending(path: project.file)
                // `try?` used to swallow a real transcode failure (ffmpeg missing, a timeout, a
                // corrupt bitstream) — VideoImporter's own `prepareImport` treats the exact same
                // call's failure as import-fatal (see its own `catch let error as
                // VideoTranscoderError`), but here the block was just skipped, leaving `project`
                // pointing at the original, still-incompatible file. Execution then fell straight
                // through to writing project.json and returning `true` — a package with a VP9/AV1/
                // MKV video (fine on Windows, none of it decodable by AVFoundation) "successfully"
                // registered a wallpaper that shows a black screen or fails outright the moment
                // it's set, with no error ever surfaced to the user.
                let transcodedURL: URL
                do {
                    (transcodedURL, _) = try await VideoTranscoder.ensureCompatible(
                        videoURL, outputDirectory: destination, deleteSourceOnSuccess: true
                    )
                } catch {
                    WWLog.importing.error("PackageImporter: transcode failed: \(error)")
                    try? fm.removeItem(at: destination)
                    return false
                }
                if transcodedURL != videoURL {
                    project.file = transcodedURL.lastPathComponent
                }
                // Also backfills width/height/audio/duration, which a package import never
                // populated at all — every other importer already probes this at commit time.
                let metadata = await VideoImporter.probeVideoMetadata(asset: AVURLAsset(url: transcodedURL))
                project.videoWidth = metadata.width
                project.videoHeight = metadata.height
                project.hasAudio = metadata.hasAudio
                project.videoDuration = metadata.duration

                // Replaces whatever preview image the source package itself shipped with a real
                // frame grabbed from the actual video — confirmed live (2026-10-05) that a Steam
                // Workshop item can ship a preview that doesn't represent its video at all (one
                // real item's own preview was a square, visually-corrupted-looking static/noise
                // image; its real video content looked nothing like that). `VideoImporter
                // .prepareImport`'s exact same recipe (second 1, preferred-track-transform applied,
                // bounded by `ThumbnailDownsampler.maxDimension`) — every video wallpaper in this
                // app gets its thumbnail this same way regardless of where it was imported from.
                // `try?`: a failed grab (e.g. a truly black first second) falls back to the
                // package's own preview rather than failing an otherwise-successful import.
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: transcodedURL))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: ThumbnailDownsampler.maxDimension, height: ThumbnailDownsampler.maxDimension)
                if let cgImage = try? await generator.image(at: CMTimeMake(value: 1, timescale: 1)).image,
                   let thumbnailData = NSImage(cgImage: cgImage, size: .zero).jpegData {
                    try? thumbnailData.write(to: destination.appending(path: "preview.jpg"), options: .atomic)
                    project.preview = "preview.jpg"
                    // The old preview is only real clutter if it was a genuinely separate file —
                    // same name (already overwritten above) or the video file itself (some
                    // packages point `preview` at their own video) are both left alone.
                    if originalPreviewFilename != "preview.jpg", originalPreviewFilename != project.file {
                        try? fm.removeItem(at: destination.appending(path: originalPreviewFilename))
                    }
                }
            }

            project.packageSizeBytes = (try? destination.directoryTotalAllocatedSize(includingSubfolders: true)).map(Int64.init)
            try JSONEncoder().encode(project).write(to: projectURL)

            VideoImporter.notifyLibraryChanged()
            return true
        } catch {
            WWLog.importing.error("PackageImporter: commit failed: \(error)")
            try? fm.removeItem(at: destination)
            return false
        }
    }
}
