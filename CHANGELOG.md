# Changelog

All notable changes to Wallwright are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Steam Workshop import can now search by keyword, not just paste a link/ID. The Steam icon's own
  popup gained a Link/Search toggle for a quick one-off paste-and-go (with its own freely-
  changeable Video/Scene/All Type picker); "WEVideo" (Video Sources popover) and "WEScene" (Image
  Sources popover — a Scene result commits as a static image, so it's grouped with UHDPaper/
  AlphaCoders rather than with WEVideo) open full browsable Workshop grids matching every other
  source's tab here: search, Genre and Miscellaneous filter chips (tap to include, tap again to
  exclude, matching Steam's own +/- filter chips), square thumbnails three across, load-more,
  one-click download. WEVideo shows Video results only and WEScene shows Scene results only — a
  hard lock, not a default, the same way MotionBgs's tab never shows AlphaCoders results. A new
  Settings > General > Steam Workshop > Safe Mode toggle (on by default) scopes every search to
  Age Rating "Everyone" and Category "Wallpaper" — no Mature/Questionable results, no Preset/Asset
  clutter — and can be turned off to lift both limits. Downloads still go through the same
  title/tags review step as before, including the scene-art picker when a Scene result bundles
  more than one candidate image.
- Steam Workshop Scene wallpapers are now imported instead of rejected: the real background
  artwork is extracted from the scene's own package (direct image decode, DXT1/3/5 texture
  decompression, or a frame grabbed from an embedded video) and set as a static image wallpaper,
  rather than discarding the download or falling back to the tiny preview thumbnail. When a scene
  bundles more than one plausible background image, the import review sheet shows a picker so you
  choose which one becomes the wallpaper instead of Wallwright silently guessing.
- Single-instance guard: a second launch of Wallwright now exits instead of running alongside the first.
- Low-power conditions auto-pause (thermal pressure and battery), modeled on Phosphene's PowerMonitor.
- Auto Trim for imported video wallpapers.
- A `WallwrightTests` unit test target with initial coverage.
- Real Liquid Glass window chrome across the app, with translucent-button tinting fixes.
- Wallpaper pinning: a right-click Pin/Unpin option, a pin badge on the library grid, and pinned
  wallpapers float to the top of the grid regardless of the active sort. Also available over the
  named-pipe command interface (`echo "pin" > /tmp/wallwright-$(id -u).pipe`).
- `PrivacyInfo.xcprivacy` privacy manifest declaring zero tracking and the app's actual
  UserDefaults/FileTimestamp API usage.
- A GitHub Actions CI workflow (build and test on push/PR to main).
- `PinningTests` and `ProcessRunnerTests` unit test suites.

### Changed
- Replaced manual "Load More" buttons and pagination with continuous auto-load-on-scroll in browse tabs.
- Settings window: removed the OK/Cancel modal pattern (settings already autosave), reordered tabs to General → Performance → Hotkeys → About, and swapped the About tab icon to match.
- Library UI polish: single hover scale, playlist menu actions, HIG wording pass.
- Every popup now closes with Escape, not just the Command Palette.
- README rewritten with a real pitch, install instructions, and license/release badges.
- Simplified attribution to a single link to the upstream fork for contributors already credited
  there, keeping the separate LivePaper/Phosphene adapted-from credits as their own entries.
- About screen now shows license/privacy badges and repository/releases/issues links instead of
  just a contributor list.
- The application menu's Quit item moved to the bottom, after Hide/Hide Others, matching standard
  macOS ordering.

### Fixed
- Path traversal and other unsafe destination handling across all importers (video, image, package, YouTube).
- Multi-monitor sync bugs and reduced memory/CPU overhead.
- Duplicate-import and duplicate-download races; hardened window dragging; cut library-tab remount cost.
- A browse-tab disk I/O storm, leaked scratch downloads, and unhardened file monitors.
- Spotify's "other app audio" detection silencing all other apps; a related session leak.
- Display-resolution unit bugs, a 2-frame day/night flash, and misc UI gaps.
- Settings window reverting unsaved changes on reopen; Dock reopen not re-activating the window.
- A playlist deadlock; added a symmetric "Previous Wallpaper" fallback.
- Crop-dimension and coordinate-overflow bugs affecting `h264_videotoolbox` encoding.
- Multi-file drag-drop and an inverted sort direction.
- A grid-card layout regression from an earlier `scaleEffect` removal.
- Manual resume and status text not accounting for a stopped state.
- The video decoder not actually releasing under "Stop (free memory)" policies.
- The thumbnail cache not evicting when the main window closes.
- The clock overlay drifting off real minute boundaries.
- Data races in `InboxLinksStore` and `NtfyInboxTransport`'s SSE buffer.
- `AerialsInjector`'s health-check timer never firing, and its registration going stale after a macOS build change (forces a fresh registration now).
- Unsynchronized subprocess output races; a self-introduced edit race; main-thread-blocking imports.
- Stale-response races and off-main-thread library scans in browse tabs.
- A settings-slider disk-write storm and browse-grid over-rendering.
- A rectangular-strip rendering artifact after kill/relaunch.
- Hardened the video wallpaper pipeline: stable display IDs, codec detection, failure recovery.
- Double audio decode and a duplicate `WallpaperAgent` restart.
- The clock color popover not closing, and an unbounded sleep assertion.
- The audio player decoding while muted or at zero volume.
- Browse-tab search text not clearing consistently across tabs, and empty-state messaging
  wrongly blaming the hide feature for a plain empty or failed fetch.
- DesktopHut's markup selectors and two category URLs, which had drifted from the live site.
- The single-instance guard exiting before XCTest could attach when launched as a test host.
- The About window stacking a new instance on every click instead of reusing one, and showing a
  blank title.
- A settings sink that re-registered the login item on every app launch (not just an actual
  toggle), silently re-pointing it at whatever ephemeral path last launched the app, including a
  test run's temporary build location.
- Toggling pin on the wallpaper actually assigned to a screen only updated the library grid's
  copy, never the separate per-screen assignment dictionary, so a second toggle (e.g. via the
  pipe interface's "pin" command) kept reading back the same stale value instead of flipping it.
- The menu bar's translucent tint going stale for as long as any video wallpaper was active,
  showing whatever the last non-video wallpaper set (or macOS's own default gradient if none ever
  had been) instead of the actual video's colors. A video wallpaper never updated the system
  desktop-picture registration that drives this tint at all, to avoid an earlier conflict with
  the Aerials lock-screen/screensaver registration; now it's updated right after Aerials finishes
  its own registration instead of being skipped outright, so both stay correct.

### Performance
- Lowered the thumbnail cache cap from 300MB to 64MB and added a cache count limit; right-sized thumbnail decoding.
- Moved disk I/O and image decoding off the main thread.
- Cached the clock overlay's `DateFormatter` instead of allocating one per draw.
- Trimmed video loop-restart overhead.
- Declared `NSSupportsAutomaticGraphicsSwitching` so dual-GPU Intel Macs aren't forced onto the
  discrete GPU just to render the wallpaper.

### Internal
- Centralized logging into `WWLog`, replacing 8 scattered `Logger` instances and 29 `print()` calls.
- Extracted `ProcessRunner.resolveBinary(named:)` and `AppResources`, removing duplicated binary-
  resolution code and several identical force-unwrapped bundle-resource lookups.
- Removed remaining unsafe `try!`/`as!` force-unwraps that could crash the app.

## [1.0.0] - 2026-08-08
Initial public release: live video wallpapers synced across desktop, lock screen, and screensaver,
a library manager, playlist rotation, a drag-anywhere clock overlay, and built-in browsers for
several free wallpaper sites.

[Unreleased]: https://github.com/anonyks/wallwright/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/anonyks/wallwright/releases/tag/v1.0.0
