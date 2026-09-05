import Foundation

enum ZipImporter {
    /// Extracts a zip file and imports any wallpaper folders (containing project.json) into the
    /// library. Returns the number of wallpapers successfully imported.
    @discardableResult
    static func importZip(at zipURL: URL) async -> Int {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appending(path: UUID().uuidString)

        defer { try? fm.removeItem(at: tempDir) }

        // Extract zip using macOS built-in ditto
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, tempDir.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("ZipImporter: ditto failed: \(error)")
            return 0
        }
        guard process.terminationStatus == 0 else {
            print("ZipImporter: ditto exited with status \(process.terminationStatus)")
            return 0
        }

        // Find wallpaper folders inside extracted content
        let wallpaperURLs = findWallpaperFolders(in: tempDir)
        var imported = 0

        for url in wallpaperURLs {
            // Was a raw `FileManager.copyItem` straight to `uniqueWallpaperDestination` — unlike
            // every other package import path (Steam Workshop, drag-and-drop onto the library
            // window), this skipped `PackageImporter` entirely: no `VideoTranscoder
            // .ensureCompatible` check (a zipped package with a VP9/AV1/MKV video — fine on
            // Windows, none of it decodable by AVFoundation — imported "successfully" into an
            // unplayable black wallpaper), and no metadata probing (`packageSizeBytes` staying nil
            // forever meant every future sort/impact-badge render fell back to a live recursive
            // directory walk for it). `preparePending` already handles the unsupported-type check
            // and the title/directory-name fallback this used to do inline.
            guard let pending = try? PackageImporter.preparePending(at: url) else {
                print("ZipImporter: skipping \(url.lastPathComponent) — couldn't prepare (unsupported type, missing project.json, or no preview image)")
                continue
            }
            if await PackageImporter.commitImport(pending) {
                imported += 1
            } else {
                print("ZipImporter: commit failed for \(url.lastPathComponent)")
            }
        }

        // No separate `notifyLibraryChanged()` needed here — `PackageImporter.commitImport`
        // already posts it per item, and `ContentViewModel`'s subscriber already debounces a burst
        // of these into one refresh (see its own doc comment), same as importing several zips does.
        return imported
    }

    /// Recursively searches for directories containing project.json, up to 3 levels deep.
    private static func findWallpaperFolders(in directory: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        // Check if this directory itself is a wallpaper
        if fm.fileExists(atPath: directory.appending(path: "project.json").path) {
            return [directory]
        }

        // Check immediate children
        guard let children = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if fm.fileExists(atPath: child.appending(path: "project.json").path) {
                results.append(child)
            } else {
                // One more level deep (zip may have a wrapper folder)
                if let grandchildren = try? fm.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles
                ) {
                    for grandchild in grandchildren {
                        var isSubDir: ObjCBool = false
                        if fm.fileExists(atPath: grandchild.path, isDirectory: &isSubDir),
                           isSubDir.boolValue,
                           fm.fileExists(atPath: grandchild.appending(path: "project.json").path) {
                            results.append(grandchild)
                        }
                    }
                }
            }
        }

        return results
    }
}
