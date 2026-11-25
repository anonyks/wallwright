//
//  CommandListener.swift
//  Wallwright
//
//  Lets a terminal or script control the app via a named pipe (substitute your own UID for
//  `501` — `id -u`):
//    echo "pause"             > /tmp/wallwright-501.pipe
//    echo "resume"            > /tmp/wallwright-501.pipe
//    echo "volume 50"         > /tmp/wallwright-501.pipe
//    echo "next"              > /tmp/wallwright-501.pipe
//    echo "prev"              > /tmp/wallwright-501.pipe
//    echo "pin"               > /tmp/wallwright-501.pipe
//    echo "clearcache"        > /tmp/wallwright-501.pipe
//    echo "status"            > /tmp/wallwright-501.pipe   # writes /tmp/wallwright-501-status.json
//    echo "apply <title>"     > /tmp/wallwright-501.pipe   # case-insensitive substring match, first hit wins
//    echo "import <path>"     > /tmp/wallwright-501.pipe   # adds a local file to the library (does not apply it)
//    echo "quit"              > /tmp/wallwright-501.pipe
//
//  Adapted from LivePaper (MIT License, Copyright (c) 2026 Raunak Gupta)
//  https://github.com/Raunik2/LivePaper
//

import AppKit

/// Written by the `status` command — the pipe itself is write-only from the caller's side (a
/// script can `echo` into it but has nothing to read a reply back from), so this is the only way
/// a script can get anything out. Same main-screen-only scoping as `CommandListener`'s own `pin`
/// handler, for the same reason: a CLI caller has no UI context to have selected a specific screen.
private struct WallwrightStatus: Codable {
    var title: String
    var type: String
    var file: String
    var isPaused: Bool
    var volumePercent: Int
}

final class CommandListener {
    static let shared = CommandListener()

    // UID-scoped, not a bare `/tmp/wallwright.pipe` — `/tmp` has the sticky bit set, so only the
    // file's owner (or root) can `unlink`/replace it. Under Fast User Switching, a second user
    // launching Wallwright while the first user's instance is still running (and still owns the
    // existing FIFO, mode 0600) would hit `unlink`/`mkfifo`/`open` all failing on permissions —
    // `listen()`'s error path retries every 0.5s forever with no way to ever succeed, since
    // nothing about the failure is transient. Scoping the path per-user means two users' instances
    // never contend for the same node at all.
    private let path = "/tmp/wallwright-\(getuid()).pipe"
    // Same UID-scoping reasoning as `path` above — a predictable sibling name next to the pipe,
    // not under a user-writable directory a script would need to create first.
    private let statusPath = "/tmp/wallwright-\(getuid())-status.json"
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        unlink(path)
        // 0600, not 0644 — this pipe's whole purpose is accepting commands, so it shouldn't be
        // world-readable to every other local account on a shared Mac (which 644 was: nobody but
        // the owner could write to it, but any user could still watch commands go by).
        mkfifo(path, 0o600)
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.listen() }
    }

    /// `String(contentsOfFile:)` doesn't give a true blocking FIFO read — confirmed live
    /// (2026-08-09) via `sample`: this thread spent 2550 of 2554 profiled samples sitting in
    /// `Thread.sleep(forTimeInterval:)`, meaning the read was failing/returning immediately and
    /// this was busy-retrying on a 0.5s cycle for the entire life of the app. A cheap wakeup twice
    /// a second still means the CPU never reaches its deepest idle state — exactly what Activity
    /// Monitor's Energy Impact penalizes, independent of raw %CPU looking like ~0.
    ///
    /// Opening the FIFO with the raw POSIX `open()`/`read()` calls instead gives the behavior a
    /// named pipe is actually meant to have: `open` blocks until a writer connects, `read` blocks
    /// until data arrives or the writer closes — genuine event-driven waiting, zero wakeups, no
    /// polling, until a command actually shows up.
    private func listen() {
        while true {
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else {
                // The FIFO node itself is missing or unopenable — recreate it and wait briefly
                // before retrying to prevent an unthrottled 100% CPU busy-spin loop.
                unlink(path)
                mkfifo(path, 0o600)
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            // Every real command in the header comment above is a couple of words — a writer that
            // never closes (`cat /dev/zero > pipe`, a runaway script) would otherwise make `data`
            // grow without bound for as long as it keeps streaming, since this loop only stops on
            // EOF/error. 64KB is generous for any legitimate command while still capping the worst
            // case; once past it, the excess is simply not read into memory (the fd is still
            // drained below so `read` doesn't block a well-behaved writer forever).
            let maxCommandBytes = 65536
            readLoop: while true {
                let bytesRead = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                switch bytesRead {
                case ..<0, 0: break readLoop // error, or EOF once the writer closes
                default:
                    if data.count < maxCommandBytes {
                        data.append(contentsOf: buffer[0..<bytesRead])
                    }
                }
            }
            close(fd)

            if let contents = String(data: data, encoding: .utf8) {
                // One write to the pipe can carry multiple newline-separated commands (e.g. a
                // script doing `printf "pause\nvolume 50\n" > pipe` in one shot) — trimming only
                // the outer whitespace and handling the whole blob as a single command left an
                // embedded "\n" inside `parts.first`, which matched none of the switch's cases and
                // silently dropped every command in the batch. Splitting first means each line
                // gets its own, independent dispatch to `handle`.
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !command.isEmpty else { continue }
                    DispatchQueue.main.async { [weak self] in self?.handle(command) }
                }
            }
        }
    }

    private func handle(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1)
        switch parts.first {
        case "pause":
            AppDelegate.shared.wallpaperViewModel.isPausedByUser = true
            AppDelegate.shared.pause()
        case "resume", "play":
            AppDelegate.shared.wallpaperViewModel.isPausedByUser = false
            AppDelegate.shared.resume()
        case "mute": AppDelegate.shared.mute()
        case "unmute": AppDelegate.shared.unmute()
        case "volume":
            if parts.count > 1, let value = Float(parts[1]) {
                AppDelegate.shared.wallpaperViewModel.playVolume = max(0, min(1, value / 100))
            }
        case "next", "skip": AppDelegate.shared.skipToNextPlaylistItem()
        case "prev", "previous": AppDelegate.shared.skipToPreviousPlaylistItem()
        case "pin", "togglepin":
            // `wallpaperViewModel.currentWallpaper` is the wallpaper for whichever screen is
            // selected in the Display Settings UI, not necessarily what's actually showing on
            // the main display, and a CLI caller has no UI context to have selected anything.
            // The main screen's wallpaper is the only sensible target without one.
            let mainId = WallpaperViewModel.mainScreenId()
            AppDelegate.shared.contentViewModel.togglePinned(AppDelegate.shared.wallpaperViewModel.wallpaper(for: mainId))
        case "clearcache":
            // Same eviction `MainWindowController.windowWillClose` already calls automatically —
            // exposed here too so it can be triggered (and its effect measured) without actually
            // opening/closing the library window, e.g. from a script or while diagnosing memory
            // footprint live.
            ThumbnailImage.clearCache()
        case "status":
            writeStatus()
        case "apply":
            if parts.count > 1 {
                applyWallpaper(matching: String(parts[1]))
            }
        case "import":
            if parts.count > 1 {
                importFile(at: String(parts[1]))
            }
        case "quit": NSApplication.shared.terminate(nil)
        case "toggleclock":
            AppDelegate.shared.globalSettingsViewModel.settings.showClockOverlay.toggle()
        case "clockalignment":
            if parts.count > 1, let alignment = GSClockTextAlignment(rawValue: String(parts[1])) {
                AppDelegate.shared.globalSettingsViewModel.settings.clockTextAlignment = alignment
            }
        default: break
        }
    }

    /// Applies the first library wallpaper whose title contains `query` (case-insensitive) to the
    /// main screen — same main-screen-only scoping as `pin`/`status` above, for the same reason a
    /// CLI caller has no UI context to have selected a specific screen. Reuses the exact mechanism
    /// clicking a library tile already triggers (`WallpaperViewModel.setWallpaper(_:for:)` — see
    /// `ExplorerItem`'s own tap handler), not `nextCurrentWallpaper`, which depends on whatever
    /// screen happens to be selected in the Display Settings UI right now — a CLI call shouldn't
    /// depend on UI state nobody can see. Silently does nothing on no match, matching every other
    /// handler in this file's own "no corresponding command, no error channel to report one on" posture.
    private func applyWallpaper(matching query: String) {
        let needle = query.lowercased()
        guard let match = AppDelegate.shared.contentViewModel.wallpapers.first(where: {
            $0.project.title.lowercased().contains(needle)
        }) else { return }
        AppDelegate.shared.wallpaperViewModel.setWallpaper(match, for: WallpaperViewModel.mainScreenId())
    }

    /// Adds a local file already on disk to the library — does NOT also apply it, deliberately:
    /// unlike `apply` above (which only ever reassigns an existing, already-validated wallpaper),
    /// an import can fail for real reasons (corrupt file, unsupported codec, transcode failure),
    /// and a script that wants both can just send `apply <title>` right after this succeeds. Reuses
    /// `VideoImporter.importVideoFile`/`ImageImporter.importImageFile` wholesale — the exact same
    /// direct-commit calls the Inbox's own downloaded-file path already uses, not the
    /// prepare-then-review flow the drag-and-drop UI uses, since there's no UI here to review
    /// anything in. `sourceProvider: "cli"` so an imported item's origin is visible in its own
    /// `project.json` the same way "inbox"/"motionbgs"/etc. already are for theirs.
    private func importFile(at pathString: String) {
        let path = (pathString as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ImageImporter.importableExtensions.contains(ext) {
            let success = ImageImporter.importImageFile(at: url, sourceProvider: "cli")
            WWLog.importing.notice("CommandListener: import (image) \(success ? "succeeded" : "failed", privacy: .public) for \(path, privacy: .public)")
        } else if VideoImporter.importableExtensions.contains(ext) {
            VideoImporter.importVideoFile(at: url, sourceProvider: "cli") { success in
                WWLog.importing.notice("CommandListener: import (video) \(success ? "succeeded" : "failed", privacy: .public) for \(path, privacy: .public)")
            }
        } else {
            WWLog.importing.notice("CommandListener: import — unsupported extension \(ext, privacy: .public) for \(path, privacy: .public)")
        }
    }

    private func writeStatus() {
        let wallpaperViewModel = AppDelegate.shared.wallpaperViewModel
        let wallpaper = wallpaperViewModel.wallpaper(for: WallpaperViewModel.mainScreenId())
        let status = WallwrightStatus(
            title: wallpaper.project.title,
            type: wallpaper.project.type,
            file: wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file).path,
            isPaused: wallpaperViewModel.playRate == 0,
            volumePercent: Int((wallpaperViewModel.playVolume * 100).rounded())
        )
        guard let data = try? JSONEncoder().encode(status) else { return }
        // Atomic — a script polling this file (rather than only reacting right after sending
        // `status`) should never be able to read a half-written file.
        try? data.write(to: URL(fileURLWithPath: statusPath), options: .atomic)
        // `Data.write` creates the file at the umask's default mode (commonly world-readable),
        // not `path`'s own deliberate 0600 — this file carries the same kind of information the
        // pipe above was scoped per-user to protect (the current wallpaper's title and full file
        // path), so it gets the same posture. Set after writing, not via a creation attribute,
        // since `.atomic` writes to a temp file and renames it into place, which would otherwise
        // carry whatever mode that temp file got instead.
        chmod(statusPath, 0o600)
    }
}
