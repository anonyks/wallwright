//
//  LockScreenExtensionBridge.swift
//  Wallwright
//
//  The main-app side of the new ExtensionKit lock-screen path — selects
//  WallwrightLockScreenExtension the same way AerialsInjector.swift already selects
//  com.apple.wallpaper.choice.aerials: write Store/Index.plist, then restart WallpaperAgent so it
//  picks up the new selection. The actual content handoff goes through LockScreenExchangeConfig
//  (shared with the extension target) instead of the aerials manifest/binary-plist mechanism.
//
//  Proven live end to end (2026-10-28): a manual out-of-band invocation produced a clean
//  acquire/snapshot/update/export round trip against the real WallpaperAgent (no errors, nothing
//  crashed), and the duck-video test wallpaper used for that test played live, muted, on the real
//  lock screen. Wired into the real call sites below as of the same date — `AerialsInjector` is
//  left fully intact and still called first at each site (same video-copy/screensaver-module/
//  health-monitoring side effects as before); this call is added right after it, so its own
//  `Store/Index.plist` write (and restart) happens last and wins. Real runtime-failure fallback
//  (detecting a private-ABI mismatch on a future OS update and reverting to `AerialsInjector`
//  alone) isn't built yet — that needs `LockScreenExtensionDiagnostics`, not yet written — so for
//  now this mechanism is simply trusted once the extension is discovered at all.
//

import AVFoundation
import AppKit

final class LockScreenExtensionBridge {
    static let shared = LockScreenExtensionBridge()

    private let providerID = "com.wallwright.Wallwright.LockScreenExtension"
    private let storePath = NSString(
        string: "~/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
    ).expandingTildeInPath
    private let imageFileName = "lock-screen.jpg"
    private let videoFileName = "lock-screen.mov"

    /// The wallpaper last successfully handed to `publish(wallpaper:)` — lets `republishCurrent()`
    /// re-assert our selection without the caller needing to carry a `WEWallpaper` around. Exists
    /// because `AerialsInjector.prewarmForNextActivation()`/its internal 5-minute health-check
    /// timer both call `AerialsInjector.inject()` directly and restart WallpaperAgent on their own
    /// schedule, with no corresponding call into this bridge — confirmed live (2026-10-28): the
    /// first unlock after launch silently reverted `Store/Index.plist` back to the old aerials
    /// provider, since nothing re-published ours afterward. Every real call site that already
    /// calls `AerialsInjector.shared.prewarmForNextActivation()` now also calls
    /// `republishCurrent()` right alongside it (`StatusBar.swift`, `LockScreenSync.swift`).
    private var lastWallpaper: WEWallpaper?

    /// The asset URLs from the last publish that actually went through — lets `publish(imageURL:
    /// videoURL:)` skip its own copy+Store-write+restart entirely when nothing would change.
    /// Added after confirmed-live evidence (2026-10-28, via the extension's own file log) that the
    /// underlying acquire/frame-delivery mechanism was succeeding instantly on every single call —
    /// the visible "static" symptom wasn't a delivery failure at all, it was WallpaperAgent being
    /// killed and relaunched every few seconds (once from `AerialsInjector`'s own prewarm restart,
    /// again 2.5s later from this bridge's own unconditional restart on every `republishCurrent()`
    /// call), which never let playback run long enough to look alive. Restarting only when the
    /// content actually changed, or when something else has taken the selection away from us,
    /// fixes that without weakening the actual reclaim behavior `republishCurrent()` exists for.
    private var lastPublishedImageURL: URL?
    private var lastPublishedVideoURL: URL?

    private init() {}

    /// Call-site convenience matching `AerialsInjector.inject(videoURL:name:)`'s own shape — the
    /// video's own first frame as the poster (see `firstFramePosterURL`), falling back to the
    /// wallpaper's existing preview thumbnail if that decode fails for any reason.
    func publish(wallpaper: WEWallpaper) {
        lastWallpaper = wallpaper
        let videoURL = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
        let posterURL =
            firstFramePosterURL(for: videoURL, in: wallpaper.wallpaperDirectory)
            ?? wallpaper.wallpaperDirectory.appending(path: wallpaper.project.preview)
        publish(imageURL: posterURL, videoURL: videoURL)
    }

    /// Generates a poster from the video's own actual first frame (time zero), not
    /// `project.preview` — that field is a representative thumbnail picked at import time, often
    /// from partway through the clip, which made the lock screen look like it was "resuming
    /// mid-playback" for the brief instant between the poster showing and the first real decoded
    /// video frame arriving (reported live, 2026-10-29). Written to a STABLE path, not a fresh temp
    /// file per call, so repeated publishes of the same wallpaper still compare equal in
    /// `publish(imageURL:videoURL:)`'s own already-selected debounce check. Same
    /// `AVAssetImageGenerator` configuration as `VideoImporter.regenerateThumbnail(for:atSeconds:)`'s
    /// own exact-frame capture. Returns nil (caller falls back to `project.preview`) on any failure
    /// — a slightly-wrong poster frame is a cosmetic issue, not worth failing the whole publish over.
    private func firstFramePosterURL(for videoURL: URL, in directory: URL) -> URL? {
        let posterURL = directory.appending(path: "lock-screen-poster.jpg")
        // Reuse a previously-generated poster rather than re-decoding frame zero on every single
        // publish (every unlock/screensaver-stop that re-asserts the same unchanged wallpaper) —
        // the file is keyed to this wallpaper's own directory, so a genuinely different video
        // lands in a different directory and gets its own fresh poster.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: posterURL.path),
            let size = attributes[.size] as? Int, size > 0
        {
            return posterURL
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(
            width: ThumbnailDownsampler.maxDimension, height: ThumbnailDownsampler.maxDimension
        )

        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: CGImage?
        generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, _ in
            resultImage = cgImage
            semaphore.signal()
        }
        // Bounded, not indefinite — an unreadable/corrupt video would otherwise hang this queue's
        // thread forever. 3s is generous for a single-frame decode; this only runs once per
        // wallpaper directory thanks to the cache check above, not on every publish.
        guard semaphore.wait(timeout: .now() + 3) == .success else {
            WWLog.aerial.error("LockScreenExtensionBridge: timed out generating first-frame poster")
            return nil
        }

        guard let cgImage = resultImage, let data = NSImage(cgImage: cgImage, size: .zero).jpegData else {
            return nil
        }
        do {
            try data.write(to: posterURL, options: .atomic)
            return posterURL
        } catch {
            WWLog.aerial.error("LockScreenExtensionBridge: failed to write first-frame poster: \(error)")
            return nil
        }
    }

    /// Re-publishes whatever `publish(wallpaper:)` last set, without needing the caller to carry a
    /// `WEWallpaper` reference — see `lastWallpaper`'s own doc comment for why this exists. A no-op
    /// if nothing has been published yet this session (current wallpaper isn't a video, or hasn't
    /// been injected yet). Self-debounces via `publish(imageURL:videoURL:)`'s own already-selected
    /// check, so callers no longer need to worry about racing `AerialsInjector` — see each real
    /// call site's own comment for the history there.
    func republishCurrent() {
        guard let lastWallpaper else { return }
        publish(wallpaper: lastWallpaper)
    }

    /// Copies `imageURL` (M0, or M1's poster frame) and, when present, `videoURL` (M1) into the
    /// shared exchange directory, publishes a new `LockScreenExchangeConfig`, posts the Darwin
    /// "changed" notification (so an already-running extension re-reads it immediately rather
    /// than waiting for the next `acquire`), then selects this extension in `Store/Index.plist`
    /// and restarts WallpaperAgent. Mirrors AerialsInjector.inject()'s own shape and its "always
    /// restart, even if content is unchanged" reasoning (see that file's own doc comment).
    func publish(imageURL: URL, videoURL: URL? = nil) {
        if imageURL == lastPublishedImageURL, videoURL == lastPublishedVideoURL, isCurrentlySelected() {
            WWLog.aerial.notice("LockScreenExtensionBridge: already selected with unchanged content, skipping restart")
            return
        }
        lastPublishedImageURL = imageURL
        lastPublishedVideoURL = videoURL

        let exchangeDir = LockScreenExchangeConfig.exchangeDirectory
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: exchangeDir, withIntermediateDirectories: true)
            let destImageURL = exchangeDir.appendingPathComponent(imageFileName)
            if fm.fileExists(atPath: destImageURL.path) { try fm.removeItem(at: destImageURL) }
            try fm.copyItem(at: imageURL, to: destImageURL)

            let destVideoURL = exchangeDir.appendingPathComponent(videoFileName)
            if fm.fileExists(atPath: destVideoURL.path) { try fm.removeItem(at: destVideoURL) }
            if let videoURL { try fm.copyItem(at: videoURL, to: destVideoURL) }
        } catch {
            WWLog.aerial.error("LockScreenExtensionBridge: failed to copy lock-screen asset: \(error)")
            return
        }

        let config = LockScreenExchangeConfig(
            imageFileName: imageFileName, videoFileName: videoURL != nil ? videoFileName : nil
        )
        guard let data = try? JSONEncoder().encode(config) else {
            WWLog.aerial.error("LockScreenExtensionBridge: failed to encode configuration.json")
            return
        }
        let configURL = exchangeDir.appendingPathComponent(LockScreenExchangeConfig.fileName)
        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            WWLog.aerial.error("LockScreenExtensionBridge: failed to write configuration.json: \(error)")
            return
        }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(LockScreenExchangeConfig.changedNotification as CFString), nil, nil, true
        )

        guard updateWallpaperStore() else {
            WWLog.aerial.error("LockScreenExtensionBridge: failed to update wallpaper store")
            return
        }
        configureScreensaverForWallwright()
        WWLog.aerial.notice("LockScreenExtensionBridge: published revision=\(config.revision), selecting extension")
        restartWallpaperAgent()
    }

    /// `AerialsInjector.inject()` (still called first at the two real wallpaper-change call sites,
    /// for its own file-copy/health-monitoring side effects) always points the classic
    /// `com.apple.screensaver` module at Apple's own `WallpaperAerialsExtension` — which forces the
    /// screensaver phase through that (broken, same `mediaanalysisd` bug documented throughout
    /// `AerialsInjector.swift`) extension. Confirmed live (2026-10-29), via the extension's own
    /// diagnostic log, that the idle/lock phase and the screensaver phase are two genuinely
    /// separate request paths — `acquire` was never once called during an actual screensaver
    /// activation, only during real lock events — so merely clearing the override and hoping
    /// "Automatic" picks up our content on its own (an earlier, disproven attempt) doesn't work.
    /// What DOES work, confirmed live: pointing the classic module directly at OUR OWN `.appex`,
    /// the same way `AerialsInjector` points it at Apple's — the classic screen-saver loader has
    /// special bridging for `com.apple.wallpaper`-protocol extensions specifically (confirmed:
    /// `WallpaperAerialsExtension.appex`'s own Info.plist declares only that one extension point,
    /// no separate classic-screensaver declaration, yet AerialsInjector's own trick has always
    /// worked). Deliberately does NOT do its own save/restore of the prior module — AerialsInjector
    /// already did that (and remembers the TRUE pre-session original) earlier in this same call,
    /// so `remove()` leaves the screensaver module alone entirely and lets AerialsInjector's own
    /// restore (which runs right before it at every real call site) be the single source of truth.
    private func configureScreensaverForWallwright() {
        let extensionPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/WallwrightLockScreenExtension.appex").path
        let currentPath =
            (CFPreferencesCopyValue(
                "moduleDict" as CFString, "com.apple.screensaver" as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
            ) as? [String: String])?["path"] ?? ""
        guard currentPath != extensionPath else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = [
            "-currentHost", "write", "com.apple.screensaver",
            "moduleDict", "-dict",
            "moduleName", "WallwrightLockScreenExtension",
            "path", extensionPath,
            "type", "0",
        ]
        try? task.run()
        task.waitUntilExit()
    }

    /// Same slot-walking shape as `AerialsInjector.updateWallpaperStore(assetID:)`, writing this
    /// extension's bundle ID as `Provider` instead of `com.apple.wallpaper.choice.aerials`.
    ///
    /// `Configuration` IS required, even though this extension doesn't read its selection out of
    /// it (it reads `configuration.json` from the shared exchange directory instead) — confirmed
    /// live (2026-10-28): omitting the key entirely makes WallpaperAgent's own plist decoder throw
    /// `DecodingError.keyNotFound` on the WHOLE Index.plist, which makes it silently fall back to
    /// whatever was selected before rather than erroring loudly. An empty serialized dict
    /// satisfies the decoder.
    /// Cheap existing-state check `publish(imageURL:videoURL:)` uses to decide whether a restart
    /// is actually necessary — reads `SystemDefault` only (every slot this bridge writes is set to
    /// the same value in one call, so checking one is representative of all of them).
    private func isCurrentlySelected() -> Bool {
        let storeURL = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: storeURL),
            let store = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
            let systemDefault = store["SystemDefault"] as? [String: Any],
            let linked = systemDefault["Linked"] as? [String: Any],
            let content = linked["Content"] as? [String: Any],
            let choices = content["Choices"] as? [[String: Any]],
            let first = choices.first
        else { return false }
        return (first["Provider"] as? String) == providerID
    }

    private func updateWallpaperStore() -> Bool {
        let storeURL = URL(fileURLWithPath: storePath)
        let storeDir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: storeDir, withIntermediateDirectories: true)

        var store: [String: Any]
        if let data = try? Data(contentsOf: storeURL),
            let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: .mutableContainersAndLeaves, format: nil
            ) as? [String: Any]
        {
            store = parsed
        } else {
            store = [:]
        }

        guard
            let emptyConfig = try? PropertyListSerialization.data(
                fromPropertyList: [String: Any](), format: .binary, options: 0
            )
        else { return false }
        let choice: [String: Any] = ["Provider": providerID, "Files": [] as [Any], "Configuration": emptyConfig]
        let content: [String: Any] = ["Choices": [choice]]
        let linked: [String: Any] = ["Content": content, "LastSet": Date(), "LastUse": Date()]
        let entry: [String: Any] = ["Type": "linked", "Linked": linked]

        store["SystemDefault"] = entry
        store["AllSpacesAndDisplays"] = entry
        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys { displays[key] = entry }
            store["Displays"] = displays
        }
        // Only ever replace `Default` and each individual `Displays.<id>` entry within a space —
        // never the `Displays` dict itself (confirmed live, 2026-10-28: overwriting it wholesale
        // produced `DecodingError.typeMismatch` on WallpaperAgent's next read, since `Displays` is
        // itself a dict of per-display entries, not a slot that can directly hold a `Linked`
        // entry). Mirrors `AerialsInjector.updateWallpaperStore(assetID:)`'s own proven-safe shape
        // exactly.
        if var spaces = store["Spaces"] as? [String: Any] {
            for spaceKey in spaces.keys {
                if var space = spaces[spaceKey] as? [String: Any] {
                    if space["Default"] != nil { space["Default"] = entry }
                    if var spaceDisplays = space["Displays"] as? [String: Any] {
                        for dKey in spaceDisplays.keys { spaceDisplays[dKey] = entry }
                        space["Displays"] = spaceDisplays
                    }
                    spaces[spaceKey] = space
                }
            }
            store["Spaces"] = spaces
        }

        guard let newData = try? PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        else { return false }
        do {
            let tmpURL = URL(fileURLWithPath: storePath + ".tmp")
            try newData.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
            return true
        } catch {
            WWLog.aerial.error("LockScreenExtensionBridge: failed to write wallpaper store: \(error)")
            return false
        }
    }

    /// Clears this extension's selection from the Store slots `updateWallpaperStore()` writes, if
    /// it's currently selected there, then restarts WallpaperAgent — same shape and reasoning as
    /// `AerialsInjector.remove()`'s own cleanup (that file's own doc comment: leaving a stale
    /// registration in place with no process left running to maintain it produces
    /// stale/frozen/blank wallpaper state). A no-op (no restart) when this extension isn't
    /// currently selected, so switching between two non-video wallpapers in a row doesn't restart
    /// WallpaperAgent for nothing.
    func remove() {
        lastWallpaper = nil
        lastPublishedImageURL = nil
        lastPublishedVideoURL = nil
        let storeURL = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: storeURL),
            var store = try? PropertyListSerialization.propertyList(
                from: data, options: .mutableContainersAndLeaves, format: nil
            ) as? [String: Any]
        else { return }

        guard Self.clearOwnSlots(in: &store, providerID: providerID) else { return }

        guard let newData = try? PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        else { return }
        do {
            let tmpURL = URL(fileURLWithPath: storePath + ".tmp")
            try newData.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
            WWLog.aerial.notice("LockScreenExtensionBridge: cleared own selection")
            restartWallpaperAgent()
        } catch {
            WWLog.aerial.error("LockScreenExtensionBridge: failed to clear wallpaper store: \(error)")
        }
    }

    /// Same recursive slot-walk as `AerialsInjector.clearStaleAerialSlots(in:assetID:)`, keyed on
    /// this extension's `Provider` id instead of an aerials assetID.
    @discardableResult
    private static func clearOwnSlots(in dict: inout [String: Any], providerID: String) -> Bool {
        var changed = false
        for key in Array(dict.keys) {
            guard var nested = dict[key] as? [String: Any] else { continue }
            if isOwnSlot(nested, providerID: providerID) {
                var content = nested["Content"] as? [String: Any] ?? [:]
                content["Choices"] = [] as [Any]
                nested["Content"] = content
                dict[key] = nested
                changed = true
                continue
            }
            if clearOwnSlots(in: &nested, providerID: providerID) {
                dict[key] = nested
                changed = true
            }
        }
        return changed
    }

    private static func isOwnSlot(_ slot: [String: Any], providerID: String) -> Bool {
        guard let content = slot["Content"] as? [String: Any],
            let choices = content["Choices"] as? [[String: Any]],
            let first = choices.first
        else { return false }
        return (first["Provider"] as? String) == providerID
    }

    private func restartWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
        task.waitUntilExit()
    }
}
