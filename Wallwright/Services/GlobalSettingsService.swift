//
//  GlobalSettingsService.swift
//  Wallwright
//
//  Created by Haren on 2023/9/2.
//

import Cocoa
import Combine
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox
import os

private let wallpaperDebugLog2 = Logger(subsystem: "com.wallwright.Wallwright", category: "VideoWallpaperDebug")

enum GSPlayback: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case keepRunning, mute, pause, stop
}

/// Where the clock actually sits on screen is purely drag-and-drop now (see `clockDraggable`/
/// `clockCustomOrigins`) — this only controls how its lines align to each other within that
/// draggable block (ragged-left, centered, or ragged-right), the same way a text editor's
/// alignment buttons would, not where the block itself lives on the desktop.
enum GSClockTextAlignment: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case left, center, right

    var label: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }
}

/// Named "Format" rather than "Font" in the UI — every case but `summit` really is just a font
/// swap for the day line, but `summit` selects a whole different layout (greeting + time-of-day
/// word + divider lines, ported from the Summit Rainmeter skin — see `ClockOverlayView`'s Summit
/// rendering path), not something a single font substitution could express.
enum GSClockFormat: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case system, anurati, quicksand, electroharmonix, summit

    var label: String {
        switch self {
        case .system: return "System"
        case .anurati: return "Anurati"
        case .quicksand: return "Quicksand"
        case .electroharmonix: return "Electroharmonix"
        case .summit: return "Summit"
        }
    }

    /// nil means "use the system font" — resolved with a weight/size at the call site. Summit's
    /// body text (everything but the day glyph) uses Hero Bold, bundled alongside Electroharmonix
    /// from the same Rainmeter skin.
    var postscriptName: String? {
        switch self {
        case .system: return nil
        case .anurati: return "Anurati-Regular"
        case .quicksand: return "Quicksand-Bold"
        case .electroharmonix: return "Electroharmonix-Regular"
        case .summit: return "Hero-Bold"
        }
    }
}

/// A plain RGBA color, Codable independent of SwiftUI/AppKit's own (non-Codable) `Color`/`NSColor`
/// — backs the user-built custom gradient's two stops (see `GSClockColor.custom` and
/// `GlobalSettings.clockCustomGradientStart`/`End`), which need arbitrary colors a fixed enum case
/// can't hold.
struct GSColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    static let black = GSColor(red: 0, green: 0, blue: 0, opacity: 1)

    var color: Color { Color(red: red, green: green, blue: blue, opacity: opacity) }
    var nsColor: NSColor { NSColor(color) }

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    init(_ color: Color) {
        let ns = (NSColor(color).usingColorSpace(.deviceRGB)) ?? NSColor(color)
        red = ns.redComponent
        green = ns.greenComponent
        blue = ns.blueComponent
        opacity = ns.alphaComponent
    }
}

enum GSClockColor: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    // All 4 black/white combinations (both directions, both orientations) plus the user-built
    // gradient come first in `allCases` — `ClockColorPicker` shows gradients before solids, since
    // that's the more distinctive/less-common choice worth surfacing first.
    case gradientBlackToWhiteVertical, gradientWhiteToBlackVertical
    case gradientBlackToWhiteHorizontal, gradientWhiteToBlackHorizontal
    /// A user-built two-stop gradient — its actual colors/direction aren't on this case (a
    /// String-backed enum can't hold arbitrary associated data while staying simply Codable and
    /// backward-compatible with settings files saved before this existed), they live in
    /// `GlobalSettings.clockCustomGradientStart`/`End`/`Horizontal` instead. See
    /// `GlobalSettings.resolvedClockGradient`, which folds those in.
    case custom
    // Mostly neutrals plus a handful of high-contrast accents — not a full rainbow, but enough
    // that most people find something close to what they want.
    case white, black, gray, red, orange, yellow, green, mint, cyan, blue, purple, pink

    /// Solid color for the swatch preview and (for non-gradient cases) the actual text fill.
    /// Gradient cases (including `.custom`) resolve to a plain gray here — only used as a
    /// fallback since they're drawn via `gradientColors`/`resolvedClockGradient` instead.
    var color: Color {
        switch self {
        case .white: return .white
        case .black: return .black
        case .gray: return .gray
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .cyan: return .cyan
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gradientBlackToWhiteVertical, .gradientWhiteToBlackVertical,
             .gradientBlackToWhiteHorizontal, .gradientWhiteToBlackHorizontal, .custom:
            return .gray
        }
    }

    var nsColor: NSColor { NSColor(color) }

    /// Non-nil for the fixed gradient cases — (start, end) colors for the swatch preview and the
    /// actual text fill. `.custom` deliberately excluded: its colors live on `GlobalSettings`, not
    /// this case, so resolving it needs `GlobalSettings.resolvedClockGradient` instead.
    var gradientColors: (NSColor, NSColor)? {
        switch self {
        case .gradientBlackToWhiteVertical, .gradientBlackToWhiteHorizontal: return (.black, .white)
        case .gradientWhiteToBlackVertical, .gradientWhiteToBlackHorizontal: return (.white, .black)
        default: return nil
        }
    }

    var isGradient: Bool { self == .custom || gradientColors != nil }

    /// Non-nil (and matches `gradientColors`) only for the gradient cases — whether the swatch
    /// preview and actual text fill run left-to-right or top-to-bottom.
    var gradientIsHorizontal: Bool {
        switch self {
        case .gradientBlackToWhiteHorizontal, .gradientWhiteToBlackHorizontal: return true
        default: return false
        }
    }
}

enum GSAppearance: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case light, dark, followSystem
}

struct GlobalSettings: Codable, Equatable {

    // MARK: Playback
    var otherApplicationFocused = GSPlayback.keepRunning
    // Defaults to `.pause`, unlike the other four policies here — confirmed live (2026-08-09) that
    // with everything left at `.keepRunning`, the video decoder keeps running at full rate the
    // entire time the screen is locked or another app is genuinely fullscreen, even though nothing
    // on any display can possibly show it. Unlike `otherApplicationFocused` (the wallpaper can
    // still be visible around a non-fullscreen window) or `laptopOnBattery` (a real, subjective
    // battery-vs-experience tradeoff), there's no legitimate reason to prefer `.keepRunning` here —
    // this is also the mechanism that catches lock screen/screensaver, via window occlusion (see
    // FullscreenAppMonitor).
    var otherApplicationFullscreen = GSPlayback.pause
    var otherApplicationPlayingAudio = GSPlayback.keepRunning
    // Defaults to `.pause` — same reasoning as `otherApplicationFullscreen` above: a display that's
    // provably asleep cannot show anything to anyone, on any screen, so decoding through it is pure
    // waste with no offsetting benefit.
    var displayAsleep = GSPlayback.pause
    var laptopOnBattery = GSPlayback.keepRunning
    // Defaults to `.pause`, same reasoning as `otherApplicationFullscreen`/`displayAsleep` above —
    // thermal throttling or a near-empty battery are both states where nothing on any display
    // benefits from continued decode. See `PowerConditionMonitor`.
    var lowPowerConditions = GSPlayback.pause

    // MARK: Automatic Setup
    var autoStart = false

    // MARK: Inbox
    /// The ntfy.sh topic name `NtfyInboxTransport` subscribes to — deliberately empty by default,
    /// not a real value, even though this app ships with source public on GitHub: a topic is only
    /// a "loose secret," and a default value here would be committed to source and visible to
    /// anyone browsing the repo, letting them push links into any user's inbox who never bothered
    /// to set their own. Each user picks (and should keep private) their own long, hard-to-guess
    /// topic string.
    var inboxNtfyTopic = ""

    // MARK: macOS
    var adjustMenuBarTint = true

    // MARK: Appearance
    var appearance = GSAppearance.followSystem
    var showClockOverlay = false
    var clockDayFont = GSClockFormat.anurati
    var clockColor = GSClockColor.white
    /// The two stops of the user-built gradient (`GSClockColor.custom`) — each independently
    /// defaults to black, matching "gradient of [black + gradient type]" until the user picks
    /// something else for that stop.
    var clockCustomGradientStart = GSColor.black
    var clockCustomGradientEnd = GSColor.black
    var clockCustomGradientHorizontal = false
    /// Multiplies every alpha the clock overlay draws with (text, shadow, Summit's divider
    /// lines) — 1.0 is today's existing look, unchanged. Purely a draw-time value, so it doesn't
    /// affect `ClockOverlayWindow`'s size/position math and never needs a window rebuild, just a
    /// redraw (already covered by `ClockOverlayView`'s existing "redraw on any settings change"
    /// subscription).
    var clockOpacity: Double = 1.0
    var clockTextAlignment = GSClockTextAlignment.center
    /// Independent point sizes per line — each dialed in separately rather than derived from a
    /// single master size.
    var clockDayFontSize: Double = 80
    var clockDateFontSize: Double = 18
    var clockTimeFontSize: Double = 18
    var clockShowSeconds = false
    var clockUse24HourTime = false
    /// Summit format only — the top/bottom divider lines' length. Previously derived from
    /// `clockDateFontSize` (so it could never grow past whatever that was set to); broken out
    /// into its own independent slider.
    var clockSummitLineLength: Double = 30
    /// Whether the clock overlay currently accepts mouse events so it can be dragged — off by
    /// default so it stays click-through like the rest of the desktop.
    var clockDraggable = false
    /// Per-screen drag position (screenId → window origin in screen coordinates). This is now the
    /// *only* thing that decides where the clock sits on screen — until the user drags it at
    /// least once on a given screen, it just defaults to that screen's center.
    var clockCustomOrigins: [String: CGPoint]? = nil

    /// `true` for every gradient case, including `.custom` — `GSClockColor.isGradient` already
    /// covers this; kept here too so callers reading through `GlobalSettings` don't need to reach
    /// into `clockColor` separately.
    var resolvedClockIsGradient: Bool { clockColor.isGradient }

    /// Resolves `clockColor` to its actual gradient endpoints/direction, folding in
    /// `clockCustomGradientStart`/`End`/`Horizontal` when `clockColor == .custom` (a user-built
    /// gradient's colors aren't fixed on the enum case itself — see `GSClockColor.custom`'s doc
    /// comment). Every other gradient case resolves exactly as `GSClockColor.gradientColors`
    /// already did. Nil for solid colors.
    var resolvedClockGradient: (start: NSColor, end: NSColor, horizontal: Bool)? {
        if clockColor == .custom {
            return (clockCustomGradientStart.nsColor, clockCustomGradientEnd.nsColor, clockCustomGradientHorizontal)
        }
        guard let (start, end) = clockColor.gradientColors else { return nil }
        return (start, end, clockColor.gradientIsHorizontal)
    }

    // MARK: Misc
    var autoRefresh = true
    /// The `steamcmd` login name used for Workshop downloads — a one-time setup step happens
    /// outside the app (installing steamcmd and logging in once in Terminal, which caches
    /// credentials locally and handles Steam Guard interactively), and this is just which cached
    /// account the app should tell steamcmd to reuse afterward. See SteamWorkshopService.
    var steamUsername: String? = nil

    // MARK: Hotkeys
    var pauseHotkey: Hotkey? = Self.defaultPauseHotkey
    var muteHotkey: Hotkey? = Self.defaultMuteHotkey
    var clockHotkey: Hotkey? = Self.defaultClockHotkey
    var playlistNextHotkey: Hotkey? = Self.defaultPlaylistNextHotkey
    var playlistPreviousHotkey: Hotkey? = Self.defaultPlaylistPreviousHotkey

    private static let defaultPauseHotkey = Hotkey(keyCode: UInt16(kVK_ANSI_P), modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue, characters: "P")
    private static let defaultMuteHotkey = Hotkey(keyCode: UInt16(kVK_ANSI_W), modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue, characters: "W")
    private static let defaultClockHotkey = Hotkey(keyCode: UInt16(kVK_ANSI_C), modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue, characters: "C")
    // ⌃⌘S was the original default here, but that combo is already "Show Filter Results" (see
    // ReservedShortcuts.swift) — shipping a default that collides with a fixed app shortcut meant
    // every fresh install started with a conflict warning already showing. ⌃⌘N doesn't clash with
    // anything in ReservedShortcuts.all or the other configurable hotkeys' defaults above.
    private static let defaultPlaylistNextHotkey = Hotkey(keyCode: UInt16(kVK_ANSI_N), modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue, characters: "N")
    private static let defaultPlaylistPreviousHotkey = Hotkey(keyCode: UInt16(kVK_ANSI_N), modifiers: NSEvent.ModifierFlags([.command, .control, .shift]).rawValue, characters: "N")

    init() {}

    /// Hand-written instead of synthesized: the synthesized decoder uses `decode` (required, not
    /// `decodeIfPresent`) even for properties with a default value, so it throws on ANY missing
    /// key — meaning adding a single new setting field made every older saved settings file fail
    /// to decode at all, silently resetting the *entire* struct back to defaults. Confirmed live
    /// (2026-07-26) as the actual cause behind every "it reset everything" report this session.
    /// Every field below is wrapped in `try?` rather than a plain `try`: that covers both a
    /// missing key (decodeIfPresent already returns nil for that) AND a key that's present but
    /// no longer valid — e.g. removing a GSClockColor case after someone had it selected would
    /// otherwise throw on a value that exists but doesn't match any remaining case, which is a
    /// different failure mode than "missing" and wasn't covered by decodeIfPresent alone. Either
    /// way, a bad/missing field now only ever affects that one field, not the whole struct.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        otherApplicationFocused = (try? c.decodeIfPresent(GSPlayback.self, forKey: .otherApplicationFocused)) ?? nil ?? .keepRunning
        // `.pause`, not `.keepRunning` — matches the property's own new default (see its doc
        // comment). Someone who saved settings before this change never made an active choice for
        // this field either way, so there's nothing to preserve by keeping the old implicit value.
        otherApplicationFullscreen = (try? c.decodeIfPresent(GSPlayback.self, forKey: .otherApplicationFullscreen)) ?? nil ?? .pause
        otherApplicationPlayingAudio = (try? c.decodeIfPresent(GSPlayback.self, forKey: .otherApplicationPlayingAudio)) ?? nil ?? .keepRunning
        displayAsleep = (try? c.decodeIfPresent(GSPlayback.self, forKey: .displayAsleep)) ?? nil ?? .pause
        laptopOnBattery = (try? c.decodeIfPresent(GSPlayback.self, forKey: .laptopOnBattery)) ?? nil ?? .keepRunning
        lowPowerConditions = (try? c.decodeIfPresent(GSPlayback.self, forKey: .lowPowerConditions)) ?? nil ?? .pause
        autoStart = (try? c.decodeIfPresent(Bool.self, forKey: .autoStart)) ?? nil ?? false
        inboxNtfyTopic = (try? c.decodeIfPresent(String.self, forKey: .inboxNtfyTopic)) ?? nil ?? ""
        adjustMenuBarTint = (try? c.decodeIfPresent(Bool.self, forKey: .adjustMenuBarTint)) ?? nil ?? true
        appearance = (try? c.decodeIfPresent(GSAppearance.self, forKey: .appearance)) ?? nil ?? .followSystem
        showClockOverlay = (try? c.decodeIfPresent(Bool.self, forKey: .showClockOverlay)) ?? nil ?? false
        clockDayFont = (try? c.decodeIfPresent(GSClockFormat.self, forKey: .clockDayFont)) ?? nil ?? .anurati
        clockColor = (try? c.decodeIfPresent(GSClockColor.self, forKey: .clockColor)) ?? nil ?? .white
        clockCustomGradientStart = (try? c.decodeIfPresent(GSColor.self, forKey: .clockCustomGradientStart)) ?? nil ?? .black
        clockCustomGradientEnd = (try? c.decodeIfPresent(GSColor.self, forKey: .clockCustomGradientEnd)) ?? nil ?? .black
        clockCustomGradientHorizontal = (try? c.decodeIfPresent(Bool.self, forKey: .clockCustomGradientHorizontal)) ?? nil ?? false
        clockOpacity = (try? c.decodeIfPresent(Double.self, forKey: .clockOpacity)) ?? nil ?? 1.0
        clockTextAlignment = (try? c.decodeIfPresent(GSClockTextAlignment.self, forKey: .clockTextAlignment)) ?? nil ?? .center
        clockDayFontSize = (try? c.decodeIfPresent(Double.self, forKey: .clockDayFontSize)) ?? nil ?? 80
        clockDateFontSize = (try? c.decodeIfPresent(Double.self, forKey: .clockDateFontSize)) ?? nil ?? 18
        clockTimeFontSize = (try? c.decodeIfPresent(Double.self, forKey: .clockTimeFontSize)) ?? nil ?? 18
        clockShowSeconds = (try? c.decodeIfPresent(Bool.self, forKey: .clockShowSeconds)) ?? nil ?? false
        clockUse24HourTime = (try? c.decodeIfPresent(Bool.self, forKey: .clockUse24HourTime)) ?? nil ?? false
        clockSummitLineLength = (try? c.decodeIfPresent(Double.self, forKey: .clockSummitLineLength)) ?? nil ?? 30
        clockDraggable = (try? c.decodeIfPresent(Bool.self, forKey: .clockDraggable)) ?? nil ?? false
        clockCustomOrigins = (try? c.decodeIfPresent([String: CGPoint].self, forKey: .clockCustomOrigins)) ?? nil
        autoRefresh = (try? c.decodeIfPresent(Bool.self, forKey: .autoRefresh)) ?? nil ?? true
        steamUsername = (try? c.decodeIfPresent(String.self, forKey: .steamUsername)) ?? nil
        pauseHotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .pauseHotkey)) ?? nil ?? Self.defaultPauseHotkey
        muteHotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .muteHotkey)) ?? nil ?? Self.defaultMuteHotkey
        clockHotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .clockHotkey)) ?? nil ?? Self.defaultClockHotkey
        playlistNextHotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .playlistNextHotkey)) ?? nil ?? Self.defaultPlaylistNextHotkey
        playlistPreviousHotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .playlistPreviousHotkey)) ?? nil ?? Self.defaultPlaylistPreviousHotkey
    }
}

class GlobalSettingsViewModel: ObservableObject {
    @Published var settings: GlobalSettings
    {
        didSet { save(); validate() }
    }
    
    @Published var selection = 0
    
    @Published var isFirstLaunch = UserDefaults.standard.value(forKey: "IsFirstLaunch") as? Bool ?? true
    
    var didFinishLaunchingNotificationCancellable: Cancellable?
    var didActivateApplicationNotificationCancellable: Cancellable?
    var didCurrentWallpaperChangeCancellable: Cancellable?
    var didAddToLoginItemCancellable: Cancellable?
    var didChangeAdjustMenuBarTintCancellable: Cancellable?
    var didChangeShowClockOverlayCancellable: Cancellable?
    var didOtherAudioChangeCancellable: Cancellable?
    var otherAudioPolicyCancellable: Cancellable?
    var didBatteryStatusChangeCancellable: Cancellable?
    var didPowerConditionChangeCancellable: Cancellable?
    var didFullscreenChangeCancellable: Cancellable?
    var didDisplaySleepChangeCancellable: Cancellable?
    var didChangeHotkeysCancellable: Cancellable?

    /// Tracked directly here rather than via a dedicated monitor class — `NSWorkspace`'s own
    /// screensDidSleep/didWake notifications are already the real, first-party signal, so there's
    /// nothing to poll or approximate the way BatteryMonitor/FullscreenAppMonitor have to.
    private var isDisplayAsleep = false

    /// Settings live in their own file rather than `UserDefaults` — `UserDefaults.synchronize()`
    /// has been a documented no-op for years, so a write can still be sitting unflushed in
    /// cfprefsd's own async queue if the app dies abruptly (force-quit, crash, `kill`/`pkill`
    /// instead of Quit) right after. Confirmed live: toggling a setting then `kill -9`-ing the
    /// process lost the change even with an explicit `synchronize()` call. A direct atomic file
    /// write completes synchronously — by the time `save()` returns, it's actually on disk.
    /// Deliberately NOT inside `wallpapersDirectory` — that folder is scanned wholesale for
    /// wallpaper packages (ContentViewModel's `wallpapers`), and a stray file sitting in it
    /// gets treated as a corrupt wallpaper entry and shown in the library as a fake "Error" card
    /// (confirmed live: that's exactly what happened when this file lived there).
    private static var settingsFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wallwright Settings")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appending(path: "GlobalSettings.json")
    }

    /// Reads the last-saved settings — from the file if present, falling back to the old
    /// `UserDefaults`-backed store for anyone updating from a build before this migration.
    static func loadPersisted() -> GlobalSettings? {
        if let data = try? Data(contentsOf: settingsFileURL),
           let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            return settings
        }
        if let data = UserDefaults.standard.data(forKey: "GlobalSettings"),
           let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            return settings
        }
        return nil
    }

    init() {
        self.settings = Self.loadPersisted() ?? GlobalSettings()

        // Add observers
        self.didFinishLaunchingNotificationCancellable =
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in self?.didFinishLaunchingNotification() }
    }
    
    deinit {
        didActivateApplicationNotificationCancellable?.cancel()
        didFinishLaunchingNotificationCancellable?.cancel()
        didCurrentWallpaperChangeCancellable?.cancel()
        didAddToLoginItemCancellable?.cancel()
        didChangeAdjustMenuBarTintCancellable?.cancel()
        didChangeShowClockOverlayCancellable?.cancel()
        didOtherAudioChangeCancellable?.cancel()
        otherAudioPolicyCancellable?.cancel()
        didBatteryStatusChangeCancellable?.cancel()
        didPowerConditionChangeCancellable?.cancel()
        didFullscreenChangeCancellable?.cancel()
        didDisplaySleepChangeCancellable?.cancel()
        didChangeHotkeysCancellable?.cancel()
    }
    
    func didFinishLaunchingNotification() {
        self.didActivateApplicationNotificationCancellable =
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.activateApplicationDidChange() }
        
        // Subscribed to the whole per-screen `wallpapers` dictionary (there's no publisher for
        // just "the main screen's entry"), so this fires on ANY screen's wallpaper changing, not
        // just the main one. `lastMainWallpaper` filters that down to only the cases where the
        // main screen's own wallpaper actually differs — confirmed live (2026-08-07) that, on a
        // multi-display setup, changing a *different* screen's wallpaper was redundantly
        // re-running `didCurrentWallpaperChange`'s image branch (a "slow, 1-2s" IPC call) for a
        // main-screen wallpaper that hadn't changed at all.
        var lastMainWallpaper: WEWallpaper?
        self.didCurrentWallpaperChangeCancellable =
        AppDelegate.shared.wallpaperViewModel.$wallpapers
            .sink { [weak self] wallpapers in
                let mainId = WallpaperViewModel.mainScreenId()
                guard let wp = wallpapers[mainId] else { return }
                guard lastMainWallpaper == nil
                    || !wp.wallpaperDirectory.isSameWallpaperDirectory(as: lastMainWallpaper!.wallpaperDirectory)
                    || wp.project != lastMainWallpaper!.project
                else { return }
                lastMainWallpaper = wp
                self?.didCurrentWallpaperChange(wp)
            }
        
        self.didAddToLoginItemCancellable =
        self.$settings
            .removeDuplicates { $0.autoStart == $1.autoStart }
            .map { $0.autoStart }
            .sink { [weak self] in self?.didAddToLoginItem($0) }
        
        self.didChangeAdjustMenuBarTintCancellable =
        self.$settings
            .removeDuplicates { $0.adjustMenuBarTint == $1.adjustMenuBarTint }
            .map { $0.adjustMenuBarTint }
            .sink { [weak self] in self?.didChangeAdjustMenuBarTint($0) }

        self.didChangeShowClockOverlayCancellable =
        self.$settings
            .removeDuplicates {
                $0.showClockOverlay == $1.showClockOverlay
                && $0.clockDayFont == $1.clockDayFont
                && $0.clockColor == $1.clockColor
                && $0.clockTextAlignment == $1.clockTextAlignment
                && $0.clockDayFontSize == $1.clockDayFontSize
                && $0.clockDateFontSize == $1.clockDateFontSize
                && $0.clockTimeFontSize == $1.clockTimeFontSize
                && $0.clockShowSeconds == $1.clockShowSeconds
                && $0.clockUse24HourTime == $1.clockUse24HourTime
                && $0.clockSummitLineLength == $1.clockSummitLineLength
                && $0.clockDraggable == $1.clockDraggable
                // clockCustomOrigins deliberately excluded — it's written continuously while
                // dragging, and this subscription rebuilds (closes + recreates) every clock
                // window, which would fight the live drag and make the overlay unusable to move.
                // The window already reflects its own new position live; nothing needs rebuilding.
            }
            // The Size slider fires a settings mutation on every pixel of drag — without this,
            // dragging it triggers dozens of rapid close+recreate cycles on the clock windows,
            // which can race (a new window created before an older one finishes closing) and
            // leave stale windows on screen at old positions. Debouncing collapses a burst of
            // rapid changes into a single rebuild once the value settles.
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { _ in AppDelegate.shared.rebuildClockWindows() }

        // `.keepRunning` (the default — most users never touch this picker) means nothing ever
        // consumes `OtherAudioMonitor.isOtherAppPlaying`, so there's no reason to run its 2s
        // CoreAudio/AppleScript poll at all in that case. Started/stopped here in response to the
        // policy's actual value, not unconditionally at launch.
        updateOtherAudioMonitoring()
        self.otherAudioPolicyCancellable = $settings
            .map(\.otherApplicationPlayingAudio)
            .removeDuplicates()
            .dropFirst() // updateOtherAudioMonitoring() above already covers the initial value
            .sink { [weak self] _ in self?.updateOtherAudioMonitoring() }
        self.didOtherAudioChangeCancellable =
        NotificationCenter.default.publisher(for: OtherAudioMonitor.didChangeNotification)
            .sink { [weak self] _ in self?.otherAudioPlayingDidChange() }

        // "Laptop on battery" was a picker that saved a value nobody ever read — confirmed by
        // grep, no code path consumed `settings.laptopOnBattery` before this. Wired up the same
        // way as the other GSPlayback policies above.
        BatteryMonitor.shared.startIfNeeded()
        self.didBatteryStatusChangeCancellable =
        NotificationCenter.default.publisher(for: BatteryMonitor.powerSourceDidChange)
            .sink { [weak self] _ in self?.batteryStatusDidChange() }
        // BatteryMonitor's initial isOnBattery is computed synchronously at init, but the
        // notification above only fires on a later *transition* — without this, launching the
        // app while already unplugged would never apply the policy until the user plugs in and
        // unplugs again.
        batteryStatusDidChange()

        // Same shape as the battery wiring just above — thermal/low-battery/near-zero-brightness
        // via one combined signal (see `PowerConditionMonitor`).
        PowerConditionMonitor.shared.startIfNeeded()
        self.didPowerConditionChangeCancellable =
        NotificationCenter.default.publisher(for: PowerConditionMonitor.didChangeNotification)
            .sink { [weak self] _ in self?.powerConditionDidChange() }
        powerConditionDidChange()

        // "Other Application Fullscreen" and "Display asleep" — same story as laptopOnBattery:
        // both pickers, both saving a value nothing consumed. Wired the same way.
        FullscreenAppMonitor.shared.startIfNeeded()
        self.didFullscreenChangeCancellable =
        NotificationCenter.default.publisher(for: FullscreenAppMonitor.didChangeNotification)
            .sink { [weak self] _ in self?.otherApplicationFullscreenDidChange() }

        self.didDisplaySleepChangeCancellable =
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification))
            .sink { [weak self] notification in
                self?.displaySleepDidChange(isAsleep: notification.name == NSWorkspace.screensDidSleepNotification)
            }

        GlobalHotkeyManager.shared.updatePauseHotkey(settings.pauseHotkey)
        GlobalHotkeyManager.shared.updateMuteHotkey(settings.muteHotkey)
        GlobalHotkeyManager.shared.updateClockHotkey(settings.clockHotkey)
        GlobalHotkeyManager.shared.updatePlaylistNextHotkey(settings.playlistNextHotkey)
        GlobalHotkeyManager.shared.updatePlaylistPreviousHotkey(settings.playlistPreviousHotkey)
        self.didChangeHotkeysCancellable =
        self.$settings
            .removeDuplicates {
                $0.pauseHotkey == $1.pauseHotkey && $0.muteHotkey == $1.muteHotkey && $0.clockHotkey == $1.clockHotkey
                && $0.playlistNextHotkey == $1.playlistNextHotkey && $0.playlistPreviousHotkey == $1.playlistPreviousHotkey
            }
            .sink { settings in
                GlobalHotkeyManager.shared.updatePauseHotkey(settings.pauseHotkey)
                GlobalHotkeyManager.shared.updateMuteHotkey(settings.muteHotkey)
                GlobalHotkeyManager.shared.updateClockHotkey(settings.clockHotkey)
                GlobalHotkeyManager.shared.updatePlaylistNextHotkey(settings.playlistNextHotkey)
                GlobalHotkeyManager.shared.updatePlaylistPreviousHotkey(settings.playlistPreviousHotkey)
            }

        self.validate()
    }

    /// True if any currently-active reason means the wallpaper should stay paused: a manual user
    /// pause, or another GSPlayback policy whose own trigger condition is still true. Every
    /// auto-resume call site checks this instead of just `isPausedByUser` — confirmed live
    /// (2026-07-26) that without it, one policy's resume can silently undo another policy's
    /// pause: launching while on battery correctly paused via the battery policy, but Wallwright
    /// becoming the frontmost app at launch also matches "Other Application Focused"'s own
    /// resume trigger (when that's set to Pause too), and it had no way to know the battery
    /// policy still wanted playback paused.
    private var shouldWallpaperStayPaused: Bool {
        if AppDelegate.shared.wallpaperViewModel.isPausedByUser { return true }
        if BatteryMonitor.shared.isOnBattery && settings.laptopOnBattery == .pause { return true }
        if PowerConditionMonitor.shared.shouldPause && settings.lowPowerConditions == .pause { return true }
        if FullscreenAppMonitor.shared.isOtherAppFullscreen && settings.otherApplicationFullscreen == .pause { return true }
        if isDisplayAsleep && settings.displayAsleep == .pause { return true }
        return false
    }

    /// A short, human-readable reason the wallpaper is *currently* paused for a policy reason —
    /// nil when playing, and nil when paused manually (the Pause/Resume button itself already
    /// makes that self-explanatory; this is specifically for the "why did this pause on its own"
    /// case, which used to just show a generic paused state with no explanation). Checked in the
    /// same priority order as `shouldWallpaperStayPaused` above.
    var activePauseReasonText: String? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
           frontmost.bundleIdentifier != "com.apple.finder",
           settings.otherApplicationFocused == .pause {
            return String(localized: "Paused — another app is focused")
        }
        if BatteryMonitor.shared.isOnBattery && settings.laptopOnBattery == .pause {
            return String(localized: "Paused — on battery")
        }
        if PowerConditionMonitor.shared.shouldPause && settings.lowPowerConditions == .pause {
            return String(localized: "Paused — power-saving")
        }
        if FullscreenAppMonitor.shared.isOtherAppFullscreen && settings.otherApplicationFullscreen == .pause {
            return String(localized: "Paused — another app is covering the screen")
        }
        if isDisplayAsleep && settings.displayAsleep == .pause {
            return String(localized: "Paused — display asleep")
        }
        return nil
    }

    /// Applies the "Other Application Playing Audio" policy — mirrors
    /// activateApplicationDidChange/globalSettingsWhenApplicationDidBecomeActive's shape, but
    /// reacting to OtherAudioMonitor's best-effort "is some other app the system's Now Playing
    /// source right now" signal instead of app focus.
    func otherAudioPlayingDidChange() {
        if OtherAudioMonitor.shared.isOtherAppPlaying {
            switch settings.otherApplicationPlayingAudio {
            case .mute:
                AppDelegate.shared.mute()
            case .pause:
                AppDelegate.shared.pause()
            case .keepRunning, .stop:
                break
            }
        } else {
            switch settings.otherApplicationPlayingAudio {
            case .mute:
                AppDelegate.shared.unmute()
            case .pause:
                guard !shouldWallpaperStayPaused else { break }
                AppDelegate.shared.resume()
            case .keepRunning, .stop:
                break
            }
        }
    }

    /// Starts/stops `OtherAudioMonitor`'s poll to match whether the policy actually needs it —
    /// `.keepRunning` never consumes `isOtherAppPlaying` at all (see the two switches above), so
    /// polling then would just be wasted CoreAudio/AppleScript work with nothing acting on the
    /// result.
    private func updateOtherAudioMonitoring() {
        if settings.otherApplicationPlayingAudio == .keepRunning {
            OtherAudioMonitor.shared.stop()
        } else {
            OtherAudioMonitor.shared.startIfNeeded()
        }
    }

    /// Applies the "Laptop on battery" policy — same shape as the other GSPlayback reactions
    /// above (guards on `shouldWallpaperStayPaused` so this never overrides a pause the user set
    /// on purpose, and never auto-resumes into that state either).
    func batteryStatusDidChange() {
        if BatteryMonitor.shared.isOnBattery {
            switch settings.laptopOnBattery {
            case .pause:
                AppDelegate.shared.pause()
            case .stop:
                AppDelegate.shared.pause()
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderOut(nil) }
            case .keepRunning, .mute:
                break
            }
        } else {
            switch settings.laptopOnBattery {
            case .pause:
                guard !shouldWallpaperStayPaused else { break }
                AppDelegate.shared.resume()
            case .stop:
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderFront(nil) }
                guard !shouldWallpaperStayPaused else { break }
                AppDelegate.shared.resume()
            case .keepRunning, .mute:
                break
            }
        }
    }

    /// Applies the "Low Power Conditions" policy (thermal throttling or critically low battery —
    /// see `PowerConditionMonitor`) — same shape as `batteryStatusDidChange` above.
    func powerConditionDidChange() {
        if PowerConditionMonitor.shared.shouldPause {
            switch settings.lowPowerConditions {
            case .pause:
                AppDelegate.shared.pause()
            case .stop:
                AppDelegate.shared.pause()
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderOut(nil) }
            case .keepRunning, .mute:
                break
            }
        } else {
            switch settings.lowPowerConditions {
            case .pause:
                guard !shouldWallpaperStayPaused else { break }
                AppDelegate.shared.resume()
            case .stop:
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderFront(nil) }
                guard !shouldWallpaperStayPaused else { break }
                AppDelegate.shared.resume()
            case .keepRunning, .mute:
                break
            }
        }
    }

    /// Applies the "Other Application Fullscreen" policy — same shape as the reactions above.
    func otherApplicationFullscreenDidChange() {
        wallpaperDebugLog2.notice("otherApplicationFullscreenDidChange() — isOtherAppFullscreen=\(FullscreenAppMonitor.shared.isOtherAppFullscreen), policy=\(String(describing: self.settings.otherApplicationFullscreen), privacy: .public)")
        if FullscreenAppMonitor.shared.isOtherAppFullscreen {
            switch settings.otherApplicationFullscreen {
            case .pause:
                AppDelegate.shared.pause()
            case .stop:
                AppDelegate.shared.pause()
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderOut(nil) }
            case .keepRunning, .mute:
                break
            }
        } else {
            switch settings.otherApplicationFullscreen {
            case .pause:
                guard !shouldWallpaperStayPaused else { break }
                AppDelegate.shared.resume()
            case .stop:
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderFront(nil) }
                guard !shouldWallpaperStayPaused else {
                    wallpaperDebugLog2.notice("otherApplicationFullscreenDidChange() — windows ordered front but shouldWallpaperStayPaused, NOT resuming")
                    break
                }
                wallpaperDebugLog2.notice("otherApplicationFullscreenDidChange() — calling AppDelegate.resume()")
                AppDelegate.shared.resume()
            case .keepRunning, .mute:
                break
            }
        }
    }

    /// Applies the "Display asleep" policy — same shape as the reactions above. Distinct from
    /// `VideoWallpaperViewModel`'s own unconditional pause-on-full-system-sleep (which exists
    /// regardless of this setting, since there's no reason to keep decoding video nobody's Mac is
    /// even awake to render); this is the user-configurable layer for just the display sleeping.
    func displaySleepDidChange(isAsleep: Bool) {
        isDisplayAsleep = isAsleep
        if isAsleep {
            switch settings.displayAsleep {
            case .pause:
                AppDelegate.shared.pause()
            case .stop:
                AppDelegate.shared.pause()
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderOut(nil) }
            case .keepRunning, .mute:
                break
            }
        } else {
            switch settings.displayAsleep {
            case .pause:
                guard !shouldWallpaperStayPaused else { break }
                AppDelegate.shared.resume()
            case .stop:
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderFront(nil) }
                guard !shouldWallpaperStayPaused else { break }
                AppDelegate.shared.resume()
            case .keepRunning, .mute:
                break
            }
        }
    }

    func didAddToLoginItem(_ added: Bool) {
        let appService = SMAppService.mainApp
        do {
            if added {
                try appService.register()
            } else {
                try appService.unregister()
            }
        } catch {
            print(error)
        }
    }
    
    func didChangeAdjustMenuBarTint(_ newValue: Bool) {
        // `NSScreen.main` is nil during transient states (display sleep/wake, reconfiguration) —
        // force-unwrapping it here was a real crash vector, not just a theoretical one, since this
        // runs in direct response to a settings change the user can trigger at any time.
        guard let mainScreen = NSScreen.main else { return }
        // This fires synchronously on the main thread (this setting's `.sink` has no
        // `.receive(on:)`), and `setDesktopImageURL` is a slow, blocking IPC call to the Dock —
        // same class of bug as the wallpaper-switch lag fixed elsewhere; dispatched off-main here
        // for the same reason.
        DispatchQueue.global(qos: .utility).async {
            if newValue != true {
                if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(wallpaper, for: mainScreen)
                    } catch {
                        print("didChangeAdjustMenuBarTint: failed to restore original wallpaper: \(error)")
                    }
                }
            } else {
                // Was independently reconstructing the "static placeholder" filename here
                // (`staticWP_<hashValue>.tiff`) instead of reusing `setPlacehoderWallpaper` — that
                // hash-based name stopped matching the file `setPlacehoderWallpaper`'s video branch
                // actually writes (`staticWP_current.tiff`, fixed deliberately since `.hashValue`
                // isn't stable across launches) as soon as that fix landed, so this always pointed
                // macOS at a file that was never created. Confirmed live (2026-08-07): the failure
                // ("The file doesn't exist") left the menu bar's tint sampling with nothing valid to
                // read, visible as a washed-out white gradient under the menu bar. Also never
                // handled the image-wallpaper case at all (only ever looked for a video-only TIFF).
                // Delegating to the one already-correct implementation fixes both at once.
                AppDelegate.shared.setPlacehoderWallpaper(with: AppDelegate.shared.wallpaperViewModel.currentWallpaper)
            }
        }
    }
    
    func didCurrentWallpaperChange(_ newValue: WEWallpaper) {
        guard newValue.project != .invalid else { return }

        if newValue.project.type == "video" {
            // AerialsInjector's system registration already governs the desktop picture (and
            // lock/idle screen) for this wallpaper. Also calling setPlacehoderWallpaper here
            // would set a *second*, competing NSWorkspace desktop-image choice — WallpaperAgent
            // then favors that static image over the aerial, so the aerial extension launches
            // and receives Play but never actually decodes a frame (confirmed via log: extension
            // active, Play called, 0 frames enqueued for the full locked session). LivePaper's
            // own code hit this exact conflict and explicitly works around it the same way.
            DispatchQueue.global(qos: .utility).async {
                let videoURL = newValue.wallpaperDirectory.appending(path: newValue.project.file)
                AerialsInjector.shared.inject(videoURL: videoURL, name: newValue.project.title)
            }
        } else {
            // Reverted: registering a synthetic looping video (built from the wallpaper's own
            // preview image) as the aerial for non-video wallpapers, so lock/idle would show
            // *something* of the current wallpaper instead of Apple's default. Verified correct
            // at every level this app can inspect — real screen resolution, proper aspect-fill
            // crop, honest frame rate matching the manifest's declared format — but still looked
            // wrong on the actual lock screen, which means the discrepancy is inside macOS's own
            // undocumented aerial rendering pipeline, with no further visibility available from
            // here. Not worth continued guessing at that; back to the simple, known-correct
            // behavior of just not claiming a lock/idle representation for these wallpapers.
            // Both dispatched together, in this exact order, on one background queue — not as two
            // independent `.async` calls. `AerialsInjector.remove()` restarts WallpaperAgent
            // (`killall WallpaperAgent`) whenever an aerial was actually registered (e.g. from a
            // video wallpaper earlier in the session — the registration persists across switches
            // until explicitly removed), and that restart resets the visible desktop picture to
            // whatever WallpaperAgent's own state is on respawn. Two independent `.async` calls to
            // `DispatchQueue.global` (a *concurrent* queue) raced against each other — confirmed
            // live: the restart could land after `setPlacehoderWallpaper`'s `setDesktopImageURL`
            // call, silently reverting the desktop to macOS's default. Running both inside one
            // closure guarantees the aerial cleanup (and its restart, if any) fully settles before
            // we write the desktop image, so that write is always the last thing that happens.
            DispatchQueue.global(qos: .utility).async {
                AerialsInjector.shared.remove()
                AppDelegate.shared.setPlacehoderWallpaper(with: newValue)
            }
        }
    }
    
    func reset() {
        settings = Self.loadPersisted() ?? GlobalSettings()
    }

    func save() {
        let data = try! JSONEncoder().encode(settings)
        try? data.write(to: Self.settingsFileURL, options: .atomic)
        // Also mirrored to UserDefaults for anything else that might still read the old key —
        // the file above is the actual durable source of truth now.
        UserDefaults.standard.set(data, forKey: "GlobalSettings")
    }
    
    private func validate() {
        switch settings.appearance {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .followSystem:
            NSApp.appearance = nil
        }
    }
    
    func activateApplicationDidChange() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return }

        switch frontmostApplication.bundleIdentifier {
        case "com.apple.finder", Bundle.main.bundleIdentifier:
            globalSettingsWhenApplicationDidBecomeActive()
        default:
            switch self.settings.otherApplicationFocused {
            case .mute:
                AppDelegate.shared.mute()
            case .pause:
                AppDelegate.shared.pause()
            case .stop:
                AppDelegate.shared.pause()
                for window in AppDelegate.shared.wallpaperWindows.values { window.orderOut(nil) }
            case .keepRunning:
                break
            }
        }
    }

    func globalSettingsWhenApplicationDidBecomeActive() {
        switch self.settings.otherApplicationFocused {
        case .mute:
            AppDelegate.shared.unmute()
        case .pause:
            guard !shouldWallpaperStayPaused else { break }
            AppDelegate.shared.resume()
        case .stop:
            for window in AppDelegate.shared.wallpaperWindows.values { window.orderFront(nil) }
            guard !shouldWallpaperStayPaused else { break }
            AppDelegate.shared.resume()
        case .keepRunning:
            break
        }
    }
    
}
