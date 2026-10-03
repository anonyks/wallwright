# Changelog

All notable changes to Wallwright are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Single-instance guard: a second launch of Wallwright now exits instead of running alongside the first.
- Low-power conditions auto-pause (thermal pressure and battery), modeled on Phosphene's PowerMonitor.
- Auto Trim for imported video wallpapers.
- A `WallwrightTests` unit test target with initial coverage.
- Real Liquid Glass window chrome across the app, with translucent-button tinting fixes.

### Changed
- Replaced manual "Load More" buttons and pagination with continuous auto-load-on-scroll in browse tabs.
- Settings window: removed the OK/Cancel modal pattern (settings already autosave), reordered tabs to General → Performance → Hotkeys → About, and swapped the About tab icon to match.
- Library UI polish: single hover scale, playlist menu actions, HIG wording pass.
- Every popup now closes with Escape, not just the Command Palette.
- README rewritten with a real pitch, install instructions, and license/release badges.

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

### Performance
- Lowered the thumbnail cache cap from 300MB to 64MB and added a cache count limit; right-sized thumbnail decoding.
- Moved disk I/O and image decoding off the main thread.
- Cached the clock overlay's `DateFormatter` instead of allocating one per draw.
- Trimmed video loop-restart overhead.

## [1.0.0] - 2026-08-08
Initial public release: live video wallpapers synced across desktop, lock screen, and screensaver,
a library manager, playlist rotation, a drag-anywhere clock overlay, and built-in browsers for
several free wallpaper sites.

[Unreleased]: https://github.com/anonyks/wallwright/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/anonyks/wallwright/releases/tag/v1.0.0
