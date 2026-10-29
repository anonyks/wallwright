//
//  LockScreenExchange.swift
//  Wallwright
//
//  Compiled into BOTH the main app target and WallwrightLockScreenExtension — the one file they
//  share, so they agree on the exchange directory layout and JSON shape without either importing
//  the other. Adapted from reference/WallpaperMachine/Shared/LockScreenConfiguration.swift (read
//  this session for the private com.apple.wallpaper extension protocol it exists to support),
//  trimmed to Wallwright's single-wallpaper case — no multi-scene list, no per-display scenes,
//  since M0/M1 force-select one wallpaper everywhere rather than offering a System Settings
//  picker (see AerialsInjector.swift's own Store/Index.plist-writing pattern, which this mirrors
//  for the extension's own Provider ID instead of com.apple.wallpaper.choice.aerials).
//

import Foundation

struct LockScreenExchangeConfig: Codable, Equatable {
    static let fileName = "configuration.json"
    /// Posted by the main app after publishing a new configuration.json, so the running
    /// extension re-reads it immediately instead of polling — same Darwin-notification push
    /// WallpaperMachine's own LockScreenWallpaperService/WallpaperController pair uses.
    static let changedNotification = "com.wallwright.Wallwright.LockScreenExchange.changed"
    static let supportedVersion = 1

    /// Home-relative, resolved against the REAL account home directory, not `NSHomeDirectory()` —
    /// inside the extension's own sandbox, `NSHomeDirectory()` names its container, not the real
    /// home, so both processes must agree on one directory via a path that doesn't depend on
    /// which sandbox (if any) is asking. Same `getpwuid` resolution WallpaperMachine's own
    /// `LockScreenConfiguration.exchangeDirectory` uses, for the same reason (its own comment:
    /// "both processes must agree on one directory").
    static let exchangeDirectory: URL = {
        let home: URL
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(
            "Library/Application Support/com.wallwright.Wallwright/LockScreenExchange",
            isDirectory: true
        )
    }()

    var version: Int = Self.supportedVersion
    /// Bumped on every publish — lets the extension cheaply tell "nothing changed" apart from
    /// "something changed" without diffing the whole struct.
    var revision: String = UUID().uuidString
    /// Filename inside `exchangeDirectory` of the current wallpaper's static preview image — used
    /// directly for an image wallpaper (M0), and as the poster frame shown the instant
    /// `videoFileName` is set but hasn't produced its first decoded frame yet. Never an absolute
    /// path or anything containing "..": resolved the same path-traversal-hardened way as
    /// `WallpaperRuntime.asset(_:)` below.
    var imageFileName: String
    /// Filename inside `exchangeDirectory` of the current wallpaper's video file (M1) — nil for an
    /// image wallpaper, where `imageFileName` alone is shown. Same path-traversal hardening as
    /// `imageFileName`.
    var videoFileName: String?
}
