# LivePaper — Research Notes

Reference repo: `references/livepaper/repo` (local clone, ~3035 lines of Swift, no Xcode
project — built via `build3.sh`/`swiftc`). Read 2026-07-28.

## What it is

LivePaper is a free, open-source (MIT) macOS menu-bar app that turns any local video file into
a live desktop wallpaper that *also* plays on the lock screen and idle screensaver — the same
niche as Wallwright, built independently, targeting macOS Tahoe (16.0+) only. Its headline trick,
credited to the closed-source "Backdrop" app as prior art, is writing directly into Apple's
undocumented aerials manifest (`~/Library/Application Support/com.apple.wallpaper/aerials/`) so a
user video gets registered as if it were one of Apple's own aerial screensavers, then restarting
`WallpaperAgent` so the system picks it up — because no ordinary app window can draw above the
lock screen, this is the only way to get a custom video there at all. Beyond that it's a single
`AVQueuePlayer`+`AVPlayerLooper` wallpaper engine, a Mond-style (Rainmeter-inspired) clock overlay,
battery-aware quality throttling, a YouTube-import dashboard, and a `/tmp` named-pipe CLI. Five
Wallwright files carry "Adapted from LivePaper" headers (`AerialsInjector.swift`,
`ClockOverlay.swift`, `LockScreenSync.swift`, `BatteryMonitor.swift`, `CommandListener.swift`), so
part of this research is a direct diff of those against LivePaper's originals — the short version
is Wallwright already *exceeded* the original in most of those five (health monitoring, orphan
pruning, atomic thumbnail writes, gradient/draggable/Summit-format clock, notification-based
battery singleton), but LivePaper's non-adapted code (`VideoPlayer.swift`, `Screensaver.swift`,
`LivePaperApp.swift`, `WindowPersistence.swift`) has several ideas Wallwright doesn't have yet.

## If I only had time for 3 things

1. **Event-driven occlusion pause** (performance) — swap or augment `FullscreenAppMonitor`'s 5s
   `CGWindowListCopyWindowInfo` poll with `NSWindow.didChangeOcclusionStateNotification` on
   Wallwright's own wallpaper windows, like `LivePaperApp.swift`'s `handleOcclusionChange()`. Zero
   polling cost, instant reaction, and it catches cases the size-heuristic can't (Mission Control,
   several overlapping non-fullscreen windows stacking to fully cover a display, Notification
   Center, etc.).
2. **Gapless loop via `AVQueuePlayer` + `AVPlayerLooper`** (performance + UI/UX) — LivePaper's
   `VideoPlayer.swift` pre-queues the next loop iteration instead of seeking to zero after
   `AVPlayerItemDidPlayToEndTime` fires (Wallwright's current approach in
   `VideoWallpaperViewModel.swift`). Bigger architectural lift (means dropping `AVPlayerView`/AVKit
   for a raw `AVPlayerLayer`, which also needs re-validating against the dual-audio-player
   workaround), but it's the single biggest visible-quality gap between the two engines — a
   loop-point hitch is exactly the kind of thing a wallpaper app can't hide.
3. **Cheap window-level watchdog** (UI/UX, near-zero cost) — `WindowPersistence.swift` re-asserts
   wallpaper/clock window level and calls `orderFront` every 5 seconds if a window somehow isn't
   visible. Wallwright has nothing equivalent. Trivial to add, and it's cheap insurance against
   "my wallpaper vanished" bug reports caused by some other app or system UI stealing z-order.

---

## Findings

### 1. Occlusion-based pause is event-driven in LivePaper, polled in Wallwright

- **LivePaper**: `Sources/LivePaperApp.swift` registers `NSWindow.didChangeOcclusionStateNotification`
  per wallpaper window at `setupWallpaper()` (lines ~113-116) and reconciles in
  `handleOcclusionChange()` (lines 194-207): if none of the wallpaper windows have
  `.occlusionState.contains(.visible)`, it calls `v.pause()` on every video view; when any becomes
  visible again it resumes (unless paused for another reason). This is pure AppKit push
  notification — no polling, no CPU cost when nothing changes, and it reflects true compositor
  occlusion (covers Mission Control, stacked non-fullscreen windows, screensaver, anything).
- **Wallwright**: `Wallwright/Services/FullscreenAppMonitor.swift` polls every 5s via
  `CGWindowListCopyWindowInfo`, checking only whether the **frontmost app's own front window** is
  `>=` some display's size. This is a heuristic proxy for occlusion, not occlusion itself: it
  misses several overlapping windows (from possibly different apps) that together cover the
  screen, and it has up to 5s of lag before reacting either direction. It *is* wired up for real
  (`GlobalSettingsService.swift:467,530` gate pause/mute behavior on
  `FullscreenAppMonitor.shared.isOtherAppFullscreen`), so this isn't a hypothetical gap — it's
  Wallwright's actual mechanism for "pause when fully covered."
- **Category**: performance (removes a periodic poll + `CGWindowListCopyWindowInfo` call), also
  correctness (`didChangeOcclusionStateNotification` is strictly more accurate).
- **Applicability**: **adapt**. Wallwright's `VideoWallpaperViewModel.swift` already listens to
  `NSWindow.didChangeOcclusionStateNotification` (line 115) but only to re-assert `playRate` after
  a Space-switch quirk — it doesn't check `occlusionState` itself. Extending that existing observer
  to also check `window.occlusionState.contains(.visible)` and feed a real pause/resume decision
  (replacing or supplementing `FullscreenAppMonitor`) looks like a small, contained change.

### 2. Gapless looping: `AVPlayerLooper` (LivePaper) vs. seek-to-zero (Wallwright)

- **LivePaper**: `Sources/VideoPlayer.swift` builds on raw `AVQueuePlayer` + `AVPlayerLooper`
  (`setupPlayer()`, lines 28-60) — the looper pre-buffers/re-queues the next loop iteration so
  there's no decode-restart stall at the loop point. It also sets
  `player.automaticallyWaitsToMinimizeStalling = false` (start immediately rather than waiting on
  buffer) and `preventsDisplaySleepDuringVideoPlayback = false` (display-sleep prevention is
  instead handled manually and only during an actual lock, in `Screensaver.swift`/
  `LockScreenSync.swift` — see finding 6).
- **Wallwright**: `Wallwright/Services/VideoWallpaperViewModel.swift`'s `playerDidFinishPlaying(_:)`
  (lines 143-161) reacts to `AVPlayerItemDidPlayToEndTime` by calling `player.seek(to: .zero)` then
  re-applying rate — a real (if usually brief) stop-start rather than a pre-queued continuation.
  Under `AVPlayerView`/AVKit, not raw `AVPlayerLayer`. Note: Wallwright *does* use
  `AVPlayerLooper` already, but only in `ContentView/Components/MotionBgsView.swift` (a lightweight
  preview component), not in the main wallpaper engine.
- **Category**: both — UI/UX (loop-point smoothness is directly visible on something meant to be
  ambient background) and performance (avoids a decode-pipeline restart every loop).
- **Applicability**: **adapt, non-trivial**. Bigger lift than it looks: migrating off
  `AVPlayerView` means re-deriving whatever AVKit was doing for free (video gravity, frame
  analysis toggling — see finding 3) as raw `AVPlayerLayer` code, and re-validating it against the
  existing dual-`AVPlayer` audio workaround (`VideoWallpaperViewModel.swift`'s `audioPlayer`,
  documented 2026-07-25) since that fix was specifically about `AVPlayerView`'s combined
  video+audio pipeline breaking after lock/unlock — a different player class might change that
  calculus entirely (for better or worse).

### 3. Two more player-layer tricks bundled with the `AVPlayerLooper` migration

- **Battery-mode compositing win, not just decode win**: `VideoPlayer.swift`'s `setBatteryMode(_:)`
  (lines 154-166) does more than cap `preferredMaximumResolution`/`preferredPeakBitRate` (which
  Wallwright already matches in `applyBatteryMode()`) — it also sets
  `playerLayer.contentsScale = 1.0` on battery ("4x fewer pixels to composite" per the inline
  comment), vs. the screen's real backing scale factor otherwise. This is a **GPU compositing**
  optimization layered on top of the **decode** optimization Wallwright already has, and it isn't
  reachable through `AVPlayerView` (no exposed `contentsScale` control) — another point in favor of
  eventually owning the `AVPlayerLayer` directly. **Adapt** (performance, blocked on finding 2).
- **Self-healing GPU pipeline reconnect**: `forceResume()` (lines 168-194) checks
  `player.timeControlStatus == .playing && !playerLayer.isReadyForDisplay` after resuming and, if
  true, force-reconnects the layer (`playerLayer.player = nil; playerLayer.player = player`) — a
  documented, cheap fix for "the GPU rendering pipeline broke" that a plain resume doesn't recover
  from. Paired with `isRenderingFrames` (lines 250-253), a nearly-free sanity check
  (`timeControlStatus == .playing && playerLayer.isReadyForDisplay`) used by `Screensaver.swift`'s
  tiered recovery (see finding 5). **Adapt** (performance/robustness, same blocker as finding 2).

### 4. LivePaper's own window can render above the *idle* screensaver — Wallwright never tries

- **LivePaper**: `Screensaver.swift`'s `ScreensaverController` treats "idle screensaver, not
  locked" as a separate case from "locked." On `systemScreensaverDidStart` while *not* locked, it
  calls `activate()` (lines 252-294), which raises LivePaper's **own** wallpaper windows to
  `NSWindow.Level.screenSaver.rawValue + 1` (above the system screensaver) and shows its own Mond
  clock overlay at `+2`, with a 2-second maintenance timer (`maintenanceTick`, lines 359-376) that
  re-raises the windows and checks `isRenderingFrames` to catch/recover a broken pipeline while
  idle. Only for the *actual lock* (`screenLocked()`, lines 177-205) does it fall back to
  hiding its own windows and trusting the aerials-injected system screensaver, since a real lock
  screen genuinely can't be drawn over.
- **Wallwright**: `LockScreenSync.swift` only listens for `com.apple.screensaver.didStop` (to
  prewarm the next aerials activation) — there's no `didStart` handler and no distinct "idle,
  unlocked" behavior. `AerialsInjector.swift`'s `configureScreensaverForAerials()` points the
  classic screensaver module at Apple's `WallpaperAerialsExtension` on every inject, so in theory
  the *same* injected aerial plays during idle-and-unlocked too, without needing LivePaper's
  window-raising fallback at all — a more elegant single-mechanism design, if it holds up.
- **This is the "surprising/cautionary" item, not a straightforward feature gap**: LivePaper's
  author built a whole second code path (`activate()`/`maintenanceTick()`/its own clock window) for
  a case Wallwright's design claims a single mechanism already covers. That's either LivePaper
  being needlessly defensive, or LivePaper's author having found empirically that
  `configureScreensaverForAerials()` alone isn't reliable for the idle-unlocked case specifically
  (only for the genuine lock screen) and building a fallback after hitting that in practice. Worth
  **actually testing** on Wallwright: trigger idle screensaver *without* locking and confirm the
  aerial plays correctly rather than showing a black/frozen frame. If it's ever flaky, LivePaper's
  own-window-raise fallback is the adaptable answer.

### 5. Tiered playback self-healing — LivePaper has it, Wallwright has none

- **LivePaper**: three redundant recovery layers in `VideoPlayer.swift`/`Screensaver.swift`:
  `observeLooper()` (looper `.status == .failed` → full rebuild), `observeItemStatus()` (item
  `.failed` → full rebuild), `observeEndTime()` (fallback if the looper doesn't restart within 0.3s
  of natural end → manual seek+play). On top of that, `Screensaver.swift`'s
  `checkAndRecoverPlayback()` (lines 333-349) escalates: first two failures within an active
  screensaver session get a lighter `reloadAllPlayers()`, the third+ gets a full
  `rebuildAllPlayers()` — checked both right after `activate()` (0.8s/2.5s delays) and every 2s via
  `maintenanceTick()` while idle.
- **Wallwright**: no equivalent found — `VideoWallpaperView.swift`/`VideoWallpaperViewModel.swift`
  have sleep/wake and occlusion re-assertion (`systemWillSleep`/`systemDidWake`/
  `windowOcclusionStateDidChange`, all just re-apply `rate`), but nothing that detects "the player
  item or layer entered a genuinely broken state" the way `isRenderingFrames`/`.status == .failed`
  do, and nothing that tears down and rebuilds the pipeline.
  Grepped for `isRenderingFrames`/`reloadAllPlayers`/`rebuildAllPlayers`/recovery-style code —
  nothing found.
- **Category**: performance/robustness (avoids a silently-frozen wallpaper needing a manual
  relaunch) — arguably also UI/UX by consequence (nothing to look at is a UI bug even if the cause
  is a backend fault).
- **Applicability**: **adapt**. Doesn't require the `AVPlayerLooper` migration — the "watch for
  `.status == .failed` / `!playerLayer.isReadyForDisplay` and rebuild" pattern applies just as well
  wrapping `AVPlayerView`'s player, though `isRenderingFrames`-style checks would need
  `AVPlayerView`'s own layer, which isn't as directly exposed as raw `AVPlayerLayer`.

### 6. Lock-screen sleep-prevention assertion — already adapted near-identically

- `LockScreenSync.swift` already carries LivePaper's exact pattern from `Screensaver.swift`'s
  `startLockSleepAssertion()`/`releaseLockSleepAssertion()` (lines 392-413): an
  `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep, ...)` assertion taken
  only on lock, only on AC power (`BatteryMonitor.checkOnBattery()` gate), released on unlock. This
  is a clean 1:1 adaptation — no gap. **Already have it.**
- One difference worth noting: LivePaper's `Screensaver.swift` takes a *second*, separate
  assertion for the idle-screensaver-active (not locked) case (`startSleepAssertion()`, not
  battery-gated) — consistent with finding 4's dual-path design. Given Wallwright doesn't have that
  second path, this doesn't currently apply, but it's the same asymmetry to watch for.

### 7. AerialsInjector: Wallwright improved on most of it, but dropped one thing on purpose

Direct diff of `Sources/AerialsInjector.swift` (LivePaper, 378 lines) vs.
`Wallwright/Services/AerialsInjector.swift` (427 lines):

- **Wallwright added, not in LivePaper**: periodic health monitoring (`startHealthMonitoring()`,
  5-min timer), `prewarmForNextActivation()` (restart ahead of the moment it's needed to avoid a
  visible black gap — LivePaper always restarts inline in `inject()`), `pruneOrphanedAssets()`
  (LivePaper's `.mov`/`.png` files with a fresh UUID per switch accumulate forever — Wallwright
  found and fixed a live ~740MB leak this way), `.atomic` thumbnail writes (fixes a real
  concurrent-write corruption bug LivePaper's plain `write(to:)` is still exposed to if two
  `inject()` calls race), and `includeInShuffle: false` (LivePaper's `true` risks the aerials
  shuffle algorithm coming up with "nothing to play" when there's only one custom asset registered
  — documented reasoning in Wallwright's comment, not present in LivePaper at all).
- **LivePaper has, Wallwright deliberately dropped**: `restartWallpaperAgent()` in LivePaper also
  clears `WallpaperAgent`'s own extension cache directory (`.bmp` files +
  `cacheVersion.db` reset) before the `killall`, and `verifyAgentRestart()` blocks (up to 5s,
  `Thread.sleep` in a loop) confirming the agent actually came back before returning. Wallwright's
  version comment (lines 400-408) explains this was tried and removed: reaching into
  WallpaperAgent's sandboxed container triggered a persistent macOS "access data from other apps"
  permission prompt that didn't even persist reliably across launches — a real dead end LivePaper's
  code doesn't warn about but Wallwright hit directly. **Cautionary, not a gap** — don't re-add the
  cache-clearing step; it's a documented pitfall already worked around correctly.
- Net: this file is a case where the "5 adapted files" framing undersells how far Wallwright's
  version has already diverged for the better — the one LivePaper behavior it lacks
  (`verifyAgentRestart`'s blocking confirmation loop) is itself double-edged, since blocking the
  calling thread for up to 5s on `Thread.sleep` is its own minor foot-gun if ever called on main.

### 8. `CommandListener` — already fully adapted, Wallwright improved the file permission

Near-identical named-pipe (`mkfifo`) architecture. Wallwright's version fixed a real issue
LivePaper still has: LivePaper's `mkfifo(path, 0o644)` is world-readable, so any other local
account on a shared Mac could watch commands go by; Wallwright uses `0o600`. One command LivePaper
has that Wallwright dropped: `change <path>` (switch video by absolute path over the pipe) — minor,
not performance/UI-critical, low priority to restore.

### 9. Clock overlay: Wallwright's version substantially exceeds `MondClockView`

`ClockOverlay.swift` already ported the useful *technique* from `MondClock.swift` — a
timer interval that drops to 30s (vs. 1s) when seconds aren't displayed, `tolerance` set to 20% of
interval for OS timer coalescing — and then built well past it (gradient text via `.sourceIn`
blend masking, drag-to-reposition with a `constrainFrameRect` override to defeat the menu-bar drag
ceiling, a full "Summit" Rainmeter-skin layout port, alignment options, debounced position
persistence). **Already have it, and then some.**

One thing worth flagging as a **cautionary/interesting aside**, not a Wallwright gap: LivePaper's
`MondClockView` is `wantsLayer = true` but never suppresses implicit layer actions
(`layer?.actions = [...]`), unlike Wallwright's `ClockOverlayView.init` (line 117), which does this
specifically to prevent a documented "garbled/doubled text" crossfade artifact on redraw.
LivePaper's clock style 1 (`showSeconds`, 1s refresh — the exact condition Wallwright's own comment
says makes the artifact "very visible") has no such suppression, so it plausibly has the same bug
Wallwright already found and fixed independently. Not actionable for Wallwright, just confirms the
fix was worth making.

### 10. `BatteryMonitor` — functionally identical; both projects poll rather than push

Wallwright's version (already-adapted) is a straight match on the actual battery check
(`IOServiceGetMatchingService("AppleSmartBattery")`/`ExternalConnected`), just refactored into a
shared singleton with `NotificationCenter` broadcast instead of a single closure, to support
multiple wallpaper windows. Neither project uses IOKit's push-based power-source notification API
(`IOPSNotificationCreateRunLoopSource`) — both poll every 30s. Not a LivePaper-vs-Wallwright
difference, so not actionable here, but worth knowing neither reference implementation is doing
the theoretically-optimal thing.

### 11. Window-level watchdog — LivePaper has one, Wallwright has nothing comparable

`WindowPersistence.swift`'s `WindowPersistenceManager` (24 lines total) is a 5-second timer that
force-reasserts `w.level` on every wallpaper/clock window and calls `orderFront` if a window
somehow isn't visible — a blunt but cheap defense against something else (another app, a system
service, Dock/Finder relaunch) stealing z-order out from under the wallpaper. No equivalent exists
in Wallwright. Trivial to add; see top-3 list.

### 12. Cautionary: `VideoLibrary.thumbnail(for:)` blocks its caller despite an async API

`Sources/VideoLibrary.swift`, lines 62-79: uses `AVAssetImageGenerator.generateCGImageAsynchronously`
but then immediately blocks on a `DispatchSemaphore.wait()` until the completion handler fires —
so despite the "asynchronously" API name, the function is fully synchronous to its caller. It's
called from `DashboardState.refresh()`, which reads like a main-thread UI-state refresh path. If
so, opening the LivePaper dashboard (or scrolling a library grid needing several uncached
thumbnails) would visibly hang the UI thread for however long AVFoundation takes to seek+decode a
frame per video. **Not something to adapt** — flagged purely as a pitfall to avoid if Wallwright
ever writes similar thumbnail-generation code: keep the semaphore-wait pattern off the main thread,
or better, don't use it at all and thread the callback through properly.

---

## Quick-reference table

| # | Idea | Category | Applicability |
|---|---|---|---|
| 1 | Event-driven occlusion pause (`didChangeOcclusionStateNotification`) | Performance | Adapt |
| 2 | `AVQueuePlayer` + `AVPlayerLooper` gapless loop | Performance + UI/UX | Adapt (non-trivial) |
| 3 | Battery-mode `contentsScale = 1.0` + GPU-pipeline self-reconnect | Performance | Adapt (blocked on #2) |
| 4 | Own-window-above-idle-screensaver fallback path | UI/UX | Interesting — verify Wallwright's single-mechanism design first |
| 5 | Tiered playback self-healing (`.failed` status, rebuild escalation) | Performance/robustness | Adapt |
| 6 | Lock-time `IOPMAssertion`, battery-gated | Performance | Already have it |
| 7 | AerialsInjector cache-clearing + blocking restart verification | — | Cautionary — don't re-add cache-clearing (documented dead end); Wallwright otherwise ahead |
| 8 | Named-pipe CLI, `change <path>` command | UI/UX (minor) | Wallwright ahead (0600 vs 0644); could restore `change` command, low priority |
| 9 | Clock 30s/1s adaptive timer + coalescing tolerance | Performance | Already have it, exceeded |
| 10 | Battery polling instead of push notifications | — | Neither project does the optimal thing; not actionable |
| 11 | Window-level watchdog timer | UI/UX | Adopt as-is |
| 12 | Semaphore-blocked "async" thumbnail generation | — | Cautionary anti-pattern, don't adapt |
