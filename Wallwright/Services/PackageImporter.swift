//
//  PackageImporter.swift
//  Wallwright
//
//  Imports an already-formed Wallpaper Engine package (a folder with its own project.json, preview
//  image, and asset files) into the wallpapers directory — as opposed to VideoImporter, which wraps
//  a single bare video file into that shape itself. Used by SteamWorkshopService's downloads, and
//  any other future source that hands over a complete package rather than raw media. Only
//  video/image packages are accepted — see `preparePending`'s type check — since those are the
//  only types this app can actually render (see `WEProject.isSupportedType`).
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
    /// `SteamWorkshopResult`), so this only re-reads from disk for the preview image.
    static func preparePending(project: WEProject, directory: URL, sourceId: String? = nil, sourceProvider: String? = nil) throws -> PendingPackageImport {
        guard project.isSupportedType else {
            throw PackageImportError.unsupportedType(project.type)
        }
        // Downsampled at decode time, not loaded full-size — a third-party package (e.g. a Steam
        // Workshop download) ships its own preview image, which can be arbitrarily large and isn't
        // something this app generated or controls the size of.
        guard let thumbnail = ThumbnailDownsampler.downsampledThumbnail(at: directory.appending(path: project.preview))?.image else {
            throw PackageImportError.previewLoadFailed
        }
        return PendingPackageImport(
            sourceDirectory: directory,
            title: project.title.isEmpty ? directory.lastPathComponent : project.title,
            tags: project.tags ?? [],
            thumbnail: thumbnail,
            type: project.type,
            sourceId: sourceId,
            sourceProvider: sourceProvider
        )
    }

    /// Reads project.json fresh off disk — used when a caller only has a bare directory (no
    /// already-parsed WEProject on hand).
    static func preparePending(at directory: URL, sourceId: String? = nil, sourceProvider: String? = nil) throws -> PendingPackageImport {
        guard let data = try? Data(contentsOf: directory.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: data)
        else { throw PackageImportError.missingProjectFile }
        return try preparePending(project: project, directory: directory, sourceId: sourceId, sourceProvider: sourceProvider)
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
                    print("PackageImporter: transcode failed: \(error)")
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
            }

            project.packageSizeBytes = (try? destination.directoryTotalAllocatedSize(includingSubfolders: true)).map(Int64.init)
            try JSONEncoder().encode(project).write(to: projectURL)

            VideoImporter.notifyLibraryChanged()
            return true
        } catch {
            print("PackageImporter: commit failed: \(error)")
            try? fm.removeItem(at: destination)
            return false
        }
    }
}
