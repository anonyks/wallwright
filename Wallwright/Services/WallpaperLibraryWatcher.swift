//
//  WallpaperLibraryWatcher.swift
//  Wallwright
//

import CoreServices
import Foundation

/// Watches `wallpapersDirectory` via FSEvents so adding, removing, or renaming a wallpaper folder
/// directly in Finder (not through the app's own import pipeline, which already posts
/// `VideoImporter.wallpaperLibraryDidChangeNotification` itself) is picked up without a relaunch.
/// Posts that same notification, so `ContentViewModel`'s existing debounced `refresh()` handles
/// both sources uniformly.
final class WallpaperLibraryWatcher {
    static let shared = WallpaperLibraryWatcher()

    private var stream: FSEventStreamRef?

    private init() {}

    func start() {
        guard stream == nil else { return }
        let path = FileManager.default.wallpapersDirectory.path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WallpaperLibraryWatcher>.fromOpaque(info)
                .takeUnretainedValue()
                .handleEvent()
        }

        // kFSEventStreamCreateFlagIgnoreSelf skips events this process itself triggers (every
        // import, project.json rewrite, and preview.jpg write already posts the notification
        // directly at its own call site) — this stream only needs to catch changes made outside
        // the app, i.e. in Finder. 1.0s latency coalesces a burst of file writes (e.g. one import
        // touching several files) into a single callback.
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)
        ) else { return }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        FSEventStreamStart(newStream)
    }

    private func handleEvent() {
        WWLog.importing.notice("WallpaperLibraryWatcher: detected external change to wallpapers directory, triggering refresh")
        VideoImporter.notifyLibraryChanged()
    }
}
