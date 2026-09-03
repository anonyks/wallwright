import Foundation

extension FileManager {
    /// The dedicated directory for storing wallpaper packages.
    /// Located at `~/Library/Application Support/Wallwright/`, created automatically if missing.
    ///
    /// This intentionally never touches `~/Documents` — macOS gates programmatic access to the
    /// Documents folder behind a TCC permission prompt that doesn't reliably persist across
    /// ad-hoc-signed development rebuilds, so it re-asks on every launch. Even just *checking*
    /// whether a Documents-folder path exists is enough to trigger that prompt, so this code
    /// path avoids Documents entirely rather than trying to migrate away from it at runtime.
    var wallpapersDirectory: URL {
        let dir = urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wallwright")
        if !fileExists(atPath: dir.path) {
            try? createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// A safe, unique destination directory under `wallpapersDirectory` for `title` — every
    /// importer used to build this as a plain `wallpapersDirectory.appending(path: title)` and
    /// unconditionally `removeItem` whatever was already there before writing. `title` can be
    /// arbitrary text from a remote source (a YouTube/Steam Workshop item name, a user-edited
    /// field) with no filesystem safety applied to it at all: a "/" in it silently nested into a
    /// subdirectory (or failed the write outright) instead of just being a character in a folder
    /// name, and two entirely unrelated imports that happen to share a title (a real, reachable
    /// case — "Sunset" is not a rare video title) silently deleted whichever one already existed.
    /// Sanitizes filesystem-illegal characters and, if the resulting name is already taken by
    /// something else, appends a numeric suffix instead — never deletes an existing directory to
    /// make room, so nothing already in the library can be silently destroyed by an unrelated
    /// import sharing its name.
    func uniqueWallpaperDestination(forTitle title: String) -> URL {
        let sanitized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "Untitled" : sanitized

        var candidate = wallpapersDirectory.appending(path: base)
        var suffix = 2
        while fileExists(atPath: candidate.path) {
            candidate = wallpapersDirectory.appending(path: "\(base) \(suffix)")
            suffix += 1
        }
        return candidate
    }
}
