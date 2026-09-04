//
//  Status.swift
//  Wallwright
//
//  Created by Haren on 2023/8/8.
//

import Cocoa

extension AppDelegate {
    // `playRate`/`playVolume` are `@Published` — Combine fires a change notification on *any*
    // assignment, even reassigning the exact same value, and every view holding `wallpaperViewModel`
    // as an `@ObservedObject` (including `ContentView`, whose body is the entire Library grid) fully
    // re-renders in response. Confirmed live (2026-08-04): these were called unconditionally from
    // `globalSettingsWhenApplicationDidBecomeActive()`'s resume/unmute paths on every app
    // activation, regardless of whether the wallpaper was actually paused/muted at the time —
    // routine clicking inside Wallwright's own window can trigger app-activation events, so this
    // was forcing a full app-wide re-render (grid included) on plain, everyday interaction. Guarding
    // each one so it only assigns when the value would actually change fixes that at the source,
    // rather than in every caller.
    @objc func mute() {
        guard self.wallpaperViewModel.playVolume != 0 else { return }
        self.wallpaperViewModel.playVolume = 0
    }

    @objc func unmute() {
        let target = self.wallpaperViewModel.lastPlayVolume == 0 ? 1 : self.wallpaperViewModel.lastPlayVolume
        guard self.wallpaperViewModel.playVolume != target else { return }
        self.wallpaperViewModel.playVolume = target
    }

    @objc func pause() {
        guard self.wallpaperViewModel.playRate != 0 else { return }
        self.wallpaperViewModel.playRate = 0
    }

    @objc func resume() {
        // A "Stop (free memory)" policy tears down the decoder and hides the window (see
        // `WallpaperViewModel.isStopped`) — neither of those undoes on its own just because
        // `playRate` changes. Without this, a manual Resume (menu, hotkey, WallpaperPreview's
        // play button, the `resume` CLI command — all of them funnel through here) while stopped
        // left the user stuck: `playRate` flips to 1, but there's no item to play and no visible
        // window, with no way out short of waiting for the original stop trigger to clear itself.
        if self.wallpaperViewModel.isStopped {
            self.wallpaperViewModel.isStopped = false
            for window in self.wallpaperWindows.values { window.orderFront(nil) }
        }
        let target = self.wallpaperViewModel.lastPlayRate == 0 ? 1 : self.wallpaperViewModel.lastPlayRate
        guard self.wallpaperViewModel.playRate != target else { return }
        self.wallpaperViewModel.playRate = target
    }

    @objc func togglePause() {
        if wallpaperViewModel.playRate == 0 {
            wallpaperViewModel.isPausedByUser = false
            resume()
        } else {
            wallpaperViewModel.isPausedByUser = true
            pause()
        }
    }

    @objc func toggleMute() {
        if wallpaperViewModel.playVolume == 0 {
            wallpaperViewModel.isMutedByUser = false
            unmute()
        } else {
            wallpaperViewModel.isMutedByUser = true
            mute()
        }
    }

    @objc func toggleClockOverlay() {
        globalSettingsViewModel.settings.showClockOverlay.toggle()
    }

    /// "Next Wallpaper" — advances the active playlist if one's running; otherwise falls back to
    /// cycling through the whole library, so this hotkey/menu item does something useful even when
    /// you're not using a playlist at all.
    @objc func skipToNextPlaylistItem() {
        if playlistViewModel.isActive {
            playlistViewModel.skip(direction: .next)
        } else {
            wallpaperViewModel.advanceToNextWallpaper()
        }
    }

    /// Same fallback as `skipToNextPlaylistItem` above — was missing entirely, so this hotkey/menu
    /// item/CLI command silently did nothing whenever no playlist was active (`PlaylistViewModel
    /// .skip` no-ops via its own `guard isActive`).
    @objc func skipToPreviousPlaylistItem() {
        if playlistViewModel.isActive {
            playlistViewModel.skip(direction: .previous)
        } else {
            wallpaperViewModel.advanceToPreviousWallpaper()
        }
    }

    @objc func togglePlaylistPin() {
        playlistViewModel.isPinned.toggle()
    }

    /// Manual escape hatch for `AerialsInjector`'s documented flakiness (a second consecutive
    /// lock-screen/screensaver activation can come up blank even though the on-disk registration
    /// is unchanged — see that file's own doc comments). Re-injects the current video and restarts
    /// `WallpaperAgent`, the same recovery the 5-minute automatic health check already does, just
    /// available on demand instead of waiting.
    @objc func refreshVideoWallpaper() {
        AerialsInjector.shared.prewarmForNextActivation()
    }

    @objc func openDisplaySettingsFromMenu() {
        openMainWindow()
        contentViewModel.isDisplaySettingsReveal = true
    }

    @objc func selectRecentWallpaper(_ sender: NSMenuItem) {
        guard let wallpaper = sender.representedObject as? WEWallpaper else { return }
        wallpaperViewModel.nextCurrentWallpaper = wallpaper
        playlistViewModel.wallpaperWasManuallyPicked(wallpaper)
    }

    func buildRecentWallpapersMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Recent Wallpapers"))
        // The menu bar is a quick-access list, not a full history browser — cap it well below
        // what's actually retained (up to 10, see WallpaperViewModel.maxRecents) so it stays fast
        // to scan.
        let recents = wallpaperViewModel.recentWallpapers.prefix(4)

        if recents.isEmpty {
            menu.addItem(NSMenuItem(title: String(localized: "No recent wallpapers"), action: nil, keyEquivalent: ""))
        } else {
            for wallpaper in recents {
                let title = wallpaper.project.title.isEmpty ? "Untitled" : wallpaper.project.title
                let typeLabel = wallpaper.project.type.isEmpty ? "" : " (\(wallpaper.project.type.capitalized))"
                let item = NSMenuItem(title: "\(title)\(typeLabel)", action: #selector(selectRecentWallpaper(_:)), keyEquivalent: "")
                item.representedObject = wallpaper
                item.target = self
                menu.addItem(item)
            }
        }

        return menu
    }

    /// Built fresh each time the menu opens (see menuWillOpen) since it varies with playback
    /// state — empty entirely while no playlist is active, matching buildRecentWallpapersMenu's
    /// rebuild-on-open approach rather than trying to keep a static section live-synced.
    func buildNowPlayingItems() -> [NSMenuItem] {
        guard playlistViewModel.isActive else { return [] }

        let currentWallpaper = wallpaperViewModel.wallpaper(for: playlistViewModel.drivingScreenId)
        var title = currentWallpaper.project.title.isEmpty ? "Untitled" : currentWallpaper.project.title
        // Plain NSMenuItem titles never truncate on macOS — the whole menu sizes itself to its
        // single widest item, and every other row's trailing content then right-aligns to that
        // same shared edge. A 28-char cap still measured ~565px once combined with "Now Playing: "
        // and was the actual reason the whole menu (every row, not just this one) rendered wide —
        // cut much shorter, and drop the redundant prefix (an icon plus sitting directly above
        // Previous/Next/Pin already makes "this is what's playing" obvious).
        if title.count > 20 {
            title = String(title.prefix(20)) + "…"
        }

        let nowPlayingItem = NSMenuItem(title: title, systemImage: "play.circle.fill", action: nil, keyEquivalent: "")
        nowPlayingItem.isEnabled = false

        // Right-aligned shortcut hint via ShortcutMenuItemView, same reasoning as Mute/Pause below
        // — a real keyEquivalent here would double-fire against the Carbon global hotkey.
        let previousItem = NSMenuItem.withShortcutHint(
            title: String(localized: "Previous"), systemImage: "backward.fill",
            shortcut: globalSettingsViewModel.settings.playlistPreviousHotkey?.displayString ?? "",
            target: self, action: #selector(skipToPreviousPlaylistItem)
        )

        let nextItem = NSMenuItem.withShortcutHint(
            title: String(localized: "Next"), systemImage: "forward.fill",
            shortcut: globalSettingsViewModel.settings.playlistNextHotkey?.displayString ?? "",
            target: self, action: #selector(skipToNextPlaylistItem)
        )

        let pinItem = NSMenuItem(title: String(localized: "Pin Current Wallpaper"), systemImage: "pin.fill", action: #selector(togglePlaylistPin), keyEquivalent: "")
        pinItem.target = self
        pinItem.state = playlistViewModel.isPinned ? .on : .off

        return [.separator(), nowPlayingItem, previousItem, nextItem, pinItem]
    }

    func setStatusMenu() {
        // Recent Wallpapers Submenu
        let recentWallpapersMenuItem = NSMenuItem(title: String(localized: "Recent Wallpapers"), action: nil, keyEquivalent: "")
        recentWallpapersMenuItem.submenu = buildRecentWallpapersMenu()

        // System usage — sampled fresh each time the menu opens (see menuWillOpen), not on a timer.
        // Held as a stored property rather than looked up by title, since its title is exactly
        // what gets overwritten with each live reading.
        systemUsageMenuItem = NSMenuItem(title: String(localized: "System Usage"), action: nil, keyEquivalent: "")
        systemUsageMenuItem.isEnabled = false

        let menu = NSMenu()
        menu.delegate = self
        menu.items = [
            systemUsageMenuItem,

            .separator(),

            .init(title: String(localized: "Show Wallwright"),
                  systemImage: "photo",
                  action: #selector(openMainWindow),
                  keyEquivalent: "o"),

            recentWallpapersMenuItem,

            .separator(),

            .init(title: String(localized: "Displays"),
                  systemImage: "display",
                  action: #selector(openDisplaySettingsFromMenu),
                  keyEquivalent: "d"),

            .init(title: String(localized: "Settings"),
                  systemImage: "gearshape.fill",
                  action: #selector(openSettingsWindow),
                  keyEquivalent: ","),

            .separator(),

            NSMenuItem.withShortcutHint(
                title: String(localized: "Mute"), systemImage: "speaker.slash.fill",
                shortcut: "", target: self, action: #selector(toggleMute)
            ),

            NSMenuItem.withShortcutHint(
                title: String(localized: "Pause"), systemImage: "pause.fill",
                shortcut: "", target: self, action: #selector(togglePause)
            ),

            .separator(),

            .init(title: String(localized: "Refresh Video Wallpaper"),
                  systemImage: "arrow.clockwise",
                  action: #selector(refreshVideoWallpaper),
                  keyEquivalent: ""),

            .init(title: String(localized: "Quit"),
                  systemImage: "power",
                  action: #selector(NSApplication.terminate(_:)),
                  keyEquivalent: "q")
        ]

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.menu = menu

        if let button = self.statusItem.button {
            if let image = NSImage(named: "we.logo") {
                image.isTemplate = true
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "play.desktopcomputer", accessibilityDescription: nil)
            }
        }
    }
}

// MARK: - NSMenuDelegate — refresh Recent Wallpapers on menu open

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Update the Recent Wallpapers submenu each time the status bar menu opens
        if let recentItem = menu.items.first(where: { $0.title == String(localized: "Recent Wallpapers") }) {
            recentItem.submenu = buildRecentWallpapersMenu()
        }

        // Rebuild the Now Playing section — remove whatever was inserted last time (item count
        // varies with playback state, so unlike Recent Wallpapers this can't just swap a submenu),
        // then insert the fresh set right after Recent Wallpapers.
        for item in nowPlayingMenuItems { menu.removeItem(item) }
        nowPlayingMenuItems = buildNowPlayingItems()
        if !nowPlayingMenuItems.isEmpty,
           let recentIndex = menu.items.firstIndex(where: { $0.title == String(localized: "Recent Wallpapers") }) {
            for (offset, item) in nowPlayingMenuItems.enumerated() {
                menu.insertItem(item, at: recentIndex + 1 + offset)
            }
        }

        // Sample CPU/memory only while the menu is actually open being looked at — not on a timer.
        // `sample()`'s CPU reading spans several seconds of wall-clock time (see its own doc
        // comment for why), so doing that synchronously here would visibly freeze the menu right
        // as it opens. Showing a placeholder immediately and filling in the real value a beat
        // later off the main thread keeps the menu itself opening instantly.
        systemUsageMenuItem.title = String(localized: "System Usage: …")
        // A short head start before the CPU sample's own window begins — confirmed live
        // (2026-08-09) that without this, the menu's own construction (this method, plus AppKit's
        // subsequent layout/draw of the menu appearing on screen) could still be finishing up right
        // as `getrusage(RUSAGE_SELF, ...)` took its first snapshot. That call sums CPU time across
        // every thread in the process, not just the one measuring, so a real but brief and
        // self-inflicted burst from the menu opening itself was getting counted as if it were
        // ongoing load — e.g. reading "CPU 5.1%" for a process `top` confirmed was at 0.0% moments
        // before and after. 200ms is enough for that to have settled without making the reading
        // noticeably slower to appear.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let formatted = SystemUsageMonitor.sample()?.formatted ?? String(localized: "System Usage Unavailable")
            DispatchQueue.main.async {
                self?.systemUsageMenuItem.title = formatted
            }
        }

        // Hint the real configured global hotkey on Mute/Unmute and Pause/Resume — these items
        // used to carry their own local "⌘M"/"⌘P" key equivalents that didn't match the actual
        // (Settings > Hotkeys-configurable) global shortcut at all, which was actively misleading.
        // Drawn via ShortcutMenuItemView (right-aligned, purely cosmetic) rather than a real
        // keyEquivalent, which would double-fire against the Carbon global hotkey.
        let settings = globalSettingsViewModel.settings
        for item in menu.items {
            guard let view = item.view as? ShortcutMenuItemView else { continue }
            // Matched by `action`, not `item.title` — title is locale-dependent (these rows are
            // built via `String(localized:)`) and also flips between two strings ("Mute"/"Unmute",
            // "Pause"/"Resume") as playback state changes, neither of which `action` does.
            switch view.action {
            case #selector(AppDelegate.toggleMute): view.setShortcut(settings.muteHotkey?.displayString ?? "")
            case #selector(AppDelegate.togglePause): view.setShortcut(settings.pauseHotkey?.displayString ?? "")
            default: break
            }
        }
    }
}
