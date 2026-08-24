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
}
