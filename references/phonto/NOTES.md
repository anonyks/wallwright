# Phonto (museslabs/phonto) — Research Notes

Repo: `references/phonto/repo` (local clone, not re-cloned). Read via README + full read of every
`src/*.rs` file relevant to macOS/rendering/UX; skimmed the Wayland GL/GStreamer pipeline for
concept comparison only. Cross-checked several findings directly against Wallwright's own source
(`Wallwright/Services/AerialsInjector.swift`, `Wallwright/Services/BatteryMonitor.swift`,
`Wallwright/AppDelegate.swift`) to judge what's actually new versus already-covered ground.

## What it is

Phonto is a small (~2.4k LOC) **Rust** CLI, GPL-3.0-licensed, that plays a video as desktop
wallpaper. It is genuinely cross-platform: Wayland compositors (Linux, via `layer-shell` +
GStreamer + EGL/GL) **and** macOS (via `AVPlayerLayer` in a borderless `NSWindow`). It also has a
macOS-only subcommand, `install-live-lockscreen`, that registers a video into Apple's Aerials
catalog so it plays on the lock screen/screensaver too — the same problem space as Wallwright's
`AerialsInjector.swift`.

**Tech-stack gap.** Phonto's macOS backend (`src/backend/macos/`) is Rust calling AppKit/AVFoundation/
VideoToolbox/IOKit through the `objc2` binding family (`objc2-app-kit`, `objc2-av-foundation`,
`objc2-video-toolbox`, `objc2-io-kit`) — i.e. it is driving **the same Apple frameworks Wallwright
uses in Swift**, just through a different FFI layer, with `unsafe` blocks standing in for what Swift
gets for free. This matters a lot for translatability: on the macOS side, most findings below are not
"Rust ideas that need reinterpreting" — they are **direct API-level usage patterns of AVFoundation /
VideoToolbox / IOKit / CoreGraphics that transfer almost verbatim to Swift**, because the underlying
calls (`VTCompressionSession`, `IOPSNotificationCreateRunLoopSource`, `AVPlayerLayer`,
`CGWindowLevelForKey`) are identical; only the calling convention differs. The Wayland/GStreamer/EGL
side (`src/backend/wayland/`) is a different story — no macOS equivalent of GStreamer/VA-API/EGL
exists, so those findings are concept-transfer-only (the *idea* of a technique, not portable code).

---

## Findings

### 1. HEVC Main10 + 2 temporal sub-layers for lock-screen playback — likely fixes a bug Wallwright is currently working around
**File:** `src/macos_live_lockscreen/transcode.rs` (412 lines), `install.rs` comment block (lines 1–16)
**Category:** Performance/correctness, both. **Applicability: worth a Swift equivalent — high priority.**

Phonto never hands the raw source video to the Aerials system. It transcodes through
`VTCompressionSession` directly (bypassing `AVAssetWriter`'s `outputSettings`, which doesn't expose
temporal-layer keys) to **HEVC Main10** with `kVTProfileLevel_HEVC_Main10_AutoLevel`, and explicitly
sets a custom `"NumberOfTemporalLayers"` VT property to 2 plus
`kVTCompressionPropertyKey_BaseLayerFrameRate`. The comment is blunt about why:

> "Two temporal sub-layers in the VPS (`vps_max_sub_layers_minus1 = 1`). **The lock-screen player
> needs this shape to re-arm across lock cycles.**"

Compare Wallwright's `AerialsInjector.swift`: it does a plain `fm.copyItem(at: videoURL, to: destPath)`
of the *original* video into the aerials `videos/` directory — no transcode, no temporal-layer shaping.
And Wallwright's own comments describe exactly the symptom phonto's transcode step exists to prevent:

> "The aerials extension only seems to reliably play a locally-injected (non-Apple-CDN) asset on the
> first activation after a restart; **a second activation with no restart in between can come up
> blank** even though nothing on disk changed."

Wallwright currently papers over this with a 5-minute health-check `Timer`, a
`prewarmForNextActivation()` restart-on-unlock hack, and "always restart WallpaperAgent even when the
video is unchanged." All three exist to compensate for a symptom that phonto's engineering notes
attribute to bitstream shape, not caching. `VTCompressionSession` and the `NumberOfTemporalLayers` /
`BaseLayerFrameRate` properties are directly callable from Swift via `VideoToolbox` — this is not a
"concept," it's a near-literal port. If confirmed by testing, this could let Wallwright drop the
timer/restart workarounds (or at least reduce how often they're needed) and fix the actual root cause.

### 2. Wallpaper window level: phonto sits *below* `kCGDesktopWindowLevel`, not at it
**File:** `src/backend/macos/mod.rs` lines 33–34, 309
**Category:** UI/UX (visual correctness). **Applicability: cautionary — needs live verification before adopting, do not blind-copy.**

```rust
// One below kCGDesktopWindowLevel so a static system wallpaper sits on top of us.
const WALLPAPER_LEVEL: isize = -2_147_483_624;
```

Wallwright's `AppDelegate.swift` sets its wallpaper windows to exactly
`CGWindowLevelForKey(.desktopWindow)` (line 241) — i.e. *at* the desktop level, which is the
conventional approach (below icons, at the same plane as the system wallpaper). Phonto deliberately
goes one level *lower*, meaning macOS's own static desktop-picture layer would render **on top of**
phonto's video if the user had one set. This only produces a visible video wallpaper if the system
desktop picture is effectively absent/transparent at that point, which the README/code don't spell
out an enforcement mechanism for. This is either a clever detail (e.g. avoiding some icon/Stage
Manager z-order conflict Wallwright hasn't hit) or a compatibility quirk of a macOS version/config
the phonto authors tested against. Flagging as "interesting, not obviously correct" — worth a
deliberate, isolated experiment (temporarily nudge Wallwright's window level down by one and check
whether a manually-set desktop picture occludes it) before considering any change, since Wallwright's
current level demonstrably works today.

### 3. Event-driven battery/power-source observation vs. polling
**Files:** `src/backend/macos/battery_observer.rs` (uses `IOPSNotificationCreateRunLoopSource`) vs. Wallwright's `Wallwright/Services/BatteryMonitor.swift` (30s `Timer` poll)
**Category:** Performance. **Applicability: worth a Swift equivalent — small, low-risk win.**

Phonto registers an IOKit run-loop source (`IOPSNotificationCreateRunLoopSource`) that fires a
callback exactly when the power source changes, then reads `IOPSCopyPowerSourcesInfo` /
`IOPSGetProvidingPowerSourceType` / `IOPSGetPowerSourceDescription` only at that moment. Wallwright's
`BatteryMonitor` polls every 30 seconds via `Timer.scheduledTimer` and diffs state, with an explicit
comment justifying the interval as "good enough" since nothing time-sensitive depends on it. Both are
legitimate designs, but `IOPSNotificationCreateRunLoopSource` is directly usable from Swift/IOKit and
would convert Wallwright's battery-aware throttling from "cheap periodic poll" to "zero idle cost,
instant reaction," which is a strict improvement with no real downside (Wallwright's own code already
argues instant reaction isn't *needed*, but "free and instant" beats "cheap and delayed" when the API
is a straight swap). Low priority precisely because Wallwright already reasoned about and accepted the
current tradeoff — but worth a look since it removes a timer entirely.

### 4. GPU-resident decode→render pipeline on Wayland (concept only, no macOS port)
**Files:** `src/backend/wayland/decoder.rs`, `src/backend/wayland/gl_renderer.rs`
**Category:** Performance. **Applicability: concept-transfer only — largely already achieved on macOS by AVPlayerLayer.**

The Wayland backend decodes via GStreamer + VA-API and uploads frames as GL textures with **zero CPU
round-trip** (`video/x-raw(memory:GLMemory)` caps, `glupload`/`glcolorconvert` elements, appsink pulls
a `GLVideoFrame` and reads a live `texture_id`). Two details worth naming even though the code isn't
portable:
- `appsink.max_buffers(1)` with `sync(true)` — the renderer always gets the newest decoded frame and
  older ones are dropped rather than queued, preventing backlog/drift under load.
- `GLSyncMeta::wait(gl_context)` before touching the texture — correct GPU-side fence wait instead of
  a CPU stall or (worse) a race.

On macOS, `AVPlayerLayer` + VideoToolbox + CoreAnimation already gives Wallwright the equivalent
"decode and composite entirely on GPU, no CPU pixel touching" property for free — this is confirmed by
phonto's own README describing its macOS backend the same way ("VideoToolbox handles decoding and
CoreAnimation handles compositing"). So this finding mostly serves as **validation that Wallwright's
existing AVPlayerLayer approach is already the architecturally-correct choice**, not a source of new
technique to adopt. Not applicable as an action item.

### 5. User-suppliable single-pass fragment shader for wallpaper post-processing
**Files:** README "GLSL shaders (Wayland only)" section, `gl_renderer.rs` (`fragment_src` param, `FRAGMENT_SHADER` constant)
**Category:** UI/UX. **Applicability: worth a Swift equivalent — nice-to-have, not urgent.**

`--shader PATH` lets a user drop in a GLSL ES 3.00 fragment shader (with documented `u_tex`, `v_uv`,
`u_resolution` uniforms) that's applied to every video frame before it's presented — README ships a
working Sobel edge-detection example. It's explicitly single-pass (no multi-pass bloom/blur support,
stated as a known limitation), keeping the feature simple to reason about. This is Wayland/GLSL-only
in phonto (not implemented for its own macOS backend), but the *feature idea* — a small, user-facing
customization point for post-processing the wallpaper without needing engine-level plugin
architecture — maps cleanly onto Swift via `CIFilter`/`CIColorKernel` chained onto the
`AVPlayerLayer`'s `filters` property, or a `CAFilter`/Core Image compositing pass. Given Wallwright's
GPL-3.0/video-only/no-scene-support philosophy of staying minimal, this is worth keeping in the
"maybe someday" bucket rather than prioritizing — it's a real feature but adds real surface area
(shader validation/sandboxing, a settings UI for picking/writing shaders).

### 6. Multi-display hot-plug reattachment — already covered ground
**Files:** `src/backend/macos/screen_observer.rs` (`ScreenObserver`, `AttachPolicy::{Mirror,PerDisplay}`) vs. Wallwright's `AppDelegate.swift` (`screensChanged()`, line 267)
**Category:** UI/UX + performance. **Applicability: not a new idea — Wallwright already does this.**

Phonto's `ScreenObserver` listens for `NSApplicationDidChangeScreenParametersNotification`, reapplies
window geometry for displays that persist, tears down surfaces for displays that vanish, and attaches
new surfaces for newly-connected displays according to an attach policy (mirror-all vs. per-display
pinned). Wallwright's `AppDelegate.swift` already observes the same notification and reconciles
`NSScreen.screens` (`screensChanged()`, `WallpaperViewModel.screenId(for:)`). No action needed — this
confirms Wallwright's existing approach matches the pattern a second independent implementation
converged on, which is a reasonable signal it's the right design, but there's nothing new to adopt
here.

### 7. Cross-platform display aliasing and "wait for reconnect, don't error" config semantics
**Files:** `src/config.rs` (`Alias`), `src/plan.rs` (`resolve_id`), README "Cross-platform aliases"
**Category:** UI/UX. **Applicability: concept-transfer only — the cross-OS half doesn't apply to a macOS-only app.**

`[[alias]]` blocks map a portable name (`"main"`) to per-OS native display IDs (`macos = "DELL
U2723QE"`, `wayland = "DP-1"`), so one dotfile config works unmodified across machines/OSes. Since
Wallwright is macOS-only, the cross-OS half is moot. The one detail worth keeping: a `[[display]]`
entry for a display that isn't currently connected is *not* an error — phonto just waits and attaches
when it appears. This matches (rather than improves on) Wallwright's existing hot-plug handling.
Nothing actionable beyond what's already true of the codebase.

### 8. `phonto displays` — explicit ID discovery command
**File:** README "Listing displays" section
**Category:** UI/UX. **Applicability: concept-transfer only.**

A dedicated CLI command prints each display's native ID so users can copy-paste the exact string into
config rather than guessing/typo-risking a name. Wallwright is a GUI app, so the direct equivalent
would be a Settings/Displays panel that shows each connected display's identifier verbatim (useful if
Wallwright ever exposes per-display pinned-wallpaper configuration in its UI, since users currently
have no way to see what internal ID a display maps to). Minor, low-priority polish idea, not urgent
since nothing in Wallwright's current UI needs it yet.

### 9. Remote/YouTube video as a wallpaper source
**File:** README "Streaming & YouTube (yt-dlp)" section, `src/plan.rs::resolve_with_ytdlp`
**Category:** UI/UX. **Applicability: not applicable — conflicts with Wallwright's stated scope.**

Phonto resolves YouTube URLs via a shelled-out `yt-dlp -g` call and feeds the resulting direct stream
URL into the normal playback path; it also accepts raw HLS/RTSP URLs. Wallwright's import is
deliberately video-file-only (scene/web support was removed per the architecture notes), and adding a
live external dependency (`yt-dlp`) plus network-stream wallpaper support is real scope creep against
that stated minimalism. Noting for completeness but actively recommending against pursuing it.

---

## Surprising / elegant / cautionary

- **Elegant:** the `AttachPolicy` enum (`Mirror(Retained<AVPlayer>)` vs.
  `PerDisplay(HashMap<String, Retained<AVPlayer>>)` in `screen_observer.rs`) cleanly unifies "one
  video mirrored everywhere" and "one video per display" under the same hot-plug reattachment code
  path — new displays get resolved against whichever policy is active without duplicating the
  attach/detach logic. If Wallwright's `PlaylistViewModel` ever needs a "different playlist per
  display" mode, this is a clean pattern to borrow structurally (not code, just the shape).
- **Elegant, and directly relevant to Wallwright's manifest-writing code:** `install.rs`'s
  `repair_phonto_category` function, which is defensive in a very specific way — after removing an
  asset, it re-points the category's `representativeAssetID`/`previewImage` at any *surviving* asset,
  or deletes the category entirely if none remain, because a category left pointing at a deleted
  UUID "poisons the catalog decode" and makes **the entire Aerials section, including Apple's own
  Landscapes, silently disappear from System Settings.** Wallwright's `AerialsInjector.swift` only
  ever has one custom entry (so this specific failure mode may not currently be reachable), but the
  general lesson — the aerials manifest parser fails closed and destructively on any category with a
  dangling `representativeAssetID`/empty `previewImage`/empty `subcategories` — is exactly the kind of
  undocumented, version-fragile behavior Wallwright's own `AerialsInjector.swift` comments already
  warn about ("It can break on any macOS update"). Good corroborating evidence, worth keeping the
  defensive checks Wallwright already has and not relaxing them.
- **Cautionary:** phonto's `build_surface` sets `NSWindowSharingType::ReadOnly` "so screen-capture /
  screen-sharing can read us" — i.e. it deliberately makes the wallpaper visible to screen recording
  tools rather than the more private `.none`. Worth double-checking this matches Wallwright's own
  choice (screen-recorded video wallpapers could be a meaningful privacy/UX expectation either way,
  and it's an easy one-line difference to get wrong silently).
- **Cautionary (see Finding 2):** the window-level choice is unverified and shouldn't be copied on
  faith just because it's "one line different."

## If I only had time for 3 things

1. **Port the HEVC Main10 / 2-temporal-sub-layer transcode step into `AerialsInjector.swift`**
   (Finding 1). This is the highest-value item — it's a near-literal `VideoToolbox` API port, and it
   plausibly fixes the exact "blank on second lock cycle" bug Wallwright is currently working around
   with timers and forced restarts, rather than just making it less noticeable.
2. **Swap `BatteryMonitor.swift`'s 30-second polling `Timer` for `IOPSNotificationCreateRunLoopSource`**
   (Finding 3). Small, low-risk, directly portable, strictly better (event-driven, zero idle cost).
3. **Live-test the window-level difference** (Finding 2) in isolation — confirm whether sitting one
   level below `kCGDesktopWindowLevel` is actually meaningful/safe before treating it as anything more
   than a curiosity. Don't adopt it without understanding why it works for phonto first.
