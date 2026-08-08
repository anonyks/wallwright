# References — competitive/technical research index

A long-term knowledge base built from studying 8 related open-source (and closed-source-but-documented)
macOS/desktop wallpaper projects, evaluated against Wallwright's two standing priorities: **(1) UI/UX** and
**(2) Performance & Optimization**. Each subdirectory has a local clone (`repo/`) and a detailed `NOTES.md`.
This file is the synthesis — read it first, then follow links into the per-repo notes for file/line citations.

Research date: 2026-07-28. All repos cloned shallow (`--depth 1`) into `references/<slug>/repo/`, which is
untracked by git (large, and not meant to ship with Wallwright itself).

## The single most important finding

**WaifuX — Wallwright's core rendering architecture is already correct.** WaifuX is by far the most ambitious
project in this batch (a real Metal renderer, a vendored Rust/wgpu scene engine, a macOS 26 ExtensionKit
lock-screen extension) — and its own `SceneOfflineBakeService` pre-renders GPU scene wallpapers to H.264 MP4
and plays them back with plain `AVQueuePlayer`/`AVPlayerLayer`, specifically because that's the version that
can actually run all day without cooking a laptop. **A team that built the fancier renderer independently
concluded video + hardware decode is the right way to run a wallpaper long-term.** That's real, external
validation of Wallwright's video-only decision — not a case of Wallwright taking a shortcut competitors avoided.
See [`waifux/NOTES.md`](waifux/NOTES.md).

## Cross-cutting signals (found independently in 3+ repos — strongest evidence)

These aren't single opinions — multiple, unrelated codebases converged on the same fixes, which is a much
stronger signal than any one repo's opinion:

1. **Event-driven occlusion/visibility detection, not polling.** LivePaper (`NSWindow.didChangeOcclusionStateNotification`),
   LiveWallpaperMacOS (`CGWindowListCopyWindowInfo`-based coverage %), and WaifuX (AX-observer + coverage-% +
   hysteresis + post-wake grace window) all detect "is my wallpaper actually visible" far more precisely and
   cheaply than Wallwright's current `FullscreenAppMonitor.swift`, which polls every 5s and only checks whether
   the *frontmost* app's window fills the screen — missing large non-fullscreen windows sitting on top of the
   desktop, and lagging up to 5s either direction. **This is the top actionable performance/battery finding of
   the whole batch.** WaifuX's version is the most complete reference implementation (coverage-% threshold +
   hysteresis band + N-stable-samples debounce + a grace window after display-configuration changes, since
   `CGWindowListCopyWindowInfo` returns empty lists transiently after those).
2. **`AVQueuePlayer` + `AVPlayerLooper` for gapless single-clip looping**, instead of manual
   seek-to-zero-on-`didPlayToEndTime` (Wallwright's current approach in `VideoWallpaperViewModel.swift`).
   Found in LivePaper, LiveWallpaperMacOS, *and* WaifuX (WaifuX also adds a freeze-frame `CALayer` shown while
   `isReadyForDisplay == false`, to kill the loop-boundary black flash entirely). Apple's purpose-built API for
   exactly this use case; the seek-based approach is the one thing all three more-established/ambitious projects
   independently moved away from.
3. **Self-healing / recovery from a stalled or failed player.** LivePaper detects `.status == .failed` and
   escalates through `reloadAllPlayers()`/`rebuildAllPlayers()`; WaifuX has orphan-process reaping and its own
   recovery layers; Wallwright's `AerialsInjector` has a health-check timer for the *lock-screen* registration
   but nothing watches the *live desktop* `AVPlayer` for a silent stall. Real robustness gap: right now a wedged
   player just sits there frozen with no path back to working.

## Prioritized action list

Ranked by (impact × how directly portable the idea is), not by which repo it came from.

### Performance & Optimization
1. **Replace `FullscreenAppMonitor`'s 5s poll with event-driven occlusion detection** (cross-cutting finding #1
   above). Biggest single win available — same UX guarantee, near-zero idle cost, catches more cases.
2. **Adopt `AVQueuePlayer`/`AVPlayerLooper` + freeze-frame-on-loop** (cross-cutting #2). Requires re-validating
   against the existing dual-audio-player lock/unlock workaround (`VideoWallpaperViewModel.swift`) since it
   touches the same player-lifecycle code — not a trivial swap, but well-specified by three independent examples.
3. **Share one `AVQueuePlayer` across mirrored/identical-content displays** (WaifuX, capped at 2 screens —
   3+ caused VSync judder in their testing). Wallwright currently decodes the same file N times for N screens
   showing the same wallpaper; this halves that in the common 2-display case.
4. **Investigate whether `preferredPeakBitRate` battery throttling is actually a no-op for local files.**
   WaifuX's code comment explicitly states it's an ABR (adaptive bitrate streaming) hint with no effect on a
   local MP4 — worth checking whether `VideoWallpaperViewModel.applyBatteryMode()`'s battery savings are real or
   partially placebo (the `preferredMaximumResolution` half almost certainly still works; the bitrate cap is the
   part in question).
5. **`ScreenConfigurationSignature`-style debouncing for `didChangeScreenParametersNotification`** (WaifuX,
   ~20 lines) — ignore spurious re-fires of that notification that don't actually change anything relevant.
6. **Event-driven battery detection** (`IOPSNotificationCreateRunLoopSource`, phonto) instead of
   `BatteryMonitor.swift`'s 30s polling `Timer` — small, low-risk, directly portable.
7. **A plausible root-cause fix for `AerialsInjector`'s flaky-blank-on-second-lock-activation bug**: phonto
   transcodes to HEVC Main10 with 2 temporal sub-layers before registering as an Aerial, with a code comment
   that "the lock-screen player needs this shape to re-arm across lock cycles." Wallwright currently just copies
   the raw file and papers over the symptom with a 5-minute health-check + forced `WallpaperAgent` restarts.
   Worth a real test — if this is the actual cause, it replaces a workaround with a fix.

### UI/UX
1. **Surface wallpaper-set failures instead of silently swallowing them** (macos-wallpaper). Wallwright's
   `try?`/bare-`print(error)` pattern around `NSWorkspace.setDesktopImageURL` and friends means a failure is
   currently invisible to the user; sindresorhus's package treats every failure as a typed, user-facing error.
2. **Fix the real crash risk in `.main!` force-unwraps and unguarded `desktopImageURL(for:)!`**
   (`AppDelegate.swift:243`, `GlobalSettingsService.swift:602,607`, `AppDelegate.swift:340`) — a user with a
   folder/slideshow system wallpaper, or a transient `NSScreen.main == nil` during display reconfiguration, can
   crash Wallwright today. Not a UI/UX polish item, a correctness bug this research surfaced.
3. **`LiquidGlassLevel`-style single-intent-axis glass modifier** (WaifuX `DesignSystem/`) — one enum driving
   ~8 correlated visual properties (opacity, blur, tint, border) instead of setting each SwiftUI glass modifier
   ad hoc per view, which is closer to how Wallwright's own popup system (Display/Clock/Playlist/YouTube/Steam)
   is currently styled per-view. Also: `AppFluidMotion.swift`'s 5 named motion/animation constants, worth
   copying close to verbatim for consistency across Wallwright's own popups and transitions.
4. **Per-reason pause-status text and a user-facing "Restart Wallpaper Agent" button** (Phosphene) — currently
   Wallwright's own `killall WallpaperAgent` recovery is invisible/automatic-only; exposing it as an explicit
   user action (for when the lock-screen aerial goes blank) turns a silent self-heal into a visible "click here
   to fix it" escape hatch, and telling the user *why* playback is paused (locked vs. battery vs. fullscreen app)
   is more transparent than a single generic paused state.
5. **A manual "Refresh Video Wallpaper" menu-bar action** (vidwall) — cheap, and directly useful given
   `AerialsInjector`'s own documented flakiness; gives the user a way to force-recover without knowing to quit/reopen.

## What turned out NOT to be worth adopting (equally valuable to know)

- **GPU-direct rendering (Metal/wgpu) instead of AVPlayer** — see the headline finding above. WaifuX's own team
  moved *away* from this for anything that needs to run all day.
- **ExtensionKit lock-screen extension as a replacement for `AerialsInjector`** — both Phosphene and WaifuX
  implement this, and both confirm it's the *architecturally correct* approach, but also: requires macOS 26+,
  depends on private/reverse-engineered frameworks Apple could break at any release, is a multi-week rewrite,
  and both projects document their *own* similar lock-screen bug classes — the "correct" mechanism doesn't
  actually escape `WallpaperAgent`'s underlying fragility. Verdict from both independent examples: worth a
  time-boxed, macOS-26-gated prototype someday, not a replacement for `AerialsInjector` now.
- **Multi-playlist / tags / scheduling** — vidwall (a shipped, paid competitor) has *none* of this after 15
  changelog versions, just a flat list and one paywalled loop toggle. External confirmation that Wallwright's
  deliberate single-playlist simplicity isn't leaving an obviously-expected feature on the table.
- **Ambitious cross-language rendering pipelines in general** (phonto's Wayland/GStreamer/VA-API path) — validates
  that Wallwright's `AVPlayerLayer` already gets the same GPU-resident, zero-copy benefits for free on macOS;
  nothing to port.

## Per-repo index

| Repo | What it is | Notes |
|---|---|---|
| [WaifuX](waifux/NOTES.md) — **highest priority** | Ambitious commercial-grade macOS wallpaper engine: Metal renderer, vendored Rust/wgpu scene engine, ExtensionKit lock-screen extension, real design system | 809 lines — the deepest doc in this batch. Read this one first. |
| [Phosphene](phosphene/NOTES.md) | App + genuine `com.apple.wallpaper` ExtensionKit extension | Second independent worked example of the lock-screen extension approach; corroborates WaifuX's findings on it |
| [LivePaper](livepaper/NOTES.md) | The project Wallwright already adapted 5 files from (AerialsInjector, ClockOverlay, LockScreenSync, BatteryMonitor, CommandListener) | Confirms Wallwright's `AerialsInjector` already exceeds LivePaper's own in most respects; the one thing Wallwright dropped from it (WallpaperAgent cache-clearing) was a correct call, not a gap |
| [LiveWallpaperMacOS](live-wallpaper-macos/NOTES.md) | ObjC++ core wallpaper daemon + Swift UI | Source of the occlusion-based throttling and UUID-keyed-display-identity findings |
| [phonto](phonto/NOTES.md) | Rust, cross-platform (macOS + Wayland) live-wallpaper engine | Despite the language gap, directly portable VideoToolbox/IOKit API findings — not just concept-transfer |
| [macos-wallpaper](macos-wallpaper/NOTES.md) | sindresorhus's small, focused Swift Package wrapping the public wallpaper API | Best source for defensive-coding/error-handling lessons; surfaced two real crash-risk gaps in Wallwright |
| [vidwall](vidwall/NOTES.md) | Shipped, paid, closed-source macOS wallpaper app | No source available — findings come from changelog/screenshots only; useful as an external sanity-check on scope decisions |
| [wallpaper-player-mac](wallpaper-player-mac/NOTES.md) | Wallwright's own great-grandparent in its fork lineage | Turned out to contain no app source at all (docs/SPM stub only) — real app was closed-source TestFlight; redirect further lineage research to `MrWindDog/wallpaper-engine-mac` instead |

## Housekeeping notes

- `references/*/repo/` are local clones for research purposes only — untracked by git (large, not meant to ship).
  `references/*/NOTES.md` and this file are the actual durable output and should be committed.
- LivePaper is credited in 5 file headers ("Adapted from LivePaper...") but not yet in Wallwright's top-level
  `README.md` Credits section, which lists every other upstream/adapted-from source. Worth adding for consistency.
- A `git log` search during this research surfaced a commit titled "remove playlist" from Wallwright's own
  history — turned out to be unrelated to the current Playlist feature: every button in it was an empty `{ }`
  closure with the whole bar `.disabled(true)`, pure unfinished placeholder UI that got cleaned up. No design
  lesson carries over from it.
