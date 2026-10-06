//
//  SceneFallback.swift
//  Wallwright
//
//  Wallpaper Engine "scene" wallpapers (layered textures, particles, shaders, scripting) have no
//  live renderer in this app. Rather than rejecting scene imports outright after a user has
//  already paid the full Workshop download cost, this converts the scene into a static "image"
//  wallpaper instead: first by trying to pull the real background art out of scene.pkg itself via
//  SceneArtExtractor (direct JPEG/PNG, DXT1/3/5 decode, or a video-frame grab — confirmed live
//  2026-10-05 against real downloaded scenes), falling back to the small bundled preview image
//  (every Workshop item ships one regardless) only when nothing in the package is usable. When the
//  import review sheet offered a choice between multiple candidate textures, the user's pick comes
//  straight in as `chosenArt` instead of this re-deriving the same first-match automatically.
//

import Foundation

enum SceneFallbackError: LocalizedError, Equatable {
    case missingPreview
    case unreadablePreview

    var errorDescription: String? {
        switch self {
        case .missingPreview:
            return "This scene wallpaper's preview image is missing or empty"
        case .unreadablePreview:
            return "This scene wallpaper's preview image couldn't be read"
        }
    }
}

enum SceneFallback {
    /// `directory` is `PackageImporter.commitImport`'s already-copied-into-place `destination`,
    /// never the original source/cache directory (Steam's own Workshop cache is left untouched).
    /// `chosenArt`: when the import review sheet offered a picker (`PendingPackageImport
    /// .sceneArtCandidates`) and the user picked one, that candidate is passed straight through
    /// here instead of re-running extraction and silently taking the first match again.
    static func apply(to project: WEProject, in directory: URL, chosenArt: SceneArtExtractor.Extracted? = nil) async throws -> WEProject {
        let extracted = chosenArt == nil ? await SceneArtExtractor.extract(directory: directory) : chosenArt
        let updated: WEProject
        if let extracted {
            updated = try applyExtractedArt(extracted, to: project, in: directory)
        } else {
            updated = try applyPreview(to: project, in: directory)
        }
        // Neither outcome above ever reads scene.pkg again — `updated.type` is "image" either way,
        // and a committed "image" wallpaper's `file`/`preview` always point at the just-written
        // static artwork, never back into the archive. Left in place, this is real, substantial
        // wasted disk space: confirmed live (2026-10-05) against a real 246MB scene.pkg sitting
        // unused in the library after extraction. `try?`: a failed cleanup shouldn't fail an
        // otherwise-successful import.
        try? FileManager.default.removeItem(at: directory.appending(path: "scene.pkg"))
        return updated
    }

    /// Writes the real-artwork extraction result as the wallpaper's full-size file, plus a
    /// downsampled preview.jpg, same shape every other importer already produces.
    private static func applyExtractedArt(_ extracted: SceneArtExtractor.Extracted, to project: WEProject, in directory: URL) throws -> WEProject {
        let filename = "scene-art.jpg"
        try extracted.jpegData.write(to: directory.appending(path: filename), options: .atomic)

        var updated = project
        updated.type = "image"
        updated.file = filename
        updated.preview = "preview.jpg"
        updated.videoWidth = extracted.width
        updated.videoHeight = extracted.height

        // preview.jpg may already exist (the scene's own bundled preview). Downsample the
        // just-extracted art over it instead of leaving the old, unrelated preview in place.
        if let thumbnailData = ThumbnailDownsampler.downsampledImage(from: extracted.jpegData)?.jpegData {
            try thumbnailData.write(to: directory.appending(path: "preview.jpg"), options: .atomic)
        }
        return updated
    }

    /// The original preview-image-only fallback, unchanged, used when SceneArtExtractor finds
    /// nothing usable in the package at all.
    private static func applyPreview(to project: WEProject, in directory: URL) throws -> WEProject {
        let fm = FileManager.default
        let previewURL = directory.appending(path: project.preview)

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: previewURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SceneFallbackError.missingPreview
        }
        let attributes = try? fm.attributesOfItem(atPath: previewURL.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        guard size > 0 else {
            throw SceneFallbackError.missingPreview
        }
        guard let (thumbnail, pixelsWide, pixelsHigh) = ThumbnailDownsampler.downsampledThumbnail(at: previewURL),
              let thumbnailData = thumbnail.jpegData
        else {
            throw SceneFallbackError.unreadablePreview
        }

        // Same "preview.jpg" filename collision ImageImporter.commitImport already guards
        // against — if the scene's own preview file is literally named "preview.jpg", writing the
        // downsampled thumbnail to that same path below would overwrite the only full-resolution
        // copy of the image this fallback has to show.
        let filename: String
        if project.preview.lowercased() == "preview.jpg" {
            let ext = previewURL.pathExtension.isEmpty ? "jpg" : previewURL.pathExtension
            let renamed = "scene." + ext
            try fm.moveItem(at: previewURL, to: directory.appending(path: renamed))
            filename = renamed
        } else {
            filename = project.preview
        }

        var updated = project
        updated.type = "image"
        updated.file = filename
        updated.preview = "preview.jpg"
        updated.videoWidth = pixelsWide
        updated.videoHeight = pixelsHigh

        try thumbnailData.write(to: directory.appending(path: "preview.jpg"), options: .atomic)
        return updated
    }
}
