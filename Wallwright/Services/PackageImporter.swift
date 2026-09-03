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
    static func preparePending(project: WEProject, directory: URL, sourceId: String? = nil) throws -> PendingPackageImport {
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
            sourceId: sourceId
        )
    }

    /// Reads project.json fresh off disk — used when a caller only has a bare directory (no
    /// already-parsed WEProject on hand).
    static func preparePending(at directory: URL, sourceId: String? = nil) throws -> PendingPackageImport {
        guard let data = try? Data(contentsOf: directory.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: data)
        else { throw PackageImportError.missingProjectFile }
        return try preparePending(project: project, directory: directory, sourceId: sourceId)
    }

    /// Copies the package into the wallpapers directory under the (possibly user-edited) title,
    /// rewriting project.json's title/tags/import-metadata fields on the copy — the source
    /// directory itself (e.g. Steam's own Workshop cache) is left untouched.
    @discardableResult
    static func commitImport(_ pending: PendingPackageImport, sourceProvider: String? = nil) -> Bool {
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
            project.sourceProvider = sourceProvider
            project.sourceId = pending.sourceId
            project.dateAdded = ISO8601DateFormatter().string(from: Date())
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
