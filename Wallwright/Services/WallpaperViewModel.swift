//
//  WallpaperViewModel.swift
//  Wallwright
//
//  Created by Haren on 2023/8/14.
//

import CoreGraphics
import SwiftUI

/// Provide Wallpaper Database for WallpaperView and ContentView etc.
class WallpaperViewModel: ObservableObject {
    @Published var nextCurrentWallpaper: WEWallpaper =
    WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!) {
        willSet {
            self.setWallpaper(newValue, for: selectedScreenId)
        }
    }

    /// Per-screen wallpaper assignments, keyed by a stable per-display UUID string (see `screenId(for:)`).
    @Published var wallpapers: [String: WEWallpaper] = [:] {
        didSet { saveWallpapers() }
    }

    /// Screens where wallpaper display is enabled.
    @Published var enabledScreens: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(enabledScreens), forKey: "EnabledScreens")
        }
    }

    /// Every screen ID this app has ever seen connected — distinct from `enabledScreens` so a
    /// display the user explicitly disabled doesn't get silently re-enabled just because it's
    /// still connected. `screenId(for:)` is a stable per-display UUID unaffected by resolution, so
    /// `AppDelegate.screensChanged()` re-fires for the SAME already-known display on a resolution
    /// change, sleep/wake, or dock/undock — under the old "not in enabledScreens" check, that was
    /// indistinguishable from a genuinely new display and silently overrode the user's choice.
    @Published var knownScreens: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(knownScreens), forKey: "KnownScreens")
        }
    }

    /// The screen currently selected in the UI for configuration.
    @Published var selectedScreenId: String = ""

    static let defaultWallpaper = WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!)

    // MARK: - Recent wallpapers

    private static let maxRecents = 10
    private static let recentsKey = "RecentWallpapers"

    @Published var recentWallpapers: [WEWallpaper] = []

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              let saved = try? JSONDecoder().decode([WEWallpaper].self, from: data) else { return }

        var seenDirectories: [URL] = []
        var cleaned: [WEWallpaper] = []
        var didDropStaleEntry = false

        for wallpaper in saved {
            guard wallpaper.project != .invalid,
                  FileManager.default.fileExists(atPath: wallpaper.wallpaperDirectory.path)
            else {
                // Points at a directory that no longer exists (e.g. a stale reference left
                // over from before wallpaper storage moved to a different location).
                didDropStaleEntry = true
                continue
            }
            guard !seenDirectories.contains(where: { $0.isSameWallpaperDirectory(as: wallpaper.wallpaperDirectory) }) else {
                didDropStaleEntry = true
                continue
            }
            seenDirectories.append(wallpaper.wallpaperDirectory)
            cleaned.append(wallpaper)
        }

        recentWallpapers = cleaned
        if didDropStaleEntry {
            saveRecents()
        }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentWallpapers) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    func addToRecents(_ wallpaper: WEWallpaper) {
        guard wallpaper.project != .invalid else { return }
        recentWallpapers.removeAll { $0.wallpaperDirectory.isSameWallpaperDirectory(as: wallpaper.wallpaperDirectory) }
        recentWallpapers.insert(wallpaper, at: 0)
        if recentWallpapers.count > Self.maxRecents {
            recentWallpapers = Array(recentWallpapers.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    // MARK: - Wallpaper access

    /// Convenience: wallpaper for the currently selected screen in the UI.
    var currentWallpaper: WEWallpaper {
        get {
            wallpapers[selectedScreenId] ?? Self.defaultWallpaper
        }
        set {
            setWallpaper(newValue, for: selectedScreenId)
        }
    }

    /// Get wallpaper for a specific screen.
    func wallpaper(for screenId: String) -> WEWallpaper {
        wallpapers[screenId] ?? Self.defaultWallpaper
    }

    /// Set wallpaper for a specific screen.
    func setWallpaper(_ wallpaper: WEWallpaper, for screenId: String) {
        wallpapers[screenId] = wallpaper
        addToRecents(wallpaper)
    }

    /// Applies `wallpaper` to every enabled screen as one batched update — used by playlist
    /// advancement, where "global rotation" means every screen changes together. Deliberately not
    /// a loop calling `setWallpaper(_:for:)` per screen: each of those independently triggers
    /// `wallpapers`' own `didSet` (a full JSON-encode + write) and its own `addToRecents` call
    /// (which mutates and re-encodes `recentWallpapers`), so N enabled screens would mean N
    /// redundant full-dictionary writes and N redundant recents mutations for what's semantically
    /// one event.
    func setWallpaperForEnabledScreens(_ wallpaper: WEWallpaper) {
        var updated = wallpapers
        for id in enabledScreens { updated[id] = wallpaper }
        wallpapers = updated
        addToRecents(wallpaper)
    }

    /// The general-purpose "Next Wallpaper" action — cycles to the next wallpaper in the library
    /// (whatever order/filter the grid is currently showing), wrapping around at the end. Used by
    /// the Next Wallpaper hotkey/menu item when no playlist is active; when one is, that hotkey
    /// drives `PlaylistViewModel.skip(direction:)` instead, which has its own shuffle/sequential
    /// logic.
    func advanceToNextWallpaper() {
        let library = AppDelegate.shared.contentViewModel.autoRefreshWallpapers
        guard !library.isEmpty else { return }
        let current = currentWallpaper
        let currentIndex = library.firstIndex { $0.wallpaperDirectory.isSameWallpaperDirectory(as: current.wallpaperDirectory) }
        let nextIndex = ((currentIndex ?? -1) + 1) % library.count
        let next = library[nextIndex]
        setWallpaperForEnabledScreens(next)
        AppDelegate.shared.playlistViewModel.wallpaperWasManuallyPicked(next)
    }

    /// The symmetric counterpart to `advanceToNextWallpaper()` — this used to not exist, on the
    /// stated reasoning that "a plain library cycle has no natural order to walk backwards
    /// through." That doesn't actually hold: `autoRefreshWallpapers` is already a well-defined,
    /// stable order (whatever sort the user has active), so walking it backwards is exactly as
    /// meaningful as walking it forwards. Without this, the "Previous Wallpaper" hotkey/menu
    /// item/CLI command silently did nothing at all whenever no playlist was running — confirmed
    /// live via `PlaylistViewModel.skip(direction:)`'s own `guard isActive else { return }`.
    func advanceToPreviousWallpaper() {
        let library = AppDelegate.shared.contentViewModel.autoRefreshWallpapers
        guard !library.isEmpty else { return }
        let current = currentWallpaper
        let currentIndex = library.firstIndex { $0.wallpaperDirectory.isSameWallpaperDirectory(as: current.wallpaperDirectory) }
        let previousIndex = (((currentIndex ?? 0) - 1) + library.count) % library.count
        let previous = library[previousIndex]
        setWallpaperForEnabledScreens(previous)
        AppDelegate.shared.playlistViewModel.wallpaperWasManuallyPicked(previous)
    }

    func isScreenEnabled(_ screenId: String) -> Bool {
        enabledScreens.contains(screenId)
    }

    func toggleScreen(_ screenId: String) {
        if enabledScreens.contains(screenId) {
            enabledScreens.remove(screenId)
        } else {
            enabledScreens.insert(screenId)
        }
        AppDelegate.shared.rebuildWallpaperWindows()
        // `setClockWindows()` gates window creation on `isScreenEnabled(screenId)` — without this,
        // disabling a screen left its clock overlay floating above the native desktop picture
        // indefinitely (only the wallpaper window was torn down), and re-enabling one didn't create
        // a new clock window until something else happened to trigger a rebuild.
        AppDelegate.shared.rebuildClockWindows()
    }

    /// Cleans up every reference to a wallpaper after it's been deleted: clears it from any
    /// screen it was assigned to, drops it from Recent Wallpapers, and forgets any trust
    /// decision recorded for it — otherwise these all keep pointing at a directory that no
    /// longer exists.
    ///
    /// Screens that had this wallpaper fall back to `replacement` (e.g. another wallpaper still
    /// in the library) when one's available, rather than always dropping to the "Wallpaper Not
    /// Found" placeholder even though other wallpapers exist to use instead.
    func removeWallpaperFromAllScreens(directory: URL, replacement: WEWallpaper? = nil) {
        for (key, wp) in wallpapers {
            if wp.wallpaperDirectory.isSameWallpaperDirectory(as: directory) {
                wallpapers[key] = replacement ?? Self.defaultWallpaper
            }
        }

        if recentWallpapers.contains(where: { $0.wallpaperDirectory.isSameWallpaperDirectory(as: directory) }) {
            recentWallpapers.removeAll { $0.wallpaperDirectory.isSameWallpaperDirectory(as: directory) }
            saveRecents()
        }
    }

    var lastPlayRate: Float = 1.0
    /// True while the current pause was something the user explicitly asked for (hotkey, menu,
    /// CLI, the sidebar button) — as opposed to the "Other Application Focused/Fullscreen"
    /// auto-pause. Confirmed live: without this, switching to an empty macOS Space activates
    /// Finder (nothing else there to focus), which fires the "Other Application Focused: Pause"
    /// auto-resume and silently un-pauses a wallpaper the user paused on purpose moments earlier.
    /// Auto-resume checks this and backs off; auto-pause is unaffected either way.
    @Published var isPausedByUser = false

    /// Same reasoning as `isPausedByUser` above, for volume instead of playback — without this, a
    /// user muting the wallpaper on purpose gets silently un-muted the moment an unrelated trigger
    /// re-fires an auto-unmute (other-app audio stopping, or switching back to Wallwright/Finder
    /// with "Other Application Focused" set to Mute), since `unmute()` had no way to know the mute
    /// was intentional rather than another policy's own doing.
    @Published var isMutedByUser = false

    /// True while a "Stop (free memory)" policy is currently in effect — every screen's
    /// `VideoWallpaperViewModel` observes this (same reactive pattern as `playRate`/`playVolume`
    /// below) and actually tears down/rebuilds its `AVPlayerItem`s in response, releasing the real
    /// `VTDecoderXPCService` hardware-decoder session and its buffer pool. `GlobalSettingsService`
    /// owns setting this — see its `shouldWallpaperStayStopped`, the `.stop` mirror of
    /// `shouldWallpaperStayPaused`. Window visibility (`AppDelegate.wallpaperWindows`) is driven
    /// separately at each `.stop` call site, gated on this same flag so a window is never shown
    /// with a torn-down player behind it.
    @Published var isStopped = false

    @Published public var playRate: Float = 1.0 {
        willSet {
            // Matched by the row's own `action`, not `item.title` — `title` is locale-dependent
            // (these rows are built via `String(localized:)`) so an English-literal comparison
            // never matches on a non-English system, and replacing the whole `NSMenuItem` (as this
            // used to) destroys its `ShortcutMenuItemView` on every toggle regardless of locale.
            // `action` is stable in both states and unique to this row. `statusItem` and `.menu`
            // are both implicitly-unwrapped and unset this early during launch — optional-chained
            // rather than force-unwrapped so a `playRate` change before menu setup is a no-op
            // instead of a crash.
            if let item = AppDelegate.shared.statusItem?.menu?.items.first(where: {
                ($0.view as? ShortcutMenuItemView)?.action == #selector(AppDelegate.togglePause)
            }), let view = item.view as? ShortcutMenuItemView {
                view.updateTitle(
                    newValue == 0.0 ? String(localized: "Resume") : String(localized: "Pause"),
                    systemImage: newValue == 0.0 ? "play.fill" : "pause.fill"
                )
            }
        }
        didSet {
            self.lastPlayRate = oldValue
        }
    }

    var lastPlayVolume: Float = 1.0
    @Published public var playVolume: Float = 1.0 {
        willSet {
            // See `playRate`'s willSet above for why this matches on `action`, not `title`.
            if let item = AppDelegate.shared.statusItem?.menu?.items.first(where: {
                ($0.view as? ShortcutMenuItemView)?.action == #selector(AppDelegate.toggleMute)
            }), let view = item.view as? ShortcutMenuItemView {
                view.updateTitle(
                    newValue == 0.0 ? String(localized: "Unmute") : String(localized: "Mute"),
                    systemImage: newValue == 0.0 ? "speaker.fill" : "speaker.slash.fill"
                )
            }
        }
        didSet {
            self.lastPlayVolume = oldValue
        }
    }

    init() {
        // Load per-screen wallpapers
        if let data = UserDefaults.standard.data(forKey: "ScreenWallpapers"),
           let saved = try? JSONDecoder().decode([String: WEWallpaper].self, from: data) {
            // Filter out any compound keys (screenId_spaceId) from previous per-space experiment,
            // and fall back to default for any wallpaper whose directory no longer exists (e.g. a
            // stale reference left over from before wallpaper storage moved to a new location).
            let cleaned = saved
                .filter { !$0.key.contains("_") }
                .mapValues { wallpaper in
                    FileManager.default.fileExists(atPath: wallpaper.wallpaperDirectory.path)
                        ? wallpaper
                        : Self.defaultWallpaper
                }
            self.wallpapers = Self.migratingLegacyDisplayIDKeys(cleaned)
        }
        // Migrate legacy single wallpaper
        else if let json = UserDefaults.standard.data(forKey: "CurrentWallpaper"),
                let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: json),
                FileManager.default.fileExists(atPath: wallpaper.wallpaperDirectory.path) {
            let mainId = Self.mainScreenId()
            self.wallpapers = [mainId: wallpaper]
        }

        // Load enabled screens (default: all connected screens enabled)
        if let saved = UserDefaults.standard.array(forKey: "EnabledScreens") as? [String] {
            var migrated = Set(saved)
            for screen in NSScreen.screens {
                let legacyId = String(Self.legacyDisplayId(for: screen))
                let stableId = Self.screenId(for: screen)
                if legacyId != stableId, migrated.contains(legacyId), !migrated.contains(stableId) {
                    migrated.insert(stableId)
                }
            }
            self.enabledScreens = migrated
        } else {
            self.enabledScreens = Set(NSScreen.screens.map { Self.screenId(for: $0) })
        }

        // No prior history of which screens were ever seen before this property existed — the best
        // available reconstruction is anything currently enabled or ever assigned a wallpaper
        // (`wallpapers`' keys persist across a disable, see `toggleScreen`). A screen disabled
        // before ever getting a wallpaper assignment won't be caught by this one-time migration and
        // could still get silently re-enabled once more, but every screen seen from here on is
        // tracked correctly.
        if let saved = UserDefaults.standard.array(forKey: "KnownScreens") as? [String] {
            self.knownScreens = Set(saved)
        } else {
            self.knownScreens = self.enabledScreens.union(self.wallpapers.keys)
        }

        // Default selected screen to main
        self.selectedScreenId = Self.mainScreenId()

        // Load recent wallpapers
        loadRecents()
    }

    // MARK: - Screen ID helpers

    /// `CGDirectDisplayID` is only stable for the current boot/hot-plug session — it can be
    /// reassigned across a reboot or when displays are reconnected in a different order, which
    /// would silently scramble per-display wallpaper assignments on a multi-monitor setup.
    /// `CGDisplayCreateUUIDFromDisplayID` ties the ID to the physical display instead, so it
    /// survives reboots and reordering. Falls back to the raw ID for the rare display that
    /// doesn't vend a UUID (e.g. some virtual/adapter displays).
    static func screenId(for screen: NSScreen) -> String {
        let displayId = legacyDisplayId(for: screen)
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayId) {
            return CFUUIDCreateString(nil, uuidRef.takeRetainedValue()) as String
        }
        return String(displayId)
    }

    private static func legacyDisplayId(for screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// One-time upgrade path from the old raw-`CGDirectDisplayID`-keyed format: for each
    /// currently connected screen, if data is still sitting under its legacy key but nothing's
    /// under its new stable key yet, copy it over — otherwise upgrading this app would look like
    /// it reset every per-display wallpaper assignment.
    private static func migratingLegacyDisplayIDKeys<Value>(_ dict: [String: Value]) -> [String: Value] {
        var migrated = dict
        for screen in NSScreen.screens {
            let legacyId = String(legacyDisplayId(for: screen))
            let stableId = screenId(for: screen)
            guard legacyId != stableId, migrated[stableId] == nil, let legacyValue = migrated[legacyId] else { continue }
            migrated[stableId] = legacyValue
        }
        return migrated
    }

    /// Prunes `wallpapers`/`enabledScreens` entries left behind by a display that never got a
    /// stable UUID from `screenId(for:)` (its raw-`CGDirectDisplayID` fallback — confirmed to
    /// affect KVM switches and some USB/DisplayLink adapters) once it disconnects. Such a display
    /// gets a new, different raw ID on every reconnect, so an old raw-ID-keyed entry can never be
    /// "reunited" with its display again — left alone, every reconnect adds one more permanently
    /// orphaned entry to two persisted collections, forever. UUID-keyed entries (the normal case,
    /// any display with a real EDID) are never touched here — a display's own UUID is worth
    /// remembering even while it's unplugged, so its wallpaper choice is still there next time it
    /// reconnects. Called from `AppDelegate.screensChanged()` on every debounced reconfiguration.
    func pruneOrphanedLegacyScreenIDs() {
        let connectedLegacyIds = Set(NSScreen.screens.map { String(Self.legacyDisplayId(for: $0)) })
        func isOrphanedLegacyId(_ id: String) -> Bool {
            !id.contains("-") && !connectedLegacyIds.contains(id)
        }
        enabledScreens = enabledScreens.filter { !isOrphanedLegacyId($0) }
        wallpapers = wallpapers.filter { !isOrphanedLegacyId($0.key) }
    }

    static func mainScreenId() -> String {
        guard let main = NSScreen.main else { return "0" }
        return screenId(for: main)
    }

    static func screenName(for screen: NSScreen) -> String {
        screen.localizedName
    }

    // MARK: - Persistence

    private func saveWallpapers() {
        if let data = try? JSONEncoder().encode(wallpapers) {
            UserDefaults.standard.set(data, forKey: "ScreenWallpapers")
        }
        // Keep legacy key updated for backward compat
        if let data = try? JSONEncoder().encode(currentWallpaper) {
            UserDefaults.standard.set(data, forKey: "CurrentWallpaper")
        }
    }
}
