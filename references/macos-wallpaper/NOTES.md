# macos-wallpaper (sindresorhus) — Notes for Wallwright

Repo: `references/macos-wallpaper/repo` (local clone, sindresorhus/macos-wallpaper, MIT).
Reviewed: `readme.md`, `Package.swift`, `Sources/wallpaper/Wallpaper.swift`, `Sources/wallpaper/Utilities.swift`,
`Sources/WallpaperCLI/Wallpaper.swift`, `Sources/WallpaperCLI/Utilities.swift`.

## What it is

A tiny, focused Swift Package that wraps macOS's *public* desktop-wallpaper API
(`NSWorkspace.shared.desktopImageURL(for:)` / `.setDesktopImageURL(_:for:options:)`) in a clean library (`Wallpaper`
target) plus a thin `swift-argument-parser` CLI (`WallpaperCLI` target, binary name `wallpaper`). It does exactly one
job — get/set the desktop picture (image or solid color) per screen — and does it defensively, working around two
specific macOS bugs that the raw API doesn't handle. It is intentionally *not* a live-wallpaper engine; it never
touches video, Spaces-aware windows, or anything undocumented. Wallwright's own `NSWorkspace` usage (in
`Wallwright/AppDelegate.swift` and `Wallwright/Services/GlobalSettingsService.swift`) is a small, ad hoc subset of
what this package does, without most of its defensive handling.

## How it uses the public wallpaper API, and what Wallwright is missing

All calls go through `NSScreen`, never `CGDirectDisplayID` directly for the get/set path itself (display IDs are
only used for the pre-10.15 screen-naming fallback). Compare this to Wallwright:

1. **Directory-vs-file bug workaround** — `Wallpaper.swift:51` `getFromDirectory(_:)`. `NSWorkspace.desktopImageURL(for:)`
   can return a *directory* URL instead of the actual image file (when wallpaper is set from a folder/slideshow);
   the package queries `~/Library/Application Support/Dock/desktoppicture.db` (via `SQLite.swift`) to resolve the
   real file, guarded by `#available(macOS 26, *)` since Apple appears to have fixed/changed this in macOS 26
   (`Wallpaper.swift:54`). It falls back gracefully to the directory URL if the DB read fails (e.g. under sandbox —
   see the README's sandboxing note). **Wallwright**: `AppDelegate.swift:243`
   (`var osWallpaper: URL { NSWorkspace.shared.desktopImageURL(for: mainScreen)! }`) reads this value raw, force-
   unwrapped, with no directory/sandbox handling — if a user has a folder or slideshow wallpaper (very plausible on
   real machines) this could crash or hand Wallwright a folder path where it expects a single image. **Applicability: performance/correctness edge case, low-severity but a real crash risk.**

2. **"Same path, different content" refresh bug workaround** — `Wallpaper.swift:119` `forceRefreshIfNeeded(_:screen:)`.
   Setting the desktop image to a URL that's byte-identical in *path* to the current one (but different file
   content) silently no-ops on macOS. The package detects this by comparing against `get(screen:)`, clears the
   wallpaper to an empty URL first, then sleeps a hand-tuned `0.4s` (`sleep(for:)` in `Utilities.swift:3`, wrapping
   `usleep`) before re-setting — with a code comment citing the exact radar (`openradar.appspot.com/radar?id=6095446787227648`)
   and explaining why `0.3` wasn't enough. **Wallwright**: `GlobalSettingsService.swift:606-607` writes a cache file
   named `staticWP_<hash of wallpaperDirectory>.tiff` specifically to dodge this exact class of bug (reusing the same
   path would silently fail to update) — i.e. Wallwright already independently discovered this problem and solved it
   with a *different, more fragile* strategy (a hash-keyed filename to force a "new" path) rather than the
   forced-refresh-with-sleep the OS itself seems to need. Worth comparing robustness: content-hash-in-filename works
   but leaves stale cache files to clean up (see the `staticWP` cleanup loop in `AppDelegate.swift:176-186`), whereas
   the package's approach requires no cache management at all. **Applicability: performance (avoids disk bloat /
   cleanup-on-quit cost) and correctness.**

3. **Multi-screen is a first-class concept, not an afterthought** — `Wallpaper.Screen` enum (`Wallpaper.swift:8-33`)
   with `.all`, `.main`, `.index(Int)`, and `.nsScreens([NSScreen])` cases, each mapping to `[NSScreen]` via a single
   `nsScreens` computed property, with `Collection.subscript(safe:)` (`Utilities.swift:8`) guarding out-of-range
   indices instead of crashing. Every public function (`get`, `set` image, `set` solid color) takes a `screen:`
   parameter uniformly. **Wallwright**: mixes bare `NSScreen.screens` iteration (`AppDelegate.swift:172-174`, on
   quit) with a hardcoded `.main!` force-unwrap (`GlobalSettingsService.swift:602,607`, `AppDelegate.swift:340`) — no
   single reusable "which screens do I mean" abstraction, and the `.main!` sites will crash if `NSScreen.main` is
   ever nil (e.g. transient states during display reconfiguration/sleep-wake, which Wallwright already has to
   handle elsewhere via `screensDidSleepNotification`/`screensDidWakeNotification` in the same file). **Applicability: UI/UX (multi-display correctness) and reliability/performance (no crash-and-relaunch cost).**

4. **No Spaces-aware or screen-change-notification handling anywhere in the package.** This was a specific thing to
   check for since Wallwright already listens to `NSWorkspace.screensDidSleepNotification` /
   `screensDidWakeNotification` (`VideoWallpaperViewModel.swift:107-108`, `GlobalSettingsService.swift:428-429`) and
   `didActivateApplicationNotification` (`GlobalSettingsService.swift:351`) for fullscreen-app detection. The
   package does *not* subscribe to `NSApplication.didChangeScreenParametersNotification` or any Spaces notification
   — it's a one-shot CLI/library call, not a long-running observer. So on this specific axis Wallwright is already
   more complete than the package; this isn't something to backport, it's confirmation there's nothing to copy here.

5. **Validation before mutation** — `validateFile(_:)` (`Wallpaper.swift:91`) checks existence *and* accessibility
   (`checkResourceIsReachable()`) before attempting to set, throwing a descriptive `NSError` with
   `NSLocalizedDescriptionKey` rather than letting the opaque `NSWorkspace` error surface. Wallwright's equivalent
   call sites (`AppDelegate.swift:173`, `GlobalSettingsService.swift:602`) use `try?` and silently swallow failures,
   or `try` with a bare `print(error)` (`GlobalSettingsService.swift:594-596` pattern) — no pre-flight check, no
   surfaced user-facing error. **Applicability: UI/UX — a failed wallpaper set currently fails silently in Wallwright;
   this pattern would let it show something like "wallpaper file is missing/inaccessible" instead.**

6. **Solid-color wallpaper is implemented as a trick, not a separate code path** — `Wallpaper.swift:180`
   `set(_ solidColor: NSColor, screen:)` reuses the exact same `set(image:...)` machinery by pointing at Apple's
   own bundled `Transparent.tiff` (`/System/Library/.../DesktopScreenEffectsPref.prefPane/.../Transparent.tiff`)
   with `.fit` scale and the color as `fillColor`. This is a "found it by reading Apple's own resources" hack — the
   kind of trick worth remembering if Wallwright ever wants a solid-color "no wallpaper selected" fallback state
   instead of (or alongside) `staticWP_*.tiff` caching. **Applicability: UI/UX nicety, not performance-critical.**

## API design / code-quality observations (not feature-related, but instructive)

- **Extremely small public surface**: the whole library is one `enum Wallpaper` namespace with 4 static members
  (`Screen`, `Scale`, `get`, `set`×2, `screenNames`) — no instantiation, no protocols, no DI. For a wrapper this
  narrow, that's the correct amount of abstraction; nothing to imitate structurally, but a good reminder that a
  focused service doesn't need a class/singleton ceremony.
- **Every workaround is commented with a citation** — both bug workarounds link an actual Open Radar issue number
  and explain *why* the chosen constant (`0.4s` sleep, the `macOS 26` availability cutoff) was picked, including a
  note that `0.3` was tried and failed. This is a strong convention: undocumented-OS-quirk workarounds should always
  carry a permalink and a "here's what we tried" note, not just a magic number. Wallwright's own quirk workarounds
  (e.g. the `staticWP_<hash>` cache-busting trick, the "second competing wallpaper choice" comment in
  `AppDelegate.swift:127` and `GlobalSettingsService.swift:620`) are already in the right spirit but less specific —
  worth tightening to this citation style.
- **Errors are typed/descriptive, not printed-and-swallowed.** Every fallible operation `throws` a real `Error`
  with a human-readable message; callers (the CLI) let ArgumentParser surface it. Wallwright's `print(error)` /
  `try?` pattern scattered through `GlobalSettingsService.swift` and `AppDelegate.swift` is the opposite instinct —
  fine for a hobby project, but a good target for cleanup since these are exactly the errors a user would want
  surfaced (e.g., "couldn't set wallpaper: file inaccessible").
- **Package.swift is honest about its minimum deployment target** (`macOS(.v10_13)`, i.e., 10.13) while the CLI
  usage note in the README separately says "Requires macOS 10.14.4 or later" for the `desktopImageURL` API itself —
  a small but disciplined distinction between "what the package builds for" and "what the API actually needs," worth
  copying in Wallwright's own docs/comments if there's ever a stated minimum-OS claim.
- **`#available(macOS 26, *)` used to *disable* a workaround going forward** (`Wallpaper.swift:54`) rather than only
  ever adding new code behind `#available` — a reminder that OS-version gates should be revisited/removed as bugs
  get fixed upstream, not just accumulated. Worth an occasional audit pass over Wallwright's own AppKit workarounds
  as new macOS versions ship.
- **Two near-duplicate `Utilities.swift` files** (`Sources/wallpaper/Utilities.swift` for
  `NSScreen`/`URL`/`Collection` extensions vs. `Sources/WallpaperCLI/Utilities.swift` for the `NSColor(hex:)`
  extension) — same filename, different targets, no naming collision because they're in separate modules. Minor,
  but shows the library deliberately keeps CLI-only concerns (hex color parsing for arguments) out of the reusable
  `Wallpaper` library target. Wallwright doesn't have an equivalent library/app split today, but if any wallpaper-
  setting logic ever gets extracted into a reusable package, this separation (parsing/CLI concerns vs. core API
  logic) is the template.
- **`fixture.jpg` / `fixture2.jpg`** at repo root imply there's (or was) a test suite exercising `set`/`get`
  round-trips with real files — no `Tests/` directory currently present in this checkout, so this is inconclusive,
  but the presence of named fixtures for two distinct images suggests the "same-path different-content" bug
  (finding #2 above) may have originally been caught by an actual regression test rather than just manual QA.

## If I only had time for 3 things

1. **Replace `.main!` force-unwraps and unguarded `desktopImageURL(for:)!` calls** in `AppDelegate.swift:243`,
   `GlobalSettingsService.swift:602,607` with safe optional handling (mirroring `Wallpaper.Screen.main`'s `guard let
   mainScreen = NSScreen.main else { return [] }` pattern) — cheap, removes a real crash vector during display
   reconfiguration.
2. **Adopt the directory-vs-file resolution workaround** (`getFromDirectory`, `Wallpaper.swift:51`) or at least guard
   against it, before Wallwright ever reads back `NSWorkspace.desktopImageURL(for:)` as a single image path — right
   now a user with a folder/slideshow system wallpaper could hand Wallwright a directory URL where a file is
   expected.
3. **Surface set-wallpaper failures instead of swallowing them** — replace the `try?`/bare-`print(error)` call sites
   around `NSWorkspace.shared.setDesktopImageURL` with a typed error path (even just a user-visible banner/log), the
   way this package's `throws`-everywhere design forces callers to acknowledge failure.
