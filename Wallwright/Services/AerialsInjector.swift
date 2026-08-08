//
//  AerialsInjector.swift
//  Wallwright
//
//  Registers the current video wallpaper as a native macOS "aerial" so it plays on the desktop,
//  lock screen, and screensaver simultaneously — all three surfaces read from the same Apple
//  aerials system, so once a video is registered there they stay in sync automatically.
//
//  There is no public API for this. macOS stores aerials as a JSON manifest plus a binary plist
//  "wallpaper store", both undocumented and unversioned — this writes those files directly in the
//  same shape WallpaperAgent already produces for Apple's own aerials. It can break on any macOS
//  update; if it does, the worst case is the injected entry silently stops appearing (desktop
//  wallpaper set via NSWorkspace is untouched, since that's a separate, stable, public API).
//
//  Adapted from LivePaper (MIT License, Copyright (c) 2026 Raunak Gupta)
//  https://github.com/Raunik2/LivePaper
//

import AppKit
import AVFoundation

final class AerialsInjector {
    static let shared = AerialsInjector()

    private let aerialsAssetIDKey = "AerialsAssetID"

    private let videosDir = NSString(string: "~/Library/Application Support/com.apple.wallpaper/aerials/videos").expandingTildeInPath
    private let thumbsDir = NSString(string: "~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails").expandingTildeInPath
    private let entriesPath = NSString(string: "~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json").expandingTildeInPath
    private let storePath = NSString(string: "~/Library/Application Support/com.apple.wallpaper/Store/Index.plist").expandingTildeInPath

    private let categoryID = "WW000000-0000-4000-8000-000000000001"
    private let subcategoryID = "WW000000-0000-4000-8000-000000000002"

    private var aerialsAssetID: String? {
        get { UserDefaults.standard.string(forKey: aerialsAssetIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: aerialsAssetIDKey) }
    }

    /// The SOURCE file's byte size at the time it was last injected — deliberately not inferred by
    /// comparing against the destination `.mov`'s size, since `preparedVideoURL(for:)` below can
    /// write a transcoded/looped file there that's a different size than the source even when the
    /// source itself hasn't changed. Comparing against a persisted source size instead keeps change
    /// detection correct regardless of what actually landed at `destPath`.
    private var lastInjectedSourceSize: Int? {
        get { UserDefaults.standard.object(forKey: "AerialsLastSourceSize") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "AerialsLastSourceSize") }
    }

    private var lastVideoURL: URL?
    private var lastVideoName: String?
    private var healthCheckTimer: Timer?

    /// Periodically verifies the injected aerial is still intact — a macOS update, a WallpaperAgent
    /// cache reset, or the user clearing app caches can silently wipe it. Re-injects without an
    /// agent restart when possible, so recovery doesn't cause a visible flicker.
    ///
    /// Private now — `inject()`/`remove()` own this timer's lifecycle directly (start when there's
    /// actually an aerial to watch, stop when there isn't), since there's nothing for it to check
    /// otherwise (`checkHealth()` already no-ops without `lastVideoURL`/`lastVideoName`, but the
    /// timer itself waking the process every 5 minutes for the app's entire lifetime — even for
    /// someone who's never once used a video wallpaper — was needless).
    private func startHealthMonitoring() {
        guard healthCheckTimer == nil else { return }
        // 5 minutes, not 2 — this only recovers a *cosmetic* lock/idle-screen registration, not
        // anything the user is actively watching for. A few extra minutes before self-healing is
        // imperceptible, so it's not worth checking this often.
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        healthCheckTimer?.tolerance = 60
    }

    private func stopHealthMonitoring() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    /// Called once at launch — resumes monitoring immediately if a valid aerial registration is
    /// already persisted from a previous session, rather than waiting for the next `inject()` call
    /// (which might not happen this session at all if the user just keeps using the same video).
    func resumeHealthMonitoringIfNeeded() {
        guard aerialsAssetID != nil else { return }
        startHealthMonitoring()
    }

    private func checkHealth() {
        guard let videoURL = lastVideoURL, let name = lastVideoName else { return }
        guard !isInjectionHealthy() else { return }
        print("AerialsInjector: health check failed — re-injecting")
        inject(videoURL: videoURL, name: name)
    }

    /// Forces a fresh WallpaperAgent restart to pre-warm for the *next* lock/screensaver
    /// activation — call this once things return to normal desktop use (unlock, screensaver
    /// stop), not at the moment of activation itself.
    ///
    /// Confirmed by direct inspection: the on-disk manifest, video file, and category entry are
    /// all structurally valid even immediately after a "blank" activation — this isn't a bad-data
    /// bug. The aerials extension only seems to reliably play a locally-injected (non-Apple-CDN)
    /// asset on the first activation after a restart; a second activation with no restart in
    /// between can come up blank even though nothing on disk changed. A restart takes real time,
    /// so triggering it exactly when the lock screen/screensaver is trying to display produces a
    /// visible black gap before the video appears — doing it here instead, while the restart is
    /// invisible against the normal desktop, means it's already settled by the time anything next
    /// needs to actually show the aerial.
    func prewarmForNextActivation() {
        guard let videoURL = lastVideoURL, let name = lastVideoName else { return }
        inject(videoURL: videoURL, name: name)
    }

    /// True if the currently-injected aerial's files and manifest entry are all still present and
    /// WallpaperAgent is running — i.e. the lock screen/screensaver actually has something to play.
    func isInjectionHealthy() -> Bool {
        guard let uuid = aerialsAssetID else { return false }
        let fm = FileManager.default
        let videoPath = (videosDir as NSString).appendingPathComponent("\(uuid).mov")
        guard fm.fileExists(atPath: videoPath) else { return false }
        guard fm.fileExists(atPath: entriesPath) else { return false }
        return isWallpaperAgentRunning()
    }

    /// Registers `videoURL` as the system's aerial wallpaper, syncing desktop, lock screen, and
    /// screensaver to it. Skips the (relatively slow) agent restart if the video hasn't changed.
    func inject(videoURL: URL, name: String) {
        lastVideoURL = videoURL
        lastVideoName = name
        let fm = FileManager.default

        // Compare against the *previous* injection's source size (see `lastInjectedSourceSize`'s
        // doc comment for why this isn't inferred from the destination file's size instead) — but
        // ALSO force a re-copy if the previous destination file is simply gone (macOS clearing the
        // aerials cache, a WallpaperAgent reset, anything external): confirmed live this can happen
        // while the source itself is unchanged, and without this check `videoChanged` stayed false
        // forever afterward, permanently skipping the copy and leaving the aerial pointing at a
        // file that no longer exists — the exact self-healing case `checkHealth()`'s timer exists
        // for, which this was silently defeating.
        let previousUUID = aerialsAssetID
        let previousDestExists = previousUUID.map { fm.fileExists(atPath: (videosDir as NSString).appendingPathComponent("\($0).mov")) } ?? false
        let srcSize = (try? fm.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? -1
        let videoChanged = srcSize != lastInjectedSourceSize || !previousDestExists

        // Mint a FRESH asset UUID whenever the video content actually changes, rather than reusing
        // the previous one. Confirmed live (2026-07-31): reusing the same UUID across genuinely
        // different video files left macOS's own menu-bar-tint sampling showing the *previous*
        // video's cached preview until something unrelated (e.g. taking a screenshot) forced a
        // resample — any system-side cache keyed on this asset ID reasonably assumes a stable ID
        // means unchanged content, so reusing it across different content breaks that assumption.
        // `restartWallpaperAgent()` below already exists because a plain file-overwrite alone
        // wasn't enough to invalidate the *aerials extension's* internal cache; this is the same
        // class of staleness in a different system cache that a restart alone doesn't reach either.
        let uuid = (videoChanged || previousUUID == nil) ? UUID().uuidString.uppercased() : previousUUID!

        let destPath = (videosDir as NSString).appendingPathComponent("\(uuid).mov")

        if videoChanged {
            let sourceForCopy = preparedVideoURL(for: videoURL)
            do {
                try fm.createDirectory(atPath: videosDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destPath) { try fm.removeItem(atPath: destPath) }
                try fm.copyItem(at: sourceForCopy, to: URL(fileURLWithPath: destPath))
            } catch {
                print("AerialsInjector: failed to copy video: \(error)")
                if sourceForCopy != videoURL { try? fm.removeItem(at: sourceForCopy) }
                return
            }
            if sourceForCopy != videoURL { try? fm.removeItem(at: sourceForCopy) }
            lastInjectedSourceSize = srcSize
        }

        let thumbPath = (thumbsDir as NSString).appendingPathComponent("\(uuid).png")
        if videoChanged || !fm.fileExists(atPath: thumbPath) {
            try? fm.createDirectory(atPath: thumbsDir, withIntermediateDirectories: true)
            generateThumbnail(from: videoURL, to: thumbPath)
        }

        guard updateEntriesJSON(assetID: uuid, videoName: name) else {
            print("AerialsInjector: failed to update entries.json")
            return
        }
        guard updateWallpaperStore(assetID: uuid) else {
            print("AerialsInjector: failed to update wallpaper store")
            return
        }

        aerialsAssetID = uuid
        pruneOrphanedAssets(keeping: uuid)

        // Always restart, even when the video itself is unchanged (e.g. a health-check
        // re-injection after some external cache reset) — WallpaperAgent's aerials extension
        // appears to hold onto internal per-session state keyed by this asset that a plain file
        // overwrite doesn't invalidate. Previously this only restarted when the video changed,
        // which left the desktop's first post-switch playback correct but a second screensaver/
        // lock-screen activation blank, since nothing forced the extension to re-read the file.
        restartWallpaperAgent()
        configureScreensaverForAerials()
        startHealthMonitoring()
    }

    /// Below this, the desktop still loops a video fine, but the lock screen/screensaver activation
    /// of the SAME injected asset shows only a static frame — confirmed live with a 0.64s source.
    /// Apple's own real aerial assets (sampled all 152 from `WallpaperAerialAssets.framework`'s own
    /// `entries.json`) are all many seconds to minutes long, with `pointsOfInterest` spans exceeding
    /// a minute even in the shortest ones — nothing suggests the private Aerial pipeline was ever
    /// exercised against a sub-few-second clip. The desktop already loops short videos seamlessly on
    /// its own, so extending the injected FILE (by looping the original enough times to clear this
    /// floor, via a real concatenation, not a synthetic still) should give the lock/screensaver path
    /// a file long enough to work with, without changing what's visibly playing on the desktop.
    private static let minimumAerialDuration: Double = 10.0

    /// Returns a file URL suitable for copying into the aerials store: `sourceURL` itself for any
    /// video already at/above `minimumAerialDuration`, or a freshly exported temp file looping the
    /// original enough times to clear that floor. Falls back to `sourceURL` unchanged on any failure
    /// (unreadable asset, no video track, composition/export failure) — a short video that doesn't
    /// work on the lock screen is the existing, known behavior; this only ever tries to improve on
    /// it, never risks the desktop-playback path that already works.
    private func preparedVideoURL(for sourceURL: URL) -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let sourceDuration = CMTimeGetSeconds(asset.duration)
        guard sourceDuration.isFinite, sourceDuration > 0, sourceDuration < Self.minimumAerialDuration else {
            return sourceURL
        }
        guard let sourceVideoTrack = asset.tracks(withMediaType: .video).first else { return sourceURL }

        let loopCount = max(2, Int((Self.minimumAerialDuration / sourceDuration).rounded(.up)))
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return sourceURL
        }
        compVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform

        let sourceAudioTrack = asset.tracks(withMediaType: .audio).first
        let compAudioTrack = sourceAudioTrack != nil
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        let fullRange = CMTimeRange(start: .zero, duration: asset.duration)
        var cursor = CMTime.zero
        do {
            for _ in 0..<loopCount {
                try compVideoTrack.insertTimeRange(fullRange, of: sourceVideoTrack, at: cursor)
                if let sourceAudioTrack, let compAudioTrack {
                    try compAudioTrack.insertTimeRange(fullRange, of: sourceAudioTrack, at: cursor)
                }
                cursor = CMTimeAdd(cursor, asset.duration)
            }
        } catch {
            print("AerialsInjector: loop composition build failed, using original file: \(error)")
            return sourceURL
        }

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        // Passthrough, not a re-encode: every segment is the original asset's own samples, just
        // concatenated, so this should be near-instant and keep the exact original quality/format.
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return sourceURL
        }
        exportSession.outputURL = tmpURL
        exportSession.outputFileType = .mov

        let semaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously { semaphore.signal() }
        semaphore.wait()

        guard exportSession.status == .completed else {
            print("AerialsInjector: loop export failed (\(exportSession.error?.localizedDescription ?? "unknown")), using original file")
            try? FileManager.default.removeItem(at: tmpURL)
            return sourceURL
        }
        return tmpURL
    }

    /// Removes the injected aerial (e.g. when the current wallpaper is no longer a video).
    func remove() {
        guard let uuid = aerialsAssetID else { return }
        stopHealthMonitoring()
        let fm = FileManager.default
        try? fm.removeItem(atPath: (videosDir as NSString).appendingPathComponent("\(uuid).mov"))
        try? fm.removeItem(atPath: (thumbsDir as NSString).appendingPathComponent("\(uuid).png"))
        removeFromEntriesJSON()
        // `updateWallpaperStore` (called from `inject()`) registers this aerial as the Idle/
        // lock-screen/screensaver choice for every display — deleting the files above and this
        // asset's entries.json category doesn't undo THAT registration. Left alone, the lock
        // screen keeps pointing at a now-deleted video indefinitely (confirmed live 2026-07-30:
        // exactly this state, after switching to an image wallpaper — desktop showed the image
        // correctly, lock screen still referenced the removed aerial). Clears it before the
        // restart below, so the restart picks up a clean state.
        clearStaleAerialStoreEntries(assetID: uuid)
        aerialsAssetID = nil
        lastVideoURL = nil
        lastVideoName = nil
        restorePreviousScreensaverIfNeeded()
        restartWallpaperAgent()
    }

    /// Walks the Store plist for any wallpaper-choice slot (a dict with a `Content` key, e.g.
    /// `AllSpacesAndDisplays.Idle`, `Displays.<uuid>.Idle`, `Spaces.<key>.Default.Linked` — the
    /// exact key name varies by context, confirmed via a live sample, so this doesn't hardcode
    /// just one) whose first choice is the aerials provider referencing `assetID`, and empties its
    /// `Choices` array — never removes the slot's own keys (`Content`/`LastSet`/etc.), just what
    /// it's currently pointing at, to stay structurally consistent with whatever WallpaperAgent
    /// expects to find there. Only ever touches a slot proven to reference OUR OWN asset; a slot
    /// for a different asset, or a non-aerials provider (e.g. the `.image`-provider Desktop
    /// choice), is left completely untouched.
    private func clearStaleAerialStoreEntries(assetID: String) {
        let storeURL = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: storeURL),
              var store = try? PropertyListSerialization.propertyList(
                  from: data, options: .mutableContainersAndLeaves, format: nil
              ) as? [String: Any]
        else { return }

        guard Self.clearStaleAerialSlots(in: &store, assetID: assetID) else { return }

        guard let newData = try? PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0) else { return }
        do {
            let tmpURL = URL(fileURLWithPath: storePath + ".tmp")
            try newData.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
        } catch {
            print("AerialsInjector: failed to clear stale store entries: \(error)")
        }
    }

    @discardableResult
    private static func clearStaleAerialSlots(in dict: inout [String: Any], assetID: String) -> Bool {
        var changed = false
        for key in Array(dict.keys) {
            guard var nested = dict[key] as? [String: Any] else { continue }
            if isStaleAerialSlot(nested, assetID: assetID) {
                var content = nested["Content"] as? [String: Any] ?? [:]
                content["Choices"] = [] as [Any]
                nested["Content"] = content
                dict[key] = nested
                changed = true
                continue
            }
            if clearStaleAerialSlots(in: &nested, assetID: assetID) {
                dict[key] = nested
                changed = true
            }
        }
        return changed
    }

    private static func isStaleAerialSlot(_ slot: [String: Any], assetID: String) -> Bool {
        guard let content = slot["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let first = choices.first,
              (first["Provider"] as? String) == "com.apple.wallpaper.choice.aerials",
              let configData = first["Configuration"] as? Data,
              let config = try? PropertyListSerialization.propertyList(from: configData, options: [], format: nil) as? [String: String],
              config["assetID"] == assetID
        else { return false }
        return true
    }

    /// Deletes any video/thumbnail files in the aerials cache that aren't the current asset.
    /// A single reused UUID means normal operation never creates more than one of each — these
    /// are leftovers from before that reuse was in place, when every wallpaper switch minted a
    /// fresh UUID and never cleaned up the old one (confirmed live: 3 orphaned `.mov` files
    /// totaling ~740MB had accumulated this way). Runs on every inject, so it can't reaccumulate.
    private func pruneOrphanedAssets(keeping uuid: String) {
        let fm = FileManager.default
        for (dir, ext) in [(videosDir, "mov"), (thumbsDir, "png")] {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".\(ext)") && entry != "\(uuid).\(ext)" {
                try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(entry))
            }
        }
    }

    // MARK: - Screensaver module

    /// The screensaver module selected before Wallwright ever pointed it at Aerials — saved once,
    /// the first time a video wallpaper takes over the screensaver, and restored once no video
    /// wallpaper needs it anymore (see `restorePreviousScreensaverIfNeeded`). An empty dictionary
    /// (rather than nil) marks "there was no explicit prior selection" as distinct from "never saved
    /// anything yet", so restore can tell those two cases apart.
    private var savedScreensaverModuleDict: [String: String]? {
        get { UserDefaults.standard.dictionary(forKey: "AerialsSavedScreensaverModuleDict") as? [String: String] }
        set { UserDefaults.standard.set(newValue, forKey: "AerialsSavedScreensaverModuleDict") }
    }

    /// Points the classic screensaver module at Apple's own aerials extension, so the lock-screen
    /// screensaver phase plays our injected video instead of whatever module was selected before.
    private func configureScreensaverForAerials() {
        let aerialsPath = "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex"
        let current = UserDefaults(suiteName: "com.apple.screensaver")
        let currentModuleDict = current?.dictionary(forKey: "moduleDict") as? [String: String]
        let currentModule = currentModuleDict?["path"] ?? ""
        guard currentModule != aerialsPath else { return }

        // Only save on the FIRST override — a later call while our own aerials dict is already
        // active (caught by the guard above) would otherwise clobber the real saved value.
        if savedScreensaverModuleDict == nil {
            savedScreensaverModuleDict = currentModuleDict ?? [:]
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = [
            "-currentHost", "write", "com.apple.screensaver",
            "moduleDict", "-dict",
            "moduleName", "WallpaperAerialsExtension",
            "path", aerialsPath,
            "type", "0",
        ]
        try? task.run()
        task.waitUntilExit()
    }

    /// Restores whatever screensaver module the user had selected before `configureScreensaverForAerials`
    /// last overrode it. Called from `remove()` — without this, switching from a video wallpaper back
    /// to a static image left the *screensaver* still pointed at the now-empty Aerials extension:
    /// confirmed live, a manual lock showed the image fine (that path just reads the synced desktop
    /// picture), but an idle-triggered auto-lock goes through the screensaver phase first, which had
    /// nothing left to play. No-ops if we never overrode it (or already restored it).
    private func restorePreviousScreensaverIfNeeded() {
        guard let saved = savedScreensaverModuleDict else { return }
        savedScreensaverModuleDict = nil

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        if let name = saved["moduleName"], let path = saved["path"] {
            task.arguments = [
                "-currentHost", "write", "com.apple.screensaver",
                "moduleDict", "-dict",
                "moduleName", name,
                "path", path,
                "type", saved["type"] ?? "0",
            ]
        } else {
            // No explicit selection existed before we overrode it — delete our override entirely
            // rather than fabricate one, letting macOS fall back to whatever it normally would.
            task.arguments = ["-currentHost", "delete", "com.apple.screensaver", "moduleDict"]
        }
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - entries.json

    private func updateEntriesJSON(assetID: String, videoName: String) -> Bool {
        let fm = FileManager.default
        let manifestDir = (entriesPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: manifestDir, withIntermediateDirectories: true)

        var entries: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = parsed
        } else {
            entries = ["version": 1, "categories": [] as [Any], "assets": [] as [Any]]
        }

        var categories = entries["categories"] as? [[String: Any]] ?? []
        var assets = entries["assets"] as? [[String: Any]] ?? []

        let thumbFileURL = URL(fileURLWithPath: (thumbsDir as NSString).appendingPathComponent("\(assetID).png")).absoluteString
        let videoFileURL = URL(fileURLWithPath: (videosDir as NSString).appendingPathComponent("\(assetID).mov")).absoluteString

        let categoryEntry: [String: Any] = [
            "id": categoryID,
            "localizedNameKey": "Wallwright",
            "localizedDescriptionKey": "Wallwright custom wallpaper",
            "preferredOrder": 0,
            "representativeAssetID": assetID,
            "previewImage": thumbFileURL,
            "subcategories": [
                [
                    "id": subcategoryID,
                    "localizedNameKey": "Wallwright",
                    "localizedDescriptionKey": "Wallwright custom wallpaper",
                    "preferredOrder": 0,
                    "previewImage": thumbFileURL,
                    "representativeAssetID": assetID,
                ]
            ],
        ]

        if let idx = categories.firstIndex(where: { ($0["id"] as? String) == categoryID }) {
            categories[idx] = categoryEntry
        } else {
            categories.append(categoryEntry)
        }

        let shotID = "CUSTOM_\(assetID.replacingOccurrences(of: "-", with: "_"))"
        let assetEntry: [String: Any] = [
            "id": assetID,
            "localizedNameKey": videoName,
            "accessibilityLabel": videoName,
            "shotID": shotID,
            "showInTopLevel": true,
            // false, not true: we only ever register a single custom asset. If the aerials
            // extension's own shuffle logic tries to avoid repeating the same shot on
            // consecutive showings (a common shuffle-algorithm behavior) and there's nothing
            // else in the pool to rotate to, that's a plausible way a second screensaver/
            // lock-screen activation could come up with nothing to play.
            "includeInShuffle": false,
            "preferredOrder": 0,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": videoFileURL,
            "previewImage": thumbFileURL,
            "pointsOfInterest": ["0": "\(shotID)_0"],
        ]

        assets.removeAll { asset in
            guard let cats = asset["categories"] as? [String] else { return false }
            return cats.contains(categoryID)
        }
        assets.append(assetEntry)

        entries["categories"] = categories
        entries["assets"] = assets

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            let tmpURL = URL(fileURLWithPath: entriesPath + ".tmp")
            try jsonData.write(to: tmpURL)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: entriesPath), withItemAt: tmpURL)
            return true
        } catch {
            print("AerialsInjector: failed to write entries.json: \(error)")
            return false
        }
    }

    private func removeFromEntriesJSON() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if var categories = entries["categories"] as? [[String: Any]] {
            categories.removeAll { ($0["id"] as? String) == categoryID }
            entries["categories"] = categories
        }
        if var assets = entries["assets"] as? [[String: Any]] {
            assets.removeAll { asset in
                guard let cats = asset["categories"] as? [String] else { return false }
                return cats.contains(categoryID)
            }
            entries["assets"] = assets
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: URL(fileURLWithPath: entriesPath))
        }
    }

    // MARK: - Thumbnail

    private func generateThumbnail(from videoURL: URL, to outputPath: String) {
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        gen.generateCGImageAsynchronously(for: time) { cgImage, _, _ in
            guard let cgImage else { return }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let pngData = rep.representation(using: .png, properties: [:]) {
                // .atomic, not a plain write: thumbPath is the same UUID-keyed file across every
                // wallpaper we ever inject (the asset ID is reused, not per-wallpaper), and
                // thumbnail generation is async and fire-and-forget. Two inject() calls close
                // together — e.g. a quick wallpaper switch, or prewarmForNextActivation() firing
                // on an unlock right after one — can end up with two of these completion
                // handlers writing to the exact same path concurrently. A plain write can
                // interleave and corrupt the file (this is what produced the garbled/static-like
                // thumbnail seen in System Settings); .atomic writes to a temp file and renames,
                // so even under a race only one fully-formed file ever lands at the real path.
                try? pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            }
        }
    }

    // MARK: - Store/Index.plist

    private func updateWallpaperStore(assetID: String) -> Bool {
        let configDict: [String: String] = ["assetID": assetID]
        guard let configData = try? PropertyListSerialization.data(
            fromPropertyList: configDict, format: .binary, options: 0
        ) else { return false }

        let storeURL = URL(fileURLWithPath: storePath)
        let storeDir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: storeDir, withIntermediateDirectories: true)

        var store: [String: Any]
        if let data = try? Data(contentsOf: storeURL),
           let parsed = try? PropertyListSerialization.propertyList(
               from: data, options: .mutableContainersAndLeaves, format: nil
           ) as? [String: Any] {
            store = parsed
        } else {
            store = [:]
        }

        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [] as [Any],
            "Configuration": configData,
        ]
        let content: [String: Any] = ["Choices": [choice]]
        let linked: [String: Any] = ["Content": content, "LastSet": Date(), "LastUse": Date()]
        let entry: [String: Any] = ["Type": "linked", "Linked": linked]

        store["SystemDefault"] = entry
        // Global override for every display/space — this is what makes the aerial show on the
        // lock screen and screensaver for every display, not just whichever one is "current".
        store["AllSpacesAndDisplays"] = entry

        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys { displays[key] = entry }
            store["Displays"] = displays
        }
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

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
            let tmpURL = URL(fileURLWithPath: storePath + ".tmp")
            try data.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
            return true
        } catch {
            print("AerialsInjector: failed to write wallpaper store: \(error)")
            return false
        }
    }

    // MARK: - WallpaperAgent

    /// Deliberately does NOT reach into WallpaperAgent's or the aerials extension's own sandboxed
    /// containers (an earlier version did, to manually clear their cache/shuffle-state files) —
    /// that's what was triggering macOS's "access data from other apps" permission prompt, which
    /// on top of being the wrong scope for a wallpaper app to be requesting, also turned out not
    /// to persist reliably across launches on the user's system, so it bought nothing but a
    /// re-occurring dialog. `killall` needs no special permission at all (signaling a process you
    /// own is always allowed) and `launchd` relaunching the agent fresh is the actual sanctioned
    /// way to reset its state — if the agent doesn't invalidate its own on-disk caches on a clean
    /// relaunch, that's on Apple's side, not something to work around by reaching into its sandbox.
    private func restartWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
        task.waitUntilExit()
    }

    private func isWallpaperAgentRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "WallpaperAgent"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
