//
//  ImageImporter.swift
//  Wallwright
//
//  Import pipeline for static image wallpapers — deliberately NOT a generalization of
//  VideoImporter's flow. Video import does real work (transcode via VideoTranscoder, an
//  AVAssetImageGenerator frame grab for the thumbnail, AVAsset metadata probing) that has no
//  image equivalent at all; an image import is just "read the file, copy it in." Mirrors
//  VideoImporter's public shape (prepareImport/commitImport, a Pending* struct) so the two read
//  the same way side by side, without forcing either through one generic path.
//

import AppKit

/// An image import that's been prepared (thumbnail = the image itself, default title derived)
/// but not yet written into the wallpapers directory — same review-before-commit shape as
/// `PendingVideoImport`.
struct PendingImageImport: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var title: String
    var tags: [String] = []
    let thumbnail: NSImage
    /// Real pixel dimensions, read directly from the file (not the image's "point size", which
    /// can differ for @2x-tagged assets) — stored into `WEProject.videoWidth`/`videoHeight` on
    /// commit, the same fields video uses (see that field's doc comment for why they're shared).
    let width: Int?
    let height: Int?
    /// See `WEProject.isDynamicDesktop`.
    let isDynamicDesktop: Bool
}

enum ImageImportPreparationError: LocalizedError {
    case notARegularFile
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .notARegularFile: return "That doesn't look like a readable image file"
        case .unreadableImage: return "Couldn't read this image — it may be corrupt or use an unsupported format"
        }
    }
}

enum ImageImporter {
    /// Formats `NSImage`/`NSBitmapImageRep` can load directly — no conversion step needed, unlike
    /// video's `importableExtensions` (which exists specifically because *not* every video
    /// container is natively decodable).
    static let importableExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "bmp"]

    /// Generates a default title from the filename and reads real pixel dimensions — nothing is
    /// copied into the wallpapers directory yet (see `commitImport`).
    ///
    /// Previously decoded the source file in full twice over — once via `NSBitmapImageRep(data:)`
    /// just to read `pixelsWide`/`pixelsHigh`, again via `NSImage(contentsOf:)` for the review
    /// sheet's thumbnail — for what's only ever displayed at 420pt wide. Confirmed live
    /// (2026-08-09) via `vmmap`: a handful of real source photos (7652x4073, 8000x3196) showed up
    /// as ~100MB+ full-resolution IOSurfaces each. `ThumbnailDownsampler` reads real dimensions
    /// from metadata (no decode) and produces the thumbnail via `CGImageSourceCreateThumbnailAtIndex`
    /// (an efficient decode-at-size, never materializing the full-size bitmap at all).
    static func prepareImport(at url: URL) throws -> PendingImageImport {
        guard let wrapper = try? FileWrapper(url: url), wrapper.isRegularFile else {
            throw ImageImportPreparationError.notARegularFile
        }
        guard let (thumbnail, pixelsWide, pixelsHigh) = ThumbnailDownsampler.downsampledThumbnail(at: url) else {
            throw ImageImportPreparationError.unreadableImage
        }

        return PendingImageImport(
            sourceURL: url,
            title: url.deletingPathExtension().lastPathComponent,
            thumbnail: thumbnail,
            width: pixelsWide,
            height: pixelsHigh,
            isDynamicDesktop: DynamicDesktopHEIC.isDynamicDesktop(at: url)
        )
    }

    /// One-shot import for source-downloaded images — skips the manual review sheet since the
    /// title/tags are already known, same convenience `VideoImporter.importVideoFile` provides
    /// for videos downloaded from a browsable source.
    static func importImageFile(
        at url: URL,
        title: String? = nil,
        tags: [String]? = nil,
        sourceProvider: String? = nil,
        sourceId: String? = nil
    ) -> Bool {
        guard var pending = try? prepareImport(at: url) else { return false }
        if let title, !title.isEmpty { pending.title = title }
        if let tags { pending.tags = tags }
        return commitImport(pending, sourceProvider: sourceProvider, sourceId: sourceId)
    }

    /// Writes a reviewed `PendingImageImport` into the wallpapers directory — the full-size image
    /// itself (needed as-is for actually setting the desktop wallpaper, via `project.file`) plus a
    /// real downsampled `preview.jpg` (via `project.preview`), the same shape video's import already
    /// used. Previously `project.preview` pointed straight back at the full-size original — every
    /// grid cell, hover preview, and edit-sheet thumbnail was decoding the whole source image just
    /// to show it a few hundred points wide; see `ThumbnailDownsampler`'s header for the measured
    /// impact.
    static func commitImport(
        _ pending: PendingImageImport,
        sourceProvider: String? = nil,
        sourceId: String? = nil
    ) -> Bool {
        guard let wrapper = try? FileWrapper(url: pending.sourceURL), wrapper.isRegularFile else { return false }
        guard let previewData = pending.thumbnail.jpegData else { return false }

        let filename = wrapper.filename ?? pending.sourceURL.lastPathComponent
        let title = pending.title.isEmpty ? pending.sourceURL.deletingPathExtension().lastPathComponent : pending.title

        var projectData = WEProject(file: filename, preview: "preview.jpg", title: title, type: "image")
        projectData.tags = pending.tags.isEmpty ? nil : pending.tags
        projectData.sourceProvider = sourceProvider
        projectData.sourceId = sourceId
        projectData.dateAdded = ISO8601DateFormatter().string(from: Date())
        projectData.videoWidth = pending.width
        projectData.videoHeight = pending.height
        projectData.isDynamicDesktop = pending.isDynamicDesktop ? true : nil

        let imageAttributes = try? FileManager.default.attributesOfItem(atPath: pending.sourceURL.path)
        projectData.packageSizeBytes = ((imageAttributes?[.size] as? Int64) ?? 0) + Int64(previewData.count)

        let wallpaperDirectoryWrapper = FileWrapper(directoryWithFileWrappers: [filename: wrapper])
        wallpaperDirectoryWrapper.addRegularFile(withContents: previewData, preferredFilename: "preview.jpg")
        wallpaperDirectoryWrapper.addRegularFile(withContents: (try? JSONEncoder().encode(projectData)) ?? Data(), preferredFilename: "project.json")

        let destination = FileManager.default.wallpapersDirectory.appending(path: title)
        do {
            // Same stale-directory-clear as VideoImporter.commitImport — FileWrapper.write throws
            // if something's already there, which would otherwise make every retry/re-import fail.
            try? FileManager.default.removeItem(at: destination)
            try wallpaperDirectoryWrapper.write(to: destination, originalContentsURL: nil)
            VideoImporter.notifyLibraryChanged()
            return true
        } catch {
            // Same cleanup-on-partial-write-failure as VideoImporter.commitImport — see its
            // comment for why.
            print("ImageImporter: write failed: \(error)")
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }
}
