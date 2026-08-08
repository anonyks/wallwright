# Phosphene (kageroumado/phosphene) — Research Notes

Source: `references/phosphene/repo` (local clone, MIT license). macOS-only, Swift 6,
requires **macOS Tahoe 26.0+**. Two Xcode targets: `Phosphene` (menu-bar app) and
`PhospheneExtension` (an actual system wallpaper extension).

This is the single most architecturally relevant repo in the batch: it is a *shipped,
working example* of getting third-party video content onto the real macOS desktop
**and** lock screen without any window trickery — via a genuine (if barely documented)
Apple extension point. Read in full: README, both Info.plists, entitlements, pbxproj
target config, and the extension's Swift sources (`PhospheneExtension.swift`,
`WallpaperXPCHandler.swift`, `WallpaperExtensionConfig.swift`, `CallerValidation.swift`,
`VideoRenderer.swift`, `PlaybackPolicy.swift`, `PowerMonitor.swift`, `SpiralRecovery.swift`,
`SnapshotCreation.swift`), plus app-side `OcclusionMonitor.swift`,
`VideoOptimizationService.swift`, `VideoDeploymentService.swift`, `MenuBarPopoverView.swift`,
`PhospheneApp.swift`.

## 1. What each target does

**`Phosphene.app`** (unsandboxed menu-bar app, `LSUIElement = YES`): lets the user import
video files into a library, optionally transcodes them to HEVC and/or pre-renders
FPS-tiered "variants" for power saving, and writes video files + `metadata.json` directly
into `~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/videos/<uuid>/`
— i.e. it populates the *extension's* sandbox container from outside, since there's no App
Group. A Darwin notification (`glass.kagerou.phosphene.libraryChanged`) tells the extension
to re-scan. The app also exposes a menu-bar popover (preview, pause, per-display carousel,
"Restart Wallpaper Agent", update check) and a `LibraryWindow` grid/inspector.

**`PhospheneExtension.appex`**: an `ExtensionKit` extension (not a classic `NSExtension`
App Extension) that is loaded *inside the system `WallpaperAgent` process* when a Phosphene
wallpaper is active. It renders actual video frames into a **remote `CAContext`** that
WallpaperAgent composites directly onto the desktop, the lock screen, and (based on the
`presentationMode` values it receives — `"default"`, `"locked"`, `"idle"`) the idle/screensaver
surface too. It talks to WallpaperAgent over XPC using Apple's private
`WallpaperExtensionKit.framework`, loaded via `dlopen` at runtime and driven through
`Mirror`-based reflection because none of its types (`WallpaperCreationRequestXPC`,
`WallpaperIDXPC`, `WallpaperSnapshotXPC`, etc.) are in any public SDK header.

## 2. Exactly how the extension is registered

- **Product type** (`Phosphene.xcodeproj/project.pbxproj`, line 117):
  `productType = "com.apple.product-type.extensionkit-extension"` — this is Apple's
  *modern* (macOS 14+) ExtensionKit mechanism, distinct from the legacy `NSExtension`
  App Extension model.
- **Extension point declaration** (`PhospheneExtension/Info.plist`):
  ```xml
  <key>EXAppExtensionAttributes</key>
  <dict>
      <key>EXExtensionPointIdentifier</key>
      <string>com.apple.wallpaper</string>
  </dict>
  ```
  This is the actual, real, Apple-defined extension point for wallpaper providers —
  the same one Apple's own bundled Aerials/wallpaper collections presumably use.
- **Entry point**: `@main final class PhospheneExtension: NSObject, AppExtension` (from
  `import ExtensionFoundation`), exposing `var configuration: some AppExtensionConfiguration`.
  `AppExtensionConfiguration.accept(connection:)` is where the XPC surface gets built
  (`WallpaperExtensionConfig.swift`) — it whitelists the private XPC value classes via
  `NSXPCInterface.setClasses(_:for:argumentIndex:ofReply:)`, one entry per exported selector.
- **Bundle ID**: `glass.kagerou.phosphene.extension` (app is `glass.kagerou.phosphene`).
  Display name `PhospheneWallpaperExtension`.
- **Entitlements**: only the *app* target has an entitlements file
  (`com.apple.security.files.bookmarks.app-scope`, App Sandbox off). No
  `PhospheneExtension.entitlements` file exists in the repo at all — the extension's sandbox
  is presumably conferred by ExtensionKit / being hosted inside WallpaperAgent's own sandbox,
  not by an explicit entitlement in this project. (This is a place a from-scratch
  reimplementation would need to reverse-engineer further — Apple's docs on
  `com.apple.wallpaper` extensions are effectively nonexistent.)
- **Embedding**: README states "The wallpaper extension is embedded into the app bundle and
  registered with the system when the app launches" — i.e. no separate installer step;
  ExtensionKit registration happens automatically from bundle presence + code signing, similar
  to how Share/Action extensions register.
- **Capabilities a normal app window fundamentally cannot get**, all confirmed in code:
  - Runs *inside* `WallpaperAgent` (a system-owned, always-running process), not the app's own
    process — survives the app quitting entirely.
  - Composites via `CAContext.remoteContext()` directly into WallpaperAgent's layer tree
    (`caContext.layer = rootLayer`), which is what actually appears on the desktop/lock/idle
    surfaces — a third-party `NSWindow` can never be composited there regardless of window
    level tricks.
  - Appears as a first-class entry in **System Settings → Wallpaper**, with its own picker
    thumbnails, chosen exactly like an Apple-shipped wallpaper (`selectedChoicesDidChange`,
    `provideSettingsViewModels`, `addChoiceRequest`/`removeChoiceRequest` XPC methods).
  - Receives authoritative OS lifecycle signals it could never observe from outside:
    `acquire`/`update`/`invalidate`/`snapshot` calls per logical *surface* (a Space, the lock
    screen, a Settings-preview), each with a stable `WallpaperID` UUID, plus true
    `presentationMode` (`default`/`locked`/`idle`) and `activityState` from the Agent itself.
  - `CallerValidation.swift` verifies the XPC peer's code signature (`anchor apple`, ideally
    `com.apple.wallpaper.agent`) via `SecCodeCopyGuestWithAttributes` — i.e. only the OS can
    even talk to it.

## 3. Is this a real alternative to `AerialsInjector.swift`? — Honest assessment

**Partially yes, architecturally — but it is not a drop-in fix, and it trades one kind of
fragility for another, not fragility for safety.**

Arguments for "yes, this is the correct way":
- `com.apple.wallpaper` / ExtensionKit is a genuine, Apple-defined integration point, not a
  reverse-engineered file format. The OS itself drives the extension via structured XPC, and
  it shows up in System Settings as a first-class citizen next to Apple's own wallpapers.
  That is categorically different from `AerialsInjector` writing raw JSON/`Index.plist` into
  `~/Library/Application Support/com.apple.wallpaper/...` and hoping WallpaperAgent's private
  cache-loading code accepts it.
- Because it's a real extension surface, it naturally gets **desktop, lock screen, and (per
  the `"idle"` presentation-mode case) the idle/screensaver-like surface** all from one
  registration — exactly the three surfaces `AerialsInjector`'s docstring says it's trying to
  unify, but via the OS's own mechanism instead of impersonating an aerial asset.
- It sidesteps `AerialsInjector`'s specific documented bug class (second-activation blank lock
  screen from stale per-session extension state) by being the actual live extension process
  instead of a static file WallpaperAgent's *own* extension has to reload.

Arguments for "no, don't oversell it":
- It still depends on an **undocumented private framework** (`WallpaperExtensionKit`, loaded
  via `dlopen`) and **`Mirror`-based reflection** over unpublished XPC value types. Phosphene's
  own README: *"Apple could change this at any major OS release."* This is not meaningfully
  more stable than `AerialsInjector`'s undocumented file formats — it's a different unstable
  surface (private framework ABI / struct layout vs. JSON/plist schema), not a stable one.
  Phosphene's own `verifyRuntimeLayout()` self-check and the `Mirror`-parsing fallbacks
  throughout `WallpaperXPCHandler.swift` are effectively the same defensive posture
  `AerialsInjector` already has to take — just one layer deeper in the stack.
  A layout mismatch here risks crashing/hanging **inside WallpaperAgent itself** (a shared
  system process), a strictly worse failure mode than `AerialsInjector`'s current worst case
  (the injected entry silently stops appearing; desktop wallpaper via `NSWorkspace` is
  untouched).
- It requires **macOS Tahoe 26.0+** specifically (per README: "depends on the Wallpaper
  extension point introduced in macOS 14 but uses Tahoe-only SwiftUI/`glassEffect()` APIs").
  Adopting this path would likely force Wallwright's minimum deployment target up
  significantly from whatever it is today — worth checking against Wallwright's current
  `MACOSX_DEPLOYMENT_TARGET` before treating this as free. It's checked/validated on macOS 26
  and 27 beta only.
- It is a **much larger engineering lift**, not a patch: a second Xcode target with its own
  bundle ID, its own sandboxed container, its own code-signing/entitlements/notarization
  surface, an out-of-process rendering pipeline reimplementing `AVPlayerLayer`-equivalent
  behavior via raw `AVSampleBufferDisplayLayer` + manual `AVAssetReader` pump (because
  `AVPlayerLayer` "silently fails inside a remote `CAContext`" per their own code comments),
  and reverse-engineering an undocumented ~15-method XPC protocol. This is a from-scratch
  rewrite of the lock-screen delivery mechanism, best scoped as an independent R&D spike, not
  a refactor of `AerialsInjector.swift`.
- **Grey/blank-screen bugs are not unique to `AerialsInjector`**: Phosphene's own "Quirks"
  section documents a near-identical failure class — `WallpaperAgent`'s snapshot XPC coder has
  a type-check bug that silently drops frames unless runtime-swizzled, "and you get a grey
  lock screen during transitions." They also self-heal by `killall WallpaperAgent` on stuck
  states (`SpiralRecovery.swift`), the exact recovery primitive `AerialsInjector` already uses.
  This suggests WallpaperAgent's internal state fragility (including Wallwright's own
  documented "second consecutive lock-screen activation comes up blank" issue) is a **shared,
  OS-level problem class** that going through the "correct" extension point does not fully
  solve — it just moves where the workarounds live.

**Bottom line**: this is real evidence the *correct* long-term direction for lock-screen
integration is an ExtensionKit `com.apple.wallpaper` provider, and it's worth a scoped,
throwaway prototype gated to macOS 26+ to see whether it actually eliminates the
second-activation-blank bug in practice. It should not be treated as a safe, incremental
replacement for `AerialsInjector.swift` today — it's a parallel, higher-risk-but-higher-
ceiling bet, and both approaches ultimately depend on undocumented Apple internals.

## 4. Other UI/UX findings (mostly `Phosphene/` app target)

- **Menu-bar popover** (`MenuBarPopoverView.swift`): per-display carousel with page dots when
  multiple wallpapers are active, live preview thumbnail, explicit **playback-status text**
  state machine (`"Paused — Only on Lock Screen"`, `"Paused — Desktop Hidden"`, `"Paused"`,
  `"Playing"`) — good transparency pattern: the user always sees *why* it's paused, not just
  that it is. Wallwright's own status UI could adopt this instead of a single generic
  "Paused" state.
  Also uses `.glassEffect(.clear)` (Tahoe-only) on nav arrows — a UI dead-end for Wallwright if
  it needs to support older macOS, but confirms Apple's glass-material direction for controls.
- **"Restart Wallpaper Agent" is a first-class, user-facing menu item**, not just an internal
  auto-recovery action — explicit self-service UX for exactly the class of "stuck/grey/wrong
  video" bug both projects hit. Wallwright's `AerialsInjector` currently only does periodic
  silent health-check re-injection (every 5 min); exposing an equivalent manual "Restart
  Wallpaper Agent" affordance would give users a way to unstick the second-activation-blank
  bug immediately instead of waiting on the timer or not knowing what's wrong.
- **"Only on Lock Screen" toggle ramps, not cuts**: `PlaybackPolicy`/`VideoRenderer` cross-fade
  playback rate with a 2s ease-in-out cubic curve on desktop↔lock transitions
  (`rampUp`/`rampDown` in `VideoRenderer.swift`) "matching Apple's own Aerials behavior."
  Wallwright's `ClockOverlay`/wallpaper transitions currently likely hard-cut; borrowing a
  short eased ramp on pause/resume transitions is a cheap, extension-independent UX win.
- **Update checking and "Check for Updates" row** built into the popover itself
  (`UpdateCheckService`) rather than requiring the user to visit a separate window.

## 5. Performance / optimization findings

- **`PlaybackPolicy` (graduated tiers, not a single bool)** — `full → reduced → minimal →
  paused`, driven by: thermal state (`.critical`→paused, `.serious`→minimal, `.fair`→reduced),
  battery level (<10%→paused, <20% on battery→minimal), on-battery at all→reduced, Game Mode
  active→paused, presentation mode `"idle"`→paused, desktop occlusion→paused (skipped on lock
  screen, correctly, since occlusion is meaningless there), and — notably — **near-zero display
  brightness→paused even though the display is technically still awake** (`PowerMonitor.swift`,
  `brightnessPauseThreshold = 0.05`, read via `IORegistryEntryCreateCFProperty` on
  `AppleBacklightDisplay`, polled every 30s since there's no brightness-change notification).
  This brightness-based pause is a real edge case (`screensDidSleep` never fires if the user
  just drags brightness to zero) that Wallwright's existing battery-aware throttling should be
  checked against — it's cheap to add and closes a real battery-drain gap.
- **Occlusion detection algorithm** (`OcclusionMonitor.swift`, app-side, not extension-side
  because the sandboxed extension can't call `CGWindowList`): rasterizes the screen's
  `visibleFrame` into an 8pt grid, marks cells covered by on-screen layer-0 windows from
  `CGWindowListCopyWindowInfo`, and calls it "occluded" at ≥95% coverage. Event-driven
  (app activate/deactivate, space change) plus a 10s poll fallback to catch plain window
  moves/resizes (which have no notification). This is a concrete, self-contained algorithm
  Wallwright could lift directly for a "pause when fully covered by windows" feature if it
  doesn't already have one.
- **Gapless looping without `AVPlayerLooper`**: because `AVPlayerLayer` doesn't composite in a
  remote `CAContext`, they drive `AVSampleBufferDisplayLayer` manually — one `AVAssetReader`
  for the current loop, a second one preloaded for the next loop's first frames, and a
  `ptsOffset` that accumulates across loop boundaries so DTS/PTS stay monotonically increasing
  (no timebase reset, no flush, no stutter at the loop point). Less directly relevant to
  Wallwright since it already uses `AVPlayer` (where `AVPlayerLooper` handles this), but useful
  reference if any loop-boundary stutter is ever reported.
- **"Deep pause" resource teardown**: after 30s of sustained pause, it fully releases the
  `AVAssetReader`/decoder pipeline (not just `rate = 0`) to free memory and let the video
  decoder actually idle; on resume it seamlessly reconstructs the pipeline **continuing from
  the paused position** (`recreatePlayback(seamlessResume: true)`), not restarting from 0. A
  meaningful pattern for long lock-screen sessions (laptop locked overnight) that Wallwright's
  own playback throttling should be checked against — pausing alone doesn't free decoder
  resources.
- **Documented cautionary bug**: `generateStillFrame()` was deliberately disabled — it used to
  spin up a fresh `AVAssetImageGenerator` (its own decoder) on every pause event, and when the
  desktop thrashed between idle/default states these piled up and starved the live playback
  reader of decoder resources for ~20s. Concrete warning against spinning up secondary
  decode/image-generation pipelines reactively on frequent state-change events — worth checking
  Wallwright doesn't do anything analogous (e.g. thumbnail/preview regeneration on frequent
  playlist or display events).
- **Adaptive FPS-tiered "variants"**: `VideoOptimizationService` pre-renders halved-FPS variants
  at import time (tiers computed by repeated halving, floor 8fps in the app-side service vs.
  floor 15fps in the extension's `PlaybackPolicy.fpsTiers` — an internal inconsistency in their
  own codebase worth noting, not copying), and the renderer picks the cheapest variant that
  satisfies the current policy tier at each loop boundary. This is a genuine perf axis
  Wallwright doesn't appear to have (throttling via pause/opacity rather than swapping to a
  lower-fps pre-rendered asset) — decoding fewer frames/sec is a more direct battery win than
  just reducing what's rendered on screen.

## 6. If I only had time for 3 things

1. **Spike (not ship) an ExtensionKit `com.apple.wallpaper` prototype, gated to macOS 26+,
   as a parallel path — not a replacement.** The extension point is real and does solve the
   category of problem `AerialsInjector` hacks around, but it's a private-framework-dependent,
   Tahoe-only, multi-week rewrite with its own crash-inside-WallpaperAgent risk. Time-box a
   throwaway prototype specifically to test whether it actually fixes the
   second-consecutive-activation-blank bug in practice before committing further; keep
   `AerialsInjector` as the supported path for pre-Tahoe systems regardless of outcome.
2. **Add brightness-near-zero and thermal-state signals to Wallwright's existing
   battery-aware throttling**, and free decoder resources (not just pause) after a sustained
   idle/lock period — both are small, self-contained, extension-independent wins lifted
   directly from `PowerMonitor.swift` / `PlaybackPolicy.swift` / the "deep pause" pattern in
   `VideoRenderer.swift`.
3. **Expose a user-facing "Restart Wallpaper Agent" action and per-reason pause-status text**
   in Wallwright's UI, mirroring `MenuBarPopoverView.swift`. Cheap, immediately actionable
   self-service UX for exactly the failure class (`killall WallpaperAgent` recovery,
   ambiguous "why is it paused") both projects already have to work around.
