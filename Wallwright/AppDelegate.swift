//
//  AppDelegate.swift
//  Wallwright
//
//  Created by Haren on 2023/6/6.
//

import Cocoa
import SwiftUI
import AVKit
import os

/// Temporary diagnostic logging for the lock/screensaver "paused but not paused" bug — same
/// subsystem/category as `VideoWallpaperViewModel`'s own instance so both interleave in one query.
private let wallpaperDebugLog = Logger(subsystem: "com.wallwright.Wallwright", category: "VideoWallpaperDebug")

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    
    var statusItem: NSStatusItem!
    var systemUsageMenuItem: NSMenuItem!
    /// Items inserted for the "Now Playing" playlist section — tracked so `menuWillOpen(_:)` can
    /// remove exactly these before rebuilding, since (unlike Recent Wallpapers) this section's
    /// item count varies: present only while a playlist is active, absent otherwise.
    var nowPlayingMenuItems: [NSMenuItem] = []
    var settingsWindow: NSWindow!
    
    var mainWindowController: MainWindowController!
    
    var wallpaperWindows: [String: NSWindow] = [:]
    var clockWindows: [String: NSWindow] = [:]
    
    var contentViewModel = ContentViewModel()
    var wallpaperViewModel = WallpaperViewModel()
    var globalSettingsViewModel = GlobalSettingsViewModel()
    var playlistViewModel = PlaylistViewModel()
    var inboxLinksStore = InboxLinksStore()
    
    var importOpenPanel: NSOpenPanel!

    /// Held for the app's entire lifetime to disable App Nap. Confirmed live via a CPU-sampling
    /// watch: this process sat at 3-5% CPU (actively decoding) for the first ~60 seconds after the
    /// screen locked, then flatlined to ~0% and stayed there — the classic App Nap signature, not
    /// anything specific to lock/display-sleep handling. Our wallpaper window can never become key
    /// or main by design (see WallpaperWindow below), which is exactly the profile App Nap targets
    /// once a window is fully occluded (guaranteed the moment the lock screen engages) for long
    /// enough. Without this, video decode (and therefore audio) silently stops mid-lock/screensaver
    /// even though nothing in our own code ever paused it.
    ///
    /// Uses `.userInitiatedAllowingIdleSystemSleep`, not the stronger `.userInitiated` this
    /// originally shipped with — confirmed live (2026-08-12) via `pmset -g assertions` that
    /// `.userInitiated` doesn't just exempt this process from App Nap, it also asserts
    /// `PreventUserIdleSystemSleep` for as long as it's held, i.e. for the app's entire lifetime.
    /// That meant the whole Mac never idle-slept while Wallwright was running, full stop — not a
    /// screen-stays-awake-while-a-video-plays situation, an actual "this laptop was on all day"
    /// bug. App Nap and idle system sleep are separate, unrelated mechanisms: exempting this
    /// process from the former doesn't require blocking the latter, and once the system genuinely
    /// sleeps, decode stopping is correct (the whole computer is suspended) — the `Allowing`
    /// variant asks for exactly that: still exempt from App Nap, but no opinion on system sleep.
    private var appNapActivity: NSObjectProtocol?

    static var shared = AppDelegate()
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Every browse tab (MotionBgs, MoeWalls, Wallper, DesktopHut, UHDPaper, AlphaCoders) loads
        // its thumbnails through plain `AsyncImage`/`RetryingAsyncImage`, which both go through
        // `URLSession.shared` and, by default, Foundation's own `URLCache.shared` — never
        // explicitly sized anywhere in this app, so it was left at whatever Foundation's own
        // undocumented default happens to be. Set explicitly before any image fetch can possibly
        // start, so this cache actually has a real, known, bounded ceiling instead of an
        // unaccountable one. Set on `URLCache.shared` (not a dedicated `URLSession`) since that's
        // exactly the cache `URLSession.shared` — and therefore every plain `AsyncImage` in this
        // app — already reads from.
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)

        // 创建设置视窗
        setSettingsWindow()
        
        // 创建桌面壁纸视窗
        setWallpaperWindows()

        // 监听显示器连接/断开
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Inbox: reuses notifications this app already subscribes to elsewhere for the same reason
        // (LockScreenSync/FullscreenAppMonitor react to unlock; VideoWallpaperViewModel/
        // GlobalSettingsService react to wake) — network state doesn't survive sleep or a lock
        // cycle, so the SSE connection needs the same "re-establish on these exact transitions"
        // treatment, not a new timer. `start()` is idempotent (see InboxTransport's own doc
        // comment), so calling it from four places costs nothing beyond the first real connect
        // (or first reconnect after an actual drop).
        ActiveInboxTransport.shared.onLinkReceived = { [weak self] url in
            self?.inboxLinksStore.add(urlString: url)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(inboxTransportShouldReconnect),
            name: LockScreenSync.screenDidUnlockNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(inboxTransportShouldReconnect),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )
        ActiveInboxTransport.shared.start()

        // 创建化左上角菜单栏
        setMainMenu()
        
        // 创建化右上角常驻菜单栏
        setStatusMenu()
        
        // 创建主视窗
        self.mainWindowController = MainWindowController()
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // NSMenu.copy() archives/unarchives each item via NSKeyedArchiver, which requires every
        // custom NSMenuItem.view to conform to NSCoding — ShortcutMenuItemView doesn't (full
        // NSCoding support for a view holding a Selector + weak target isn't worth it for a
        // cosmetic row), so a naive `.copy()` here crashed instantly the moment a Dock right-click
        // needed to duplicate a Mute/Pause item (confirmed via crash log: fatalError inside
        // ShortcutMenuItemView.init(coder:)). Building a fresh menu by hand sidesteps NSCoding
        // entirely instead of trying to make the view archivable.
        guard let sourceItems = self.statusItem.menu?.items else { return nil }
        let dockMenu = NSMenu()
        for item in sourceItems {
            // System Usage doesn't belong in the Dock menu — it's a one-shot copy of whatever
            // text was last sampled for the status bar menu (menuWillOpen refreshes it live, but
            // the Dock menu has no equivalent hook), so it would just show stale CPU/Memory
            // numbers frozen at some earlier point rather than anything current.
            guard item !== systemUsageMenuItem else { continue }
            if let shared = item.view as? ShortcutMenuItemView {
                let fresh = NSMenuItem(title: item.title, action: item.action, keyEquivalent: "")
                let view = shared.rebuildFreshView()
                view.menuItem = fresh
                fresh.view = view
                dockMenu.addItem(fresh)
            } else if item.isSeparatorItem {
                // Skip a separator immediately following another separator (or opening the
                // menu) — dropping System Usage above would otherwise leave two back-to-back
                // separators with nothing between them.
                if dockMenu.items.last?.isSeparatorItem != false { continue }
                dockMenu.addItem(.separator())
            } else {
                let copy = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.keyEquivalent)
                copy.target = item.target
                copy.image = item.image
                copy.submenu = item.submenu
                copy.isEnabled = item.isEnabled
                dockMenu.addItem(copy)
            }
        }
        dockMenu.items.removeLast() // Remove `Quit` menu item
        return dockMenu
    }
    
// MARK: - delegate methods
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable App Nap for the whole app lifetime — see appNapActivity's doc comment. Held,
        // never ended, since a wallpaper needs to keep rendering/playing for as long as the app runs.
        // `.userInitiatedAllowingIdleSystemSleep`, not `.userInitiated` — see appNapActivity's doc
        // comment for why the stronger option was silently keeping the whole Mac from ever sleeping.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Continuous video wallpaper playback"
        )

        saveCurrentWallpaper()
        // Skip for video wallpapers, same as didCurrentWallpaperChange does — calling
        // setDesktopImageURL for a video creates a second, competing wallpaper choice that fights
        // AerialsInjector's own registration (root-caused earlier: the aerials extension launches
        // but decodes zero frames when this happens). This unconditional startup call was
        // reintroducing that exact bug on every launch.
        if wallpaperViewModel.currentWallpaper.project.type != "video" {
            let wallpaper = wallpaperViewModel.currentWallpaper
            // `setPlacehoderWallpaper` is a plain synchronous call (see its own doc comment) —
            // dispatched here, same as `didCurrentWallpaperChange`, so a slow `setDesktopImageURL`
            // IPC call doesn't stall app launch on the main thread.
            DispatchQueue.global(qos: .utility).async {
                AppDelegate.shared.setPlacehoderWallpaper(with: wallpaper)
            }
        } else {
            // Explicit, deterministic re-injection at launch for the video case — mirrors
            // `didCurrentWallpaperChange`'s own video branch. Confirmed live (2026-07-31) that
            // relying solely on that reactive path firing at launch (via
            // `GlobalSettingsService.didFinishLaunchingNotification`'s `$wallpapers` subscription,
            // which only re-syncs if its "fires immediately on subscribe" emission happens to land
            // after `wallpapers` is actually populated) isn't reliable enough on its own: after
            // quitting or an OS restart, a stale aerial registration from the *previous* session
            // was found left dangling in the Store, producing inconsistent stale/frozen/blank
            // wallpaper state per screen until something unrelated forced a resync. This call can
            // race the reactive path also firing at launch for the same wallpaper — that used to
            // mean two full `killall WallpaperAgent` restarts for one real "app started" event
            // (confirmed live 2026-08-31, `AerialsInjector.inject()` always restarts, it's not
            // actually cheap to call twice); `AerialsInjector.inject()` now debounces a same-URL
            // re-injection on its own, so this call staying here is safe regardless of whether the
            // reactive path also fires.
            let wallpaper = wallpaperViewModel.currentWallpaper
            DispatchQueue.global(qos: .utility).async {
                let videoURL = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
                AerialsInjector.shared.inject(videoURL: videoURL, name: wallpaper.project.title)
            }
        }
        registerBundledClockFonts()
        LockScreenSync.shared.start()
        AerialsInjector.shared.resumeHealthMonitoringIfNeeded()
        CommandListener.shared.start()

        // 显示桌面壁纸
        for (_, window) in self.wallpaperWindows {
            window.orderFront(nil)
        }
        // Clock windows are created reactively by GlobalSettingsService's settings subscription,
        // which fires immediately on subscribe with the current value — calling setClockWindows()
        // here too would create a second, orphaned set that never gets cleaned up.

        if globalSettingsViewModel.isFirstLaunch {
            self.mainWindowController.window.center()
            self.mainWindowController.window.makeKeyAndOrderFront(nil)
        }
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        wallpaperDebugLog.notice("applicationDidBecomeActive fired")
        NSApp.activate(ignoringOtherApps: true)
        ActiveInboxTransport.shared.start()
    }

    /// Shared by the unlock and system-wake observers registered in `applicationDidFinishLaunching`
    /// — both just mean "the network connection may have dropped, try reconnecting," and `start()`
    /// is already a no-op if the connection is still alive.
    @objc private func inboxTransportShouldReconnect() {
        ActiveInboxTransport.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        wallpaperDebugLog.notice("applicationShouldHandleReopen fired — hasVisibleWindows=\(flag), mainWindow.isVisible=\(self.mainWindowController.window.isVisible), settingsWindow.isVisible=\(self.settingsWindow.isVisible)")
        if !self.mainWindowController.window.isVisible && !settingsWindow.isVisible {
            wallpaperDebugLog.notice("applicationShouldHandleReopen — calling makeKeyAndOrderFront")
            self.mainWindowController.window?.makeKeyAndOrderFront(nil)
        }

        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Backstop for every UserDefaults write in the app, not just GlobalSettingsService's own
        // (which already synchronizes on every save) — covers recent wallpapers, hidden MotionBgs
        // items, and anything else written to standard defaults elsewhere.
        UserDefaults.standard.synchronize()

        // Tear down the aerial registration BEFORE restoring the original desktop image below —
        // confirmed live (2026-07-31) that leaving it in place on quit left the Store/Index.plist
        // lock/idle slots pointing at a video with no Wallwright process left running to maintain
        // it (health-monitoring, WallpaperAgent prewarming), producing stale/frozen/blank wallpaper
        // state that varied per screen and got worse across a subsequent lock/unlock, until the
        // next full relaunch happened to resync things. Mirrors the exact cleanup
        // `didCurrentWallpaperChange`'s non-video branch already does when switching away from a
        // video wallpaper while the app keeps running — quitting deserves the same clean teardown.
        // Deliberately synchronous here (not dispatched to a background queue like most of
        // `AerialsInjector`'s other call sites): this needs to fully finish before the process
        // actually exits, which an async dispatch can't guarantee.
        AerialsInjector.shared.remove()

        if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(wallpaper, for: screen)
            }
        }
        
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        do {
            let filesURL = try FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)
            for url in filesURL {
                if url.lastPathComponent.contains("staticWP") {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            print(error)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

// MARK: - misc methods
    @objc func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow.center()
        self.settingsWindow.makeKeyAndOrderFront(nil)
    }
    
    @objc func openMainWindow() {
        wallpaperDebugLog.notice("openMainWindow() called")
        self.mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
// MARK: Set Settings Window
    func setSettingsWindow() {
        self.settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        self.settingsWindow.title = "Settings"
        self.settingsWindow.isReleasedWhenClosed = false
        self.settingsWindow.toolbarStyle = .preference
        
        self.settingsWindow.delegate = self
        
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        
        toolbar.selectedItemIdentifier = SettingsToolbarIdentifiers.performance
        
        self.settingsWindow.toolbar = toolbar
        self.settingsWindow.contentView = NSHostingView(rootView: SettingsView().environmentObject(self.globalSettingsViewModel))
    }
    
// MARK: Set Wallpaper Windows - One per screen
    func setWallpaperWindows() {
        for screen in NSScreen.screens {
            let screenId = WallpaperViewModel.screenId(for: screen)
            guard wallpaperViewModel.isScreenEnabled(screenId) else { continue }

            let window = WallpaperWindow()
            window.styleMask = [.borderless, .fullSizeContentView]
            window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.stationary, .canJoinAllSpaces]
            window.setFrame(screen.frame, display: true)
            window.isMovable = false
            // Never left at NSWindow's default background (a light system color) — anything the
            // player layer doesn't cover for even a moment (a frame swap, the brief gap before the
            // first frame decodes) showed through as a white border around the video. Black matches
            // StaticImageWallpaperView's own backstop, so video and image wallpapers look consistent.
            window.backgroundColor = .black
            window.isOpaque = true
            // NSWindow's default `hasShadow = true` was never overridden here — for a borderless,
            // desktop-level backdrop window this has no visual purpose, but the shadow itself still
            // rendered: a soft, LIGHTER gradient right along the window's own edges. Confirmed live
            // via screenshot: this is what showed up as a thin bright seam at the boundary between
            // two adjacent displays' wallpaper windows (and is the more likely real explanation for
            // the original border report too, not the AVPlayerView sizing/background fixes above).
            window.hasShadow = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.canHide = false
            window.canBecomeVisibleWithoutLogin = true
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView:
                WallpaperView(viewModel: self.wallpaperViewModel, screenId: screenId)
            )
            wallpaperWindows[screenId] = window
        }
    }

    /// Rebuild wallpaper windows without changing enabled state.
    func rebuildWallpaperWindows() {
        for (_, window) in wallpaperWindows { window.close() }
        wallpaperWindows.removeAll()
        setWallpaperWindows()
        for (_, window) in wallpaperWindows { window.orderFront(nil) }
    }

    /// Called when monitors connect/disconnect — auto-enables newly connected screens.
    /// `didChangeScreenParametersNotification` is documented to fire multiple times for a single
    /// real event (resolution change, dock/undock, sleep/wake with an external display attached —
    /// often several intermediate fires, sometimes with genuinely different intermediate signatures,
    /// as the OS settles on a final configuration). Rebuilding every wallpaper/clock window (tearing
    /// down and recreating every `AVPlayer`) on each spurious fire is wasted decode/GPU work and can
    /// cause a visible flicker. Debounced on top of the signature check below — the signature check
    /// alone only catches an exact-duplicate re-fire, not a burst of several different-but-transient
    /// configurations, so only whatever's still current after a short quiet period actually rebuilds.
    private var lastScreenConfigurationSignature: String?
    private var pendingScreensChangedWorkItem: DispatchWorkItem?

    @objc func screensChanged() {
        wallpaperDebugLog.notice("screensChanged() notification received — debouncing 0.5s")
        pendingScreensChangedWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let signature = Self.screenConfigurationSignature()
            guard signature != self.lastScreenConfigurationSignature else {
                wallpaperDebugLog.notice("screensChanged() — signature unchanged, skipping rebuild")
                return
            }
            self.lastScreenConfigurationSignature = signature

            let connectedIds = Set(NSScreen.screens.map { WallpaperViewModel.screenId(for: $0) })
            for id in connectedIds where !self.wallpaperViewModel.enabledScreens.contains(id) {
                self.wallpaperViewModel.enabledScreens.insert(id)
            }
            wallpaperDebugLog.notice("screensChanged() — signature CHANGED, rebuilding wallpaper windows")
            self.rebuildWallpaperWindows()
            self.rebuildClockWindows()
        }
        pendingScreensChangedWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private static func screenConfigurationSignature() -> String {
        NSScreen.screens
            .map { "\(WallpaperViewModel.screenId(for: $0))@\($0.frame.debugDescription)" }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: Set Clock Overlay Windows — one per enabled screen, only when the setting is on
    func setClockWindows() {
        guard globalSettingsViewModel.settings.showClockOverlay else { return }
        for screen in NSScreen.screens {
            let screenId = WallpaperViewModel.screenId(for: screen)
            guard wallpaperViewModel.isScreenEnabled(screenId) else { continue }
            let window = ClockOverlayWindow(screen: screen)
            clockWindows[screenId] = window
            window.orderFront(nil)
        }
    }

    func rebuildClockWindows() {
        for (_, window) in clockWindows { window.close() }
        clockWindows.removeAll()
        setClockWindows()
    }
    
    func windowWillClose(_ notification: Notification) {
        globalSettingsViewModel.reset()
    }
    
    func saveCurrentWallpaper() {
        // Both can legitimately be nil (no main screen during a display reconfiguration/sleep-wake
        // transition; no desktop image URL for some system wallpaper configurations e.g. a solid
        // color) — force-unwrapping either was a real, if rare, crash vector. Bailing out here just
        // skips this save; the next call (this runs periodically elsewhere) picks it up normally.
        guard let mainScreen = NSScreen.main,
              let osWallpaper = NSWorkspace.shared.desktopImageURL(for: mainScreen)
        else { return }
        var wallpaper: URL {
            if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
                if wallpaper != osWallpaper {
                    if !wallpaper.lastPathComponent.contains("staticWP") {
                        return wallpaper
                    }
                }
            }
            return osWallpaper
        }
        UserDefaults.standard.set(wallpaper, forKey: "OSWallpaper")
    }
    
    /// Guards the image branch below against redundant `setDesktopImageURL` calls — see its own
    /// comment for why that call is expensive. Not persisted: a fresh launch should always run it
    /// at least once, since nothing guarantees the OS's own desktop picture still matches what we
    /// last set (a macOS update, a reset, another app changing it).
    private var lastPlaceholderImageURL: URL?

    func setPlacehoderWallpaper(with wallpaper: WEWallpaper) {
        switch wallpaper.project.type {
        case "video":
            let asset = AVAsset(url: wallpaper.wallpaperDirectory.appending(component: wallpaper.project.file))
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            
            let time = CMTimeMake(value: 1, timescale: 1) // 第一帧的时间
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
                if let error = error {
                    print(error)
                } else if let cgImage = cgImage {
                    // Build the TIFF data directly from the CGImage via NSBitmapImageRep, not by
                    // wrapping it in a zero-sized NSImage first and asking for .tiffRepresentation
                    // — that indirection was producing a corrupted (grayscale, partially mirrored)
                    // render, visible as the "hero" preview and "Your Photos" entry in System
                    // Settings' Wallpaper pane. AerialsInjector's own thumbnail generation uses
                    // this same direct NSBitmapImageRep path and has never shown this problem.
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let data = rep.representation(using: .tiff, properties: [:]) {
                        do {
                            // Always the same filename — Swift's .hashValue is randomized per
                            // process launch, not stable, so hashing into the name here would
                            // leak a new file (and a new macOS "recently used wallpaper" entry)
                            // on every single app launch instead of overwriting one.
                            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "staticWP_current.tiff")
                            try data.write(to: url, options: .atomic)
                            for screen in NSScreen.screens {
                                try NSWorkspace.shared.setDesktopImageURL(url, for: screen)
                            }
                        } catch {
                            print(error)
                        }
                    }
                }
            }
        case "image":
            // Already a directly-settable desktop picture — no frame-grab, no TIFF re-encode,
            // no intermediate cache file needed (unlike video, which has to be decoded into a
            // still first). `setDesktopImageURL` itself is a slow, synchronous IPC call to the
            // Dock/WallpaperAgent (confirmed live: blocked the main thread for 1-2s per switch) —
            // deliberately NOT dispatched to a background queue *here*, though: every call site
            // is responsible for its own dispatch (see `didCurrentWallpaperChange`), so this stays
            // a plain synchronous call and callers control exactly when it runs relative to
            // anything else that might also touch WallpaperAgent (e.g. AerialsInjector.remove()'s
            // restart) — self-dispatching here previously raced against that from a different call
            // site, since two independent `.async` calls to the same concurrent queue have no
            // ordering guarantee relative to each other.
            //
            // Gated on the URL actually changing: `didCurrentWallpaperChange`'s caller subscribes
            // to the whole `$wallpapers` dictionary (every screen), not just this one, so with a
            // multi-display setup, changing screen 2's wallpaper redundantly re-fired this for
            // screen 1 too — confirmed live (2026-08-07) that meant this "slow, 1-2s" call was
            // running again for no reason on every unrelated screen's wallpaper change.
            let url = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
            if url != lastPlaceholderImageURL {
                for screen in NSScreen.screens {
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(url, for: screen)
                    } catch {
                        print(error)
                    }
                }
                lastPlaceholderImageURL = url
            }
            // Reverted: registering this image as the system's "Idle" (screensaver) choice too,
            // via a `killall WallpaperAgent` restart on every real wallpaper switch. Confirmed live
            // (2026-08-07) that restart is disruptive enough on its own to read as a visible
            // freeze/hang when switching wallpapers, and the actual payoff (whether an idle-
            // triggered screensaver would even render the image correctly through
            // `WallpaperImageExtension.appex`) was never confirmed either way. Not a good trade —
            // manual lock already shows this wallpaper correctly by reading the Desktop choice.
        default:
            return
        }
    }
}

/// Non-interactive window that stays behind all other windows.
class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum SettingsToolbarIdentifiers {
    static let performance = NSToolbarItem.Identifier(rawValue: "performance")
    static let general = NSToolbarItem.Identifier(rawValue: "general")
    static let hotkeys = NSToolbarItem.Identifier(rawValue: "hotkeys")
    static let about = NSToolbarItem.Identifier(rawValue: "about")
}
