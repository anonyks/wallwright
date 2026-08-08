//
//  PlaylistViewModel.swift
//  Wallwright
//
//  A single manually-curated, ordered rotation of wallpapers — sequential or shuffled, advancing
//  either the instant each item finishes one full loop ("per-wallpaper" mode) or after a user-set
//  duration has elapsed, but always at the *next* loop boundary rather than cutting a video off
//  mid-clip ("timed" mode). Global, not per-screen: every enabled screen shows the same current
//  item at once, driven off a single "driving" screen's own loop-end event (see
//  `VideoWallpaperViewModel.playerDidFinishPlaying`). Deliberately just one playlist, not a
//  library of named playlists — that turned out to add a create/select/manage step for no real
//  benefit when there's only ever one rotation active at a time.
//

import AppKit
import Combine

enum PlaylistSwitchMode: String, Codable {
    case perWallpaper, timed
}

enum PlaylistSkipDirection {
    case next, previous
}

struct Playlist: Codable, Equatable {
    /// Ordered; identity matches `WEWallpaper.wallpaperDirectory` (compared via
    /// `isSameWallpaperDirectory(as:)`, never raw `URL ==` — see that helper's own doc comment).
    var itemDirectories: [URL]
    var shuffleEnabled: Bool
    var switchMode: PlaylistSwitchMode
    var timedIntervalMinutes: Double

    init(
        itemDirectories: [URL] = [], shuffleEnabled: Bool = false,
        switchMode: PlaylistSwitchMode = .perWallpaper, timedIntervalMinutes: Double = 5
    ) {
        self.itemDirectories = itemDirectories
        self.shuffleEnabled = shuffleEnabled
        self.switchMode = switchMode
        self.timedIntervalMinutes = timedIntervalMinutes
    }

    /// Hand-written, same defensive pattern as `GlobalSettings.init(from:)` — every field wrapped
    /// in `try?` with a fallback, so one bad/missing field (e.g. after a future schema change)
    /// only resets that one field instead of throwing away the whole playlist.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemDirectories = (try? c.decodeIfPresent([URL].self, forKey: .itemDirectories)) ?? nil ?? []
        shuffleEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .shuffleEnabled)) ?? nil ?? false
        switchMode = (try? c.decodeIfPresent(PlaylistSwitchMode.self, forKey: .switchMode)) ?? nil ?? .perWallpaper
        timedIntervalMinutes = (try? c.decodeIfPresent(Double.self, forKey: .timedIntervalMinutes)) ?? nil ?? 5
    }
}

/// The whole persisted shape — one file, one decoder, kept separate from `GlobalSettings.json` so
/// playlist work never has to touch that (already large) settings decoder.
private struct PlaylistFile: Codable {
    var playlist: Playlist
    var isActive: Bool
    var isPinned: Bool

    init(playlist: Playlist = Playlist(), isActive: Bool = false, isPinned: Bool = false) {
        self.playlist = playlist
        self.isActive = isActive
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlist = (try? c.decodeIfPresent(Playlist.self, forKey: .playlist)) ?? nil ?? Playlist()
        isActive = (try? c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? nil ?? false
        isPinned = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? nil ?? false
    }
}

final class PlaylistViewModel: ObservableObject {
    @Published var playlist = Playlist() {
        didSet { save() }
    }
    @Published var isActive = false {
        didSet {
            if isActive != oldValue {
                elapsedSeconds = 0
                lastPlayedIndices.removeAll()
                // The tick timer only has anything to do while a playlist is actually active
                // (`tick()` itself already early-returns via `guard isActive` otherwise) — no
                // reason to wake the process every 15s for the app's entire lifetime when no
                // playlist has ever been turned on.
                isActive ? startTicking() : stopTicking()
            }
            save()
        }
    }
    @Published var isPinned = false {
        didSet { save() }
    }

    /// Small ring buffer of recently-played indices, for shuffle-without-immediate-repeats.
    private var lastPlayedIndices: [Int] = []
    /// Only relevant in `.timed` mode; frozen (not incremented) while `isPinned`.
    private var elapsedSeconds: TimeInterval = 0
    private var tickTimer: Timer?

    /// `NSScreen.screens.first` (the hardware/menu-bar-designated primary display), not
    /// `NSScreen.main` (which tracks *keyboard focus*, not a fixed screen) — re-resolving
    /// `.main` on every loop-end would make playlist advancement silently jump between screens
    /// depending on which window the user last clicked, since `WallpaperWindow` itself can never
    /// become key/main. `.screens.first` only changes on an actual display connect/disconnect.
    var drivingScreenId: String {
        guard let first = NSScreen.screens.first else { return WallpaperViewModel.mainScreenId() }
        return WallpaperViewModel.screenId(for: first)
    }

    init() {
        let loaded = Self.loadPersisted()
        self.playlist = loaded.playlist
        // Assigning directly to the stored property (not through `self.isActive = ...`, which
        // would run its own `didSet` and start the timer redundantly here on top of the explicit
        // call below) — Swift property observers don't fire for a value set during `init` anyway,
        // but this stays explicit rather than relying on that.
        self.isActive = loaded.isActive
        self.isPinned = loaded.isPinned
        if isActive { startTicking() }
    }

    deinit {
        tickTimer?.invalidate()
    }

    // MARK: - Persistence

    private static var playlistFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wallwright Settings")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appending(path: "Playlist.json")
    }

    private static func loadPersisted() -> PlaylistFile {
        guard let data = try? Data(contentsOf: playlistFileURL),
              let file = try? JSONDecoder().decode(PlaylistFile.self, from: data)
        else { return PlaylistFile() }
        return file
    }

    private func save() {
        let file = PlaylistFile(playlist: playlist, isActive: isActive, isPinned: isPinned)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: Self.playlistFileURL, options: .atomic)
    }

    // MARK: - Playlist editing

    /// Skips directories already present (matched via `isSameWallpaperDirectory`) rather than
    /// allowing duplicates.
    func addWallpapers(_ directories: [URL]) {
        for directory in directories where !playlist.itemDirectories.contains(where: { $0.isSameWallpaperDirectory(as: directory) }) {
            playlist.itemDirectories.append(directory)
        }
    }

    func removeItems(at offsets: IndexSet) {
        playlist.itemDirectories.remove(atOffsets: offsets)
    }

    func moveItems(from source: IndexSet, to destination: Int) {
        playlist.itemDirectories.move(fromOffsets: source, toOffset: destination)
    }

    /// Called alongside every existing `removeWallpaperFromAllScreens` call site so a deleted
    /// wallpaper can't leave a dangling, 404-on-advance entry in the playlist.
    func removeWallpaperFromPlaylist(directory: URL) {
        playlist.itemDirectories.removeAll { $0.isSameWallpaperDirectory(as: directory) }
    }

    // MARK: - Activation

    func activate() {
        guard !playlist.itemDirectories.isEmpty else { return }
        isActive = true
        advance(direction: .next) // start playback from the first (or a random) item immediately
    }

    func deactivate() {
        isActive = false
        isPinned = false
    }

    /// Explicit user action (hotkey/menu) — always immediate, ignores the pin and the
    /// loop-boundary wait that automatic advancement respects, and resets the timed-mode clock.
    func skip(direction: PlaylistSkipDirection) {
        guard isActive else { return }
        advance(direction: direction)
    }

    /// If the manually-picked wallpaper is in the playlist, keep it running from that new
    /// position; otherwise the manual pick takes precedence and the playlist deactivates.
    func wallpaperWasManuallyPicked(_ wallpaper: WEWallpaper) {
        guard isActive else { return }
        if playlist.itemDirectories.contains(where: { $0.isSameWallpaperDirectory(as: wallpaper.wallpaperDirectory) }) {
            elapsedSeconds = 0
        } else {
            deactivate()
        }
    }

    /// Called from the driving screen's `VideoWallpaperViewModel.playerDidFinishPlaying`. Returns
    /// `true` if it just advanced the playlist (the caller should skip its own normal
    /// seek-to-zero-and-loop, since a new wallpaper is on its way in), `false` to loop as usual.
    @discardableResult
    func mainScreenLoopEnded() -> Bool {
        guard isActive, playlist.itemDirectories.count > 1, !isPinned else { return false }
        switch playlist.switchMode {
        case .perWallpaper:
            break
        case .timed:
            guard elapsedSeconds >= effectiveTimedInterval else { return false }
        }
        advance(direction: .next)
        return true
    }

    /// Shared by `mainScreenLoopEnded()` and `tick()` so the two never drift apart on what
    /// "the interval" actually means.
    private var effectiveTimedInterval: TimeInterval {
        playlist.timedIntervalMinutes * 60 * (BatteryMonitor.shared.isOnBattery ? 1.5 : 1.0)
    }

    /// True only for the specific "paused because the laptop is on battery, and that policy is
    /// set to Pause" state — deliberately narrower than "playRate == 0" in general. Manual pause
    /// and lock-screen pause (both confirmed correct as-is: manual pause means the user explicitly
    /// wants things frozen, and the lock screen is invisible anyway) must NOT gain the
    /// paused-but-still-advancing behavior below; only this one specific, visible-desktop case
    /// should.
    private var isPausedSpecificallyForBattery: Bool {
        BatteryMonitor.shared.isOnBattery && AppDelegate.shared.globalSettingsViewModel.settings.laptopOnBattery == .pause
    }

    // MARK: - Advancement internals

    private var currentIndex: Int? {
        let current = AppDelegate.shared.wallpaperViewModel.wallpaper(for: drivingScreenId)
        return playlist.itemDirectories.firstIndex(where: { $0.isSameWallpaperDirectory(as: current.wallpaperDirectory) })
    }

    private func advance(direction: PlaylistSkipDirection) {
        let cur = currentIndex
        guard !playlist.itemDirectories.isEmpty else { return }
        guard let nextIndex = pickNextIndex(from: cur, direction: direction) else { return }

        recordPlayed(index: nextIndex, itemCount: playlist.itemDirectories.count)
        elapsedSeconds = 0

        let directory = playlist.itemDirectories[nextIndex]
        guard let wallpaper = resolveWallpaper(at: directory) else { return }
        AppDelegate.shared.wallpaperViewModel.setWallpaperForEnabledScreens(wallpaper)
    }

    private func resolveWallpaper(at directory: URL) -> WEWallpaper? {
        AppDelegate.shared.contentViewModel.wallpapers.first(where: { $0.wallpaperDirectory.isSameWallpaperDirectory(as: directory) })
    }

    private func pickNextIndex(from current: Int?, direction: PlaylistSkipDirection) -> Int? {
        let count = playlist.itemDirectories.count
        guard count > 0 else { return nil }
        if playlist.shuffleEnabled {
            return pickShuffledIndex(count: count)
        }
        let base = current ?? -1
        switch direction {
        case .next: return (base + 1 + count) % count
        case .previous: return (base - 1 + count) % count
        }
    }

    private func pickShuffledIndex(count: Int) -> Int {
        guard count > 1 else { return 0 }
        let excludeCount = min(lastPlayedIndices.count, count - 1) // never exclude every candidate
        let excluded = Set(lastPlayedIndices.suffix(excludeCount))
        let candidates = (0..<count).filter { !excluded.contains($0) }
        return candidates.randomElement() ?? Int.random(in: 0..<count)
    }

    private func recordPlayed(index: Int, itemCount: Int) {
        lastPlayedIndices.append(index)
        let maxHistory = max(1, itemCount - 1)
        if lastPlayedIndices.count > maxHistory {
            lastPlayedIndices.removeFirst(lastPlayedIndices.count - maxHistory)
        }
    }

    // MARK: - Timed-mode clock

    private func startTicking() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tickTimer?.tolerance = 5
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isActive, !isPinned else { return }
        let onBatteryPause = isPausedSpecificallyForBattery
        let currentIsImage = currentItemIsStaticImage
        // A static image has no "loop end" event at all — `mainScreenLoopEnded()` is only ever
        // called from `VideoWallpaperViewModel.playerDidFinishPlaying`, which never exists for an
        // image screen (see `WallpaperView`'s type dispatch). So in EVERY switch mode, not just
        // `.timed`, a static image item has to advance off this elapsed-time clock instead —
        // there's no boundary to wait for that will ever come.
        guard playlist.switchMode == .timed || currentIsImage else { return }
        // Only counts while actually playing, OR while paused specifically for the battery policy,
        // OR while showing a static image (which has no "playing" state to gate on at all) — any
        // *other* pause (manual, lock screen, other-app-fullscreen, display asleep) still doesn't
        // count, so a long one of those doesn't leave elapsedSeconds already past the interval by
        // the time playback resumes, firing a surprise advance instead of after N minutes of
        // actually-watched time.
        guard AppDelegate.shared.wallpaperViewModel.playRate > 0 || onBatteryPause || currentIsImage else { return }
        elapsedSeconds += 15

        // On battery, playback is fully paused (rate 0), so `playerDidFinishPlaying` will never
        // fire; there's no "loop end" to wait for since nothing is progressing. Waiting for one
        // there would mean staying on the exact same frozen frame for as long as you're on battery
        // power, defeating the point of having a playlist while you're actively looking at the
        // desktop (unlike a lock screen, battery mode doesn't hide anything). Since nothing is
        // animating, there's no "cut a clip off mid-motion" risk to protect against by waiting
        // anyway — advancing directly here is safe. The exact same reasoning applies to a static
        // image, which is never "animating" in the first place regardless of battery state.
        if (onBatteryPause || currentIsImage), itemCount > 1, elapsedSeconds >= effectiveTimedInterval {
            advance(direction: .next)
        }
    }

    private var currentItemIsStaticImage: Bool {
        AppDelegate.shared.wallpaperViewModel.wallpaper(for: drivingScreenId).project.type.lowercased() == "image"
    }

    private var itemCount: Int { playlist.itemDirectories.count }
}
