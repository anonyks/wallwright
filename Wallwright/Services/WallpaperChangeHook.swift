//
//  WallpaperChangeHook.swift
//  Wallwright
//
//  Optional user-provided script run after a wallpaper is applied, for people who want to wire
//  Wallwright into their own ricing setup (SketchyBar, Ghostty, etc.) without Wallwright needing to
//  know anything about those tools itself. Entirely opt-in: if the script isn't there, this is a
//  single cheap `isExecutableFile` check and nothing else happens — no logging, no directory
//  creation, no cost for the overwhelming majority of users who never touch this.
//

import Foundation

enum WallpaperChangeHook {
    private static let scriptPath = NSString(string: "~/.config/wallwright/on_change.sh").expandingTildeInPath

    /// Callers go through `DesktopUpdates`, which keeps calls in switch order. This queue was
    /// added when they ran on a concurrent queue, where two wallpaper-apply paths (confirmed:
    /// `AppDelegate`'s launch-time restore and `GlobalSettingsService.didCurrentWallpaperChange`'s
    /// reactive subscription both fire for the same wallpaper at startup, the latter delivering its
    /// current value immediately on subscribe) could call in genuinely concurrently. A bare
    /// `static var` debounce check would race exactly the way this codebase's own file-write races
    /// already did (see `LockScreenExtensionBridge.atomicCopy`'s doc comment) — serial, not
    /// concurrent, closes that instead of just making the race less likely.
    private static let queue = DispatchQueue(label: "com.wallwright.WallpaperChangeHook")
    private static var lastFilePath: String?

    /// Call from wherever a wallpaper actually gets applied — this does its own file-existence
    /// check up front, so calling it unconditionally on every wallpaper change is fine.
    ///
    /// The script receives `--file <path>`, followed by `--dominant-hex <#RRGGBB>`,
    /// `--accent-hex <#RRGGBB>` and `--is-dark <true|false>` for that same file. The color
    /// arguments are left out if the preview can't be read. `--file` stays first, so scripts that
    /// read it by position keep working. No `--screen` yet: this app has no per-display identity
    /// to pass.
    static func run(for wallpaper: WEWallpaper) {
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else { return }
        let fileURL = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)

        queue.async {
            guard fileURL.path != lastFilePath else { return }
            lastFilePath = fileURL.path

            let task = Process()
            task.executableURL = URL(fileURLWithPath: scriptPath)
            var arguments = ["--file", fileURL.path]
            if let palette = PaletteExporter.palette(for: wallpaper) {
                arguments += [
                    "--dominant-hex", palette.dominant, "--accent-hex", palette.accent,
                    "--is-dark", String(palette.isDark),
                ]
            }
            task.arguments = arguments
            // `nil` is `Process`'s own default and means INHERIT the parent's file handles, not
            // discard — actually swallowing the script's output (so it never ends up interleaved
            // in Wallwright's own logs) means handing it a real file handle on `/dev/null`.
            let devNull = FileHandle(forWritingAtPath: "/dev/null")
            task.standardOutput = devNull
            task.standardError = devNull

            do {
                try task.run()
            } catch {
                WWLog.settings.error("WallpaperChangeHook: failed to launch on_change.sh: \(error)")
                return
            }

            // Bounded the same way `firstFramePosterURL`'s decode wait is — a misbehaving user
            // script that never exits shouldn't be able to leak a process indefinitely. Waiting
            // right here on `queue` (serial) also means a second wallpaper change can't launch a
            // new instance of the script until this one has finished or been killed, rather than
            // letting multiple copies pile up.
            let deadline = DispatchTime.now() + 5
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                task.waitUntilExit()
                group.leave()
            }
            if group.wait(timeout: deadline) == .timedOut {
                WWLog.settings.notice("WallpaperChangeHook: on_change.sh exceeded 5s, terminating it")
                task.terminate()
            }
        }
    }
}
