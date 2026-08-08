# WaifuX (jipika/WaifuX) — deep research notes

Repo: `references/waifux/repo` (cloned from `github.com/jipika/WaifuX`)
Version studied: **38.0.139** (see `VERSION`), GPL-3.0, macOS 14.4+ deployment target, built with Xcode 26.
Language: Swift 6, SwiftUI + AppKit. **Most in-repo comments and docs are in Simplified Chinese**; some newer files are commented in English.

> This is the deepest doc in the research batch because WaifuX is the closest thing to a "what if Wallwright were a
> full commercial-scale product" reference. Read section 1, then jump to whatever you need. Sections 3 and 4 are the
> two priority areas (rendering/performance, design/UI). Section 5 is a tagged catalogue of everything else.

---

## 1. If I only had time for N things

Ordered by (value to Wallwright) ÷ (effort). Numbers 1–5 are the real shortlist.

| # | Thing | Where | Why it matters | Effort |
|---|-------|-------|----------------|--------|
| **1** | **Freeze-frame layer under the `AVPlayerLayer`** | `Services/VideoWallpaperManager.swift:6020-6140` (`WallpaperVideoContainerView`) | A `CALayer` sitting *below* the `AVPlayerLayer` holding a snapshot of the last good frame, shown whenever `AVPlayerLayer.isReadyForDisplay == false`. Kills the black flash on loop boundaries and on player swap. ~60 lines. Highest value-per-line thing in the repo. | XS |
| **2** | **One shared `AVQueuePlayer` when N displays show the same file** | `VideoWallpaperManager.swift:112-130, 4552-4640` | Wallwright makes one `AVPlayer` per display. If two displays show the same video that is literally 2× the decode work for identical output. WaifuX shares the decode pipeline across displays (`findReusablePlayerComponents`) and *caps it at 2 screens* (`maxOpportunisticShareScreenCount = 2`) because one player driving 3+ high-refresh displays causes VSync-alignment judder. The cap is as valuable as the sharing. | M |
| **3** | **`AVPlayerLooper` instead of hand-rolled loop-on-`didPlayToEndTime`** | `VideoWallpaperManager.swift:4900-4920`, `Components/LoopingVideoBackgroundView.swift:176-179` | `AVQueuePlayer` + `actionAtItemEnd = .none` + `AVPlayerLooper(player:templateItem:)`. Genuinely seamless; no seek-to-zero hitch. Pair with #1, because the looper's item swap is exactly when `isReadyForDisplay` drops. | S |
| **4** | **AX-observer-driven auto-pause instead of a polling timer** | `Services/DynamicWallpaperAutoPauseManager.swift` (1919 lines) | Wallwright's pause policies are the right *set*; WaifuX's *detection* is much better: an `AXObserver` on the frontmost app for window-geometry events, coalesced (leading+trailing, 0.2 s gate / 0.5 s settle), plus a window-coverage-percentage threshold with 3% hysteresis, plus N-stable-samples debouncing, plus a 1 s grace window after display sleep/unlock (during which `CGWindowListCopyWindowInfo` lies and returns an empty list). Also "only play on the display the mouse is on". | L (cherry-pickable) |
| **5** | **`ScreenConfigurationSignature` — ignore spurious `didChangeScreenParameters`** | `VideoWallpaperManager.swift:40-61`, same struct in `WallpaperEngineXBridge.swift:159-195` | Quantized (origin, size, scale) per screen, compared before rebuilding any player/window. `didChangeScreenParametersNotification` fires on window activation/hide paths where nothing actually changed; rebuilding players there is a real source of flicker and CPU spikes. ~20 lines. | XS |
| 6 | Physical-display **fingerprints** separate from `NSScreenNumber` | `Utilities/NSScreen+Wallpaper.swift` | `NSScreenNumber` changes across sleep/wake and reconnect. Every per-screen dict in WaifuX is keyed twice: by screenID *and* by a CG vendor/model/serial fingerprint (with desktop position appended when there's no hardware serial, so two identical monitors don't collide). Also `orderedScreens` (main-first, left-to-right, top-to-bottom) so "Display 2" means the same thing in settings, menus, and helper processes. | S |
| 7 | **Cross-fade wallpaper switching via a pre-warmed hidden player** | `VideoWallpaperManager.swift:131-155, 4123+`, `WallpaperCrossTypeTransitionCoordinator:5665+` | New player is built into a hidden layer, KVO waits for first frame on *every* target screen (1.2 s timeout), then all screens cross-fade together in 0.28 s. For cross-type switches they screenshot the desktop into a temporary window to cover the teardown gap. Overkill in full; the "prewarm then swap" core is worth stealing. | M |
| 8 | **Automatic loop-point detection** | `Services/VideoLoopAnalysisService.swift`, `Metal/VideoLoopAnalysisMetalComparator.swift` | Finds the best seamless loop point in an arbitrary video (low-res luminance signature scan → 20-frame refinement → crop `[start, end)` so the duplicate tail frame is excluded) and rewrites the file in place. Genuinely novel for a wallpaper app; most downloaded wallpaper videos have a visible cut. The Metal comparator is a nice-to-have; the CPU algorithm is the value. | L |

**Explicit non-recommendation up front:** do **not** adopt a GPU/Metal/wgpu rendering path for video wallpapers.
See §3.7 — WaifuX itself does not do that, and their most interesting design decision points the *other* way.

---

## 2. What this project is, and how it compares to Wallwright

### 2.1 Product

WaifuX is an "all-in-one ACG app for macOS": an aggregator/browser for anime wallpapers (Wallhaven, 4KWallpapers,
Konachan, Pixiv, MotionBGs, Wallsflow), *plus* a wallpaper engine (static / video / Wallpaper Engine scenes / web),
*plus* an anime video streaming client with multi-source scraping and danmaku, *plus* a manga reader, *plus* WebDAV
cloud sync. Wallpapers are maybe half of it.

It is a commercially-shaped free product: signed with a real Developer Team ID, Sparkle auto-update with a hosted
appcast, a Homebrew cask auto-updated by CI, a Vite/Tailwind landing page deployed to GitHub Pages, a Cloudflare
Worker (`worker/`), three localizations, and donation QR codes in the README.

### 2.2 Scale

| | Wallwright | WaifuX |
|---|---|---|
| Swift LOC | modest | **168,056** across 300+ files |
| Largest file | — | `Services/VideoWallpaperManager.swift` — **6,760 lines** |
| Next largest | — | `wallpaperengine-cli.swift` 5,753 · `Views/MediaDetailSheet.swift` 5,541 · `Services/LocalizationService.swift` 4,486 · `Services/WallpaperEngineXBridge.swift` 4,353 |
| Services | a handful | **~100 files** in `Services/` |
| ViewModels | 1–2 | 10, incl. `MediaExploreViewModel.swift` (120 KB) and `WallpaperViewModel.swift` (94 KB) |
| Helper processes | none | 3 (`wallpaper-wgpu`, `wallpaperengine-cli`, `WaifuXWallpaperExtension`) + bundled ffmpeg, steamcmd, dxc |
| Project file | `.xcodeproj` in repo | **XcodeGen `project.yml`**, `.xcodeproj` generated |
| Repo size | small | 557 MB (292 MB of it is `Resources/`: bundled ffmpeg + steamcmd + dxc + a 40 MB prebuilt Rust binary) |
| Wallpaper types | video only (deliberate) | static image, video, WE `scene` (wgpu), WE `web` (WKWebView) |
| Playlist model | one playlist, deliberate | per-display scheduler configs, folder filtering, sequential/random, timed / on-playback-end / on-unlock |

### 2.3 Honest framing

The scope difference is enormous and most of WaifuX's surface area is irrelevant to Wallwright (anime scrapers,
danmaku, manga, Pixiv OAuth, cloud sync). Two things make it worth deep study anyway:

1. **The video-wallpaper code is battle-scarred in exactly the ways Wallwright will be.**
   `VideoWallpaperManager.swift` is 6,760 lines of comments-as-bug-postmortems — "the desktop layer doesn't
   recompose until you click another app", "AVPlayerLooper copies the template item on the *next* runloop", "the
   menu bar samples the system wallpaper, not your window". Every one of those is a real macOS trap Wallwright will
   hit or has hit.
2. **They solved "how do I get a live wallpaper onto the lock screen" a completely different way** than Wallwright's
   `AerialsInjector`, using an actual (private) macOS 26 extension point. See §3.6.

Also worth knowing what they *didn't* do better: i18n is a hand-rolled 4,486-line Swift dictionary
(`LocalizationService.swift`) — Wallwright's `Localizable.xcstrings` is strictly better. Their modals are plain
SwiftUI `.sheet()` (17 sites) — Wallwright's click-outside-to-dismiss popup is better macOS UX. And several files
are far past the point of maintainability.

---

## 3. The rendering pipeline (priority #2: performance)

**This is the headline finding, and it is the opposite of what the directory listing suggests.**

### 3.1 There are three pipelines, and video does not use the GPU one

| Content type | Renderer | Process | Notes |
|---|---|---|---|
| **Video (mp4/mov)** | `AVQueuePlayer` + `AVPlayerLooper` → `AVPlayerLayer` in a borderless `NSWindow` at `CGWindowLevelForKey(.desktopWindow)` | in-app | **Identical architecture to Wallwright.** No Metal, no wgpu, no custom compositor. |
| **Static image** | `NSWorkspace.setDesktopImageURL` + optional grain overlay window | in-app | `StaticImageWallpaperOverlayManager.swift`, `StaticWallpaperGrainManager.swift` |
| **Wallpaper Engine `scene`** | `wallpaper-wgpu` — a **prebuilt Rust/wgpu binary**, one process *per display* | out-of-process | `Services/WallpaperEngineXBridge.swift` |
| **Wallpaper Engine `web`** | `wallpaperengine-cli` — a WKWebView daemon compiled from one 5,753-line Swift file | out-of-process | legacy path, being phased out |

So: **the answer to "is plain-AVPlayer-per-window leaving performance on the table?" is essentially no.** The most
ambitious macOS wallpaper app in this batch uses the same AVFoundation path Wallwright does for video. What it adds
is a large amount of *tuning* around that path (§3.2). It uses GPU rendering only for content AVFoundation
fundamentally cannot play (Wallpaper Engine scenes) — and even then it prefers to **bake those to video** (§3.4).

### 3.2 The video path, in detail — where the real lessons are

Everything below is in `Services/VideoWallpaperManager.swift` unless noted.

**Window and layer setup** (`createWindow`, line ~4969):

```
window.level              = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
window.isOpaque = true; window.backgroundColor = .black; window.hasShadow = false
window.ignoresMouseEvents = true; window.isMovable = false
window.animationBehavior  = .none      // stop the system animating it on activation-policy changes
window.isReleasedWhenClosed = false    // lifecycle managed manually
```

The content view (`WallpaperVideoContainerView`, line ~6000) is a three-layer stack:

1. container `CALayer` with `masksToBounds = true` — the crop viewport
2. `freezeFrameLayer` (`contentsGravity = .resizeAspectFill`, opaque black) — the anti-flash layer
3. `avPlayerLayer` (`videoGravity = .resizeAspectFill`, transparent background)

Pan/zoom cropping moves/resizes the `AVPlayerLayer` inside the masked container rather than using a
`videoComposition` — they explicitly `item.videoComposition = nil` (line 1909) to avoid pulling in the compositor.

**The freeze-frame trick (finding #1).** KVO on `avPlayerLayer.isReadyForDisplay`. When it goes false (looper item
swap, decode gap), reveal the freeze layer holding the last captured frame; when it goes true, capture a new frame
(throttled to one per 0.35 s) and hide the freeze layer *one runloop later* — because the layer reports ready
slightly before it actually commits a non-empty buffer. Frame capture prefers reusing `layer.contents` directly and
falls back to rendering.

**AVPlayerItem tuning** (`makePlayerComponents`, line ~4836):

- `preferredMaximumResolution =` screen physical pixels; when a decoder is shared across displays it takes the
  **max** across all target screens so the external monitor isn't downscaled to the laptop's limit (line 4728).
- `preferredPeakBitRate` is deliberately set **only** for non-file URLs, with an explicit comment that it is an ABR
  hint and a no-op for local single-rate MP4/MOV. *Note for Wallwright: your battery throttling sets
  `preferredPeakBitRate` on local files — per this comment that likely does nothing. `preferredMaximumResolution`
  is the knob that actually bites.*
- `preferredForwardBufferDuration` tiered by storage: internal 5 s, internal >1 GB 2 s, **external volume 12 s**,
  external >1 GB **20 s** (detected via `URLResourceValues.volumeIsInternal`, defaulting to "internal" when
  unreadable). Slow USB disks stall otherwise.
- `automaticallyWaitsToMinimizeStalling = false` for local files (waiting causes a one-frame black flash at the loop
  boundary), `true` for external volumes and network.
- `preventsDisplaySleepDuringVideoPlayback = false` — important; a wallpaper must not block display sleep.
- `appliesPerFrameHDRDisplayMetadata` toggled for HDR sources; `seekingWaitsForVideoCompositionRendering = false`;
  `audioTimePitchAlgorithm = .timeDomain`.

**Muting.** They do **not** use a second player. Muting disables the audio *tracks* on the `AVPlayerItem`
(`track.isEnabled = false` for `.audio` tracks, line 4962) so no audio output chain is established at all — plus an
async re-apply after `asset.loadTracks(withMediaType: .audio)` completes, since tracks may not be loaded yet at
creation time. There is also a hack (line 424+) caching the built-in speaker's device UID and force-routing audio
there when muted, to stop macOS auto-connecting AirPods just because the app holds an audio session.
*Relevance to Wallwright's two-player audio workaround:* different approach to a different problem, but
"disable the track, don't just set volume 0" is worth knowing — a muted player with an enabled audio track keeps a
live audio route, which is plausibly connected to the lock/unlock audio-drop bug.

**Multi-display orchestration:**

- `videoTargetScreenIDs` / `videoTargetScreenFingerprints` — on wake/resolution-change, `rebuildWindows()` rebuilds
  only screens that are *supposed* to have video, instead of all screens.
- Multi-display switches are **serialized**: `activeDisplaySwitchScreenID` + a `pendingDisplaySwitches` queue, 1 s
  stable delay, 8 s timeout — so three displays auto-rotating don't spin up three `AVPlayer`s and three poster
  writes simultaneously.
- Shared-decoder followers don't attach until the lead screen has actually started playing
  (`pendingSharedFollowerScreenIDsByPlayerID`).
- Player ownership is anchored by *file path per player object* (`anchoredVideoPathByPlayerID`), not by the global
  `currentVideoURL`, because the global URL updates before the new player exists — a subtle correctness bug they
  clearly hit.

**WindowServer / desktop-layer compositing quirks** (`revealDesktopWallpaperWindow`, `forceCommitDesktopPresentation`,
lines 317–422). A whole subsystem devoted to one bug: *the desktop layer does not recomposite while the app is
inactive or a menu is tracking, so "I switched the wallpaper" doesn't visibly happen until you click something.*
Their fix stack: `CATransaction` with actions disabled → `orderFrontRegardless()` then `orderBack(nil)` →
`displayIfNeeded()` → `CATransaction.commit()` + `CATransaction.flush()` → `CFRunLoopWakeUp(CFRunLoopGetMain())`,
then repeat on the next runloop and again after 50 ms. Ugly, empirical, probably necessary. If Wallwright ever sees
"wallpaper changed but the screen didn't update until I clicked", this is the recipe.

Related: `Services/DesktopWallpaperSyncManager.swift` handles the fact that the **menu bar samples the system
desktop image, not your window**, so after presenting a video they re-write a poster through `setDesktopImageURL`
using an *alternating filename slot* (the system treats re-setting the same URL as a no-op) and even briefly
map/unmap a throwaway `NSWindow` to force the menu bar to re-sample. It also handles `setDesktopImageURL` with
`allSpaces: true` still not reliably updating other Spaces, by re-applying on `activeSpaceDidChangeNotification`.

### 3.3 `wallpaper-wgpu` — what it actually is

**It is a 40 MB prebuilt `Mach-O 64-bit executable arm64` checked into the repo root and `Resources/`. There is no
Rust source anywhere in this repository.** `strings` confirms a Rust binary linking wgpu + naga (WGSL/SPIR-V front
ends) and objc2, built in CI by another project; `scripts/build-wallpaper-wgpu.sh` reveals the author's local path
`/Volumes/mac/CodeLibrary/Claude/wallpaper-wgpu/target/release/wallpaper-wgpu`. So it is a sibling project by the
same author, vendored as a binary. (Shipping a binary-only component inside a GPL-3.0 repo is at best awkward.)

Its job is to render **Wallpaper Engine `scene` wallpapers** — a proprietary format with its own shaders (HLSL,
hence the bundled `dxc` + `libdxcompiler.dylib` for cross-compilation), particle systems, and models. Nothing
AVFoundation could ever play. It is **not** used for video wallpapers.

**The IPC design is the genuinely reusable part** (`Services/WallpaperEngineXBridge.swift`, 4,353 lines):

- **One process per display.** Launched with `--wallpaper --background --assets <path> --screen x,y,w,h,scale`,
  plus `--upscaling <30..100>` (render at a fraction of native resolution and upscale — their performance mode) and
  `--effect-reduction`.
- **Control by polled JSON files, not sockets.** Four temp-file paths are passed as launch args: `--crop-control`
  (renderer polls ~200 ms for pan/zoom hot-updates), `--wallpaper-control` (hot-swap the wallpaper or update user
  properties *without restarting the process*), `--canvas-size-file` (renderer writes back the scene's ortho canvas
  size once ready so the app can compute crop), and an audio control file. Crude, but trivially debuggable, survives
  process restarts, and needs no socket lifecycle handling.
- **Pause/resume via `kill(pid, SIGSTOP)` / `SIGCONT`**, per display (line ~1250). Zero renderer cooperation
  required, instantaneous, provably zero CPU while stopped.
- **Orphan reaping.** They scan the process table for `wallpaper-wgpu` processes carrying their control-file naming
  convention (`waifux-wallpaper-wgpu-wallpaper-<screen>-`) and kill leftovers from a previous crashed run, because
  an orphan renderer keeps holding the desktop layer. They also kill `afplay` children the renderer spawned.
- Stderr is teed to a per-screen log file so a renderer crash can be post-mortemed (lines ~2550, ~2940).
- Hot-switch ordering matters: they must clear the old crop-control and invalidate the old canvas-size file *before*
  telling the renderer to load a new wallpaper, or the "wait for new canvas size" task reads the stale file and
  computes the wrong crop.

**Tradeoffs, honestly:** you get content you otherwise could not display at all, plus crash isolation (a renderer
segfault doesn't kill the app). You pay: a 40 MB opaque binary, a second toolchain you can't debug, an entire
process-supervision layer (~4,000 lines including launch, hot-swap, reaping, crash detection, and focus-stealing
mitigation — `wallpaper-wgpu` steals focus on launch so they restore the previously-focused app, line ~1053), and
codesigning/entitlements/`install_name_tool` gymnastics in the build script.

### 3.4 The bake pipeline — the most important architectural idea in the repo

`Services/SceneOfflineBakeService.swift` (2,042), `Services/BakeService.swift` (1,862),
`Services/SceneBakeEligibilityService.swift`, `Services/WebOfflineBakeService.swift`.

**They render the expensive GPU scene once, offline, capture it, and encode it to an H.264 MP4 — then play that MP4
with plain AVPlayer at runtime.**

- `BakeService` launches `wallpaper-wgpu` in a wrapper bundle, waits for the scene to *visually stabilize* (polls
  frames until average luma and bright-pixel ratio are stable across 6 samples; min 8 s warmup, max 24 s wait),
  captures via ScreenCaptureKit/CGWindow, and encodes H.264 at ≤30 fps.
- `SceneBakeEligibilityService` decides *whether a scene can be baked at all*, keyed on flags parsed from the scene:
  `cursor_ripple`, `iris`, `audio_reactive`, `waterripple`, `shake`, `wall_clock_time`. Anything genuinely
  interactive or wall-clock-dependent can't be pre-rendered; everything else can.
- Baked artifacts are cached as `{analysisId}[_title]_{W}x{H}_{fps}fps_{duration}s.mp4`.

**Why this matters for Wallwright:** it is direct, hard-won validation of the video-only decision. The team that
built a full GPU scene renderer concluded that the best way to *run* those scenes on a desktop all day is to turn
them into video and hand them to the hardware decoder. Hardware H.264/HEVC decode is a fixed-function block costing
a fraction of the power of continuous GPU shader work. A wallpaper runs for hours; nothing else matters as much.

Secondary idea worth stealing regardless: **"wait until the visual output stabilizes" as a readiness signal** —
sampling frames and comparing luma statistics rather than trusting a `ready` flag.

### 3.5 What `Metal/` actually contains

Only four files, ~1,000 lines total, and **none of them are in the wallpaper rendering hot path**:

| File | What it does | Verdict |
|---|---|---|
| `FrameInterpolationMetalInterpolator.swift` | One compute kernel (`opticalFlowWarpKernel`) warping frames N and N+1 along a Vision-computed optical-flow field and blending. Used **offline** to rewrite a 24/30 fps video as 60/90/120 fps and replace the file on disk. `commandBuffer.waitUntilCompleted()` — clearly not realtime. | interesting, not applicable |
| `VideoLoopAnalysisMetalComparator.swift` | Compute kernel doing atomic per-pixel luma diffs across candidate frame pairs, accelerating loop-point search. Also offline. | interesting, not applicable |
| `LiquidGlassMetalRenderer.swift` + `LiquidGlassClockShaders.metal` | `MTKView`-based glass background for their **clock overlay**, at `preferredFramesPerSecond = 1` with a `shouldRedraw()` minute check. | see §5, clock |

Shader source is mostly **embedded as Swift string literals** and compiled with `device.makeLibrary(source:)` at
runtime, so shaders needn't be Xcode build inputs. Convenient for a small number of small kernels.

### 3.6 The lock screen: `WallpaperExtensionKit` vs Wallwright's `AerialsInjector`

The other genuinely novel thing in the repo, and the direct counterpart to Wallwright's hackiest file.

`WaifuXWallpaperExtension/` is a real **ExtensionKit app extension** declaring
`EXExtensionPointIdentifier = com.apple.wallpaper` (`WaifuXWallpaperExtension/Info.plist`) — Apple's *private*
wallpaper extension point, available on **macOS 26+**. Instead of forging files into
`~/Library/Application Support/com.apple.wallpaper/`, they register as a wallpaper *provider* that `WallpaperAgent`
loads and drives.

How it's built:

- `WallpaperExtension-Bridging-Header.h` hand-declares the two XPC protocols — `WallpaperExtensionXPCProtocol`
  (host→extension: `acquire / update / invalidate / snapshot / provideSettingsViewModels / choices / downloads /
  migration / shuffle / debug / notifications`) and `WallpaperExtensionProxyXPCProtocol` (extension→host: `ping`,
  `updateSettingsViewModels`, `requestReadOnlyAccessTo`, `invalidateSnapshots`) — plus private `CAContext`
  (`+remoteContext`, `contextId`) and `CGSMainConnectionID()`.
- The private XPC value classes (`WallpaperCreationRequestXPC`, `WallpaperSnapshotXPC`, `WallpaperChoiceIDsXPC`, …)
  are resolved at runtime via `objc_getClass` and added to the `NSXPCInterface` allowlist per selector/argument
  index — see the 15-name type list at `WaifuXWallpaperExtension.swift:16-33` and the ~30-entry selector table
  below it. Missing classes on a given OS build are logged, not fatal.
- `WallpaperXPCHandler.swift` (1,267 lines) implements the protocol. Rendering is handed back as a private
  `CAContext` remote layer that `WallpaperAgent` composites.

**Frame delivery is the clever part.** The extension does not decode video itself:

- `WaifuXWallpaperExtension/IOSurfaceFrameRenderer.swift` allocates **two global BGRA `IOSurface`s per display**
  (double-buffered; `IOSurfaceIsGlobal = true`, `bytesPerRow` 16-byte aligned) and exposes their `IOSurfaceID`s.
- The **main app** decodes (`Services/LockScreenFramePusher.swift`) and writes frames into the idle surface, then
  signals the extension over a **Unix domain socket** (`Services/WallpaperExtensionSocketServer.swift` ↔
  `WaifuXWallpaperExtension/UnixSocketClient.swift`, `FrameChannel.swift`).
- The extension wraps the surface's `CVPixelBuffer` in a `CMSampleBuffer` and feeds
  `AVSampleBufferDisplayLayer.sampleBufferRenderer` via `requestMediaDataWhenReady`, driven by a `CMTimebase` built
  on `CMClockGetHostTimeClock()`.
- Extension-side support: `PlaybackPolicy.swift`, `PowerMonitor.swift`, `WallpaperPrefs.swift` (settings shared via
  the `group.com.waifux.app` app group), `SnapshotCreation.swift` (settings-pane thumbnail), `BMPCache.swift`,
  `ExtensionCropSupport.swift`.
- Liveness is triple-checked: an extension-written state JSON, `hasActivePipeline` on the socket server, and a user
  preference — see `isLockScreenMirroringActive` (`VideoWallpaperManager.swift:209-228`), which exists specifically
  because the state file is sometimes written late.
- Deployment detail from their Homebrew cask postflight: after install they run `lsregister -f <app>`,
  `pluginkit -e use -i com.waifux.app.wallpaperextension`, then `killall WallpaperAgent`.

**Verdict for Wallwright: fascinating, and probably still not worth it.**

- Requires **macOS 26+**. `AerialsInjector` would still be needed as a fallback, so this is *additive* complexity,
  not a replacement.
- Entirely private API that Apple can change in a point release; the runtime class-name allowlist and the
  "the notification sometimes doesn't arrive" workarounds show they are already fighting that.
- Cost is roughly: a second target, a hand-written ObjC bridging header of reverse-engineered protocols, an IOSurface
  double-buffer, a Unix socket protocol, an app group, and a frame pusher — call it 3,000+ lines.
- **But**: if `AerialsInjector`'s flaky-blank-on-second-activation ever becomes unfixable, this is the escape hatch,
  and this repo is a complete worked example. Bookmark
  `WaifuXWallpaperExtension/WallpaperExtension-Bridging-Header.h` and `WaifuXWallpaperExtension.swift` — those two
  files hold the hard part (knowing the protocol shape) in ~500 lines combined.

Note that WaifuX's bridge still restarts `WallpaperAgent` in some paths, same as Wallwright.

### 3.7 Rendering verdict table

| Idea | Tag | Applicability to Wallwright |
|---|---|---|
| Shared `AVQueuePlayer` across same-file displays, capped at 2 | perf | **Adapt** — highest-value perf change available |
| `AVPlayerLooper` for seamless loops | both | **Adopt as-is** |
| Freeze-frame layer under `AVPlayerLayer` | both | **Adopt as-is** |
| Disable audio tracks rather than volume-0 for mute | perf | **Adapt** — may also bear on the lock/unlock audio bug |
| Storage-tiered `preferredForwardBufferDuration` | perf | **Adopt as-is** (trivial; real benefit for NAS/USB libraries) |
| `preferredMaximumResolution` = max across shared screens | perf | **Adopt** if you add sharing |
| `automaticallyWaitsToMinimizeStalling = false` for local files | perf | **Adopt** — directly reduces loop-boundary flash |
| `preferredPeakBitRate` is a no-op on local files | perf | **Already have it (incorrectly)** — worth verifying your battery throttle actually does anything |
| `ScreenConfigurationSignature` gate on `didChangeScreenParameters` | perf | **Adopt as-is** |
| Serialize multi-display switches | perf | **Adapt** — only if you see contention with 3+ displays |
| Pre-warm + cross-fade switching | UI/UX | **Adapt** — a simplified version |
| `forceCommitDesktopPresentation` WindowServer poking | UI/UX | **Keep in your back pocket** — only if you see the symptom |
| Menu-bar re-sample via alternating poster slot | UI/UX | **Adapt** if menu-bar tint mismatch bothers you |
| Out-of-process GPU renderer (`wallpaper-wgpu`) | perf | **Not applicable** — Wallwright removed scene support on purpose |
| Bake-scene-to-MP4 | perf | **Already have it, philosophically** — validates video-only |
| Metal for realtime wallpaper compositing | perf | **Not worth it** — nobody, including WaifuX, does this |
| WallpaperExtensionKit lock screen | UI/UX | **Interesting but not applicable now** — reference implementation for later |
| SIGSTOP/SIGCONT to pause a helper process | perf | **Interesting** — applies only if Wallwright gains a long-lived helper (yt-dlp/ffmpeg are short-lived) |

---

## 4. Design system and UI patterns (priority #1)

### 4.1 What `Design/` and `DesignSystem/` actually are

Set expectations: **`Design/` is not a design system.** It is app-icon artwork — SVG source, a Python icon generator
(`Tools/generate_app_icon.py`, 20 KB), size-check sheets, a `Logo/` folder, and two short "AppIcon philosophy"
markdown notes. Nothing portable except the idea of scripting icon generation.

`DesignSystem/` is three files, ~1,500 lines:

| File | Contents |
|---|---|
| `LiquidGlassDesignSystem.swift` (1,119) | Color tokens, `LiquidGlassLevel` scale, `GlassVariant`, the `.liquidGlassSurface()` / `.liquidGlassEffect()` modifiers, and components: `LiquidGlassCard`, `LiquidGlassButton`, `LiquidGlassPillButton`, `LiquidGlassFloatingButton`, `LiquidGlassNavigationBar`, `LiquidGlassAtmosphereBackground`, `OptimizedGlassContainer` |
| `LiquidGlassControls.swift` | `LiquidGlassToggle`, `LiquidGlassSwitch`, `PressableButtonStyle` |
| `SkeuomorphicStyles.swift` | An alternative visual theme |

Supporting code lives *outside* that folder: `Utilities/GlassStyle.swift` (1,064), `Utilities/LiquidGlassModifier.swift`,
`Utilities/ArcFrostedGlass.swift`, `Utilities/ArcBackgroundSettings.swift`, `Components/LiquidGlassComponents.swift`.
That split is itself a lesson — the "design system" leaked into `Utilities/` and `Components/` and there is no
longer a single place to look.

### 4.2 The token model — genuinely better than ad-hoc per-view styling

Three ideas worth taking, independent of the "liquid glass" aesthetic:

**(a) A named *level* scale that resolves to many correlated values at once.**
`LiquidGlassLevel` is `.subtle / .regular / .prominent / .max`, and each level defines `material`, `fillOpacity`,
`tintOpacity`, `highlightOpacity`, `borderOpacity`, `shadowOpacity`, `shadowRadius`, `shadowYOffset`, and
`nativeBackdropOpacity` (`LiquidGlassDesignSystem.swift:147-269`). Call sites say `.liquidGlassSurface(.prominent)`
and never touch a number. This is the difference between a design system and a constants file: one axis of intent
maps to eight correlated visual properties, so elevation stays consistent by construction.

**(b) Semantic colors as `@MainActor` computed properties over a `ThemeManager`, not `static let`s.**
`textPrimary`, `textSecondary`, `glassBorder`, `surfaceBackground`, … each resolve differently in dark vs light
(`:11-136`). Brand/accent colors (`primaryPink`, `secondaryViolet`, glow colors) stay static because they don't
theme. Clean separation.

**(c) A native/fallback fork behind one modifier.**
`AdaptiveLevelGlassModifier` picks `NativeGlassModifier` (real macOS 26 `Glass` / `glassEffect`) or
`FallbackGlassModifier` (hand-built material + gradient + border + shadow) per availability (`:690-760`), and
`OptimizedGlassContainer` wraps in `GlassEffectContainer` only on 26+. Call sites are version-agnostic. **This is the
pattern to copy if Wallwright ever wants Liquid Glass while still supporting Sonoma/Sequoia** — one `#available`
fork inside one modifier, not scattered through views.

**Applicability: Adapt.** Don't take the pink/violet ACG palette or the whole file. Take the shape: a `Tokens.swift`
with a small level enum, semantic color computed properties, and one adaptive surface modifier. Even a 150-line
version beats per-view `.background(.ultraThinMaterial).cornerRadius(12)` everywhere.

### 4.3 Motion tokens — `Utilities/AppFluidMotion.swift`, adopt as-is

The single most Wallwright-sized file in the repo. The whole thing:

```swift
enum AppFluidMotion {
    static let interactiveSpring = Animation.spring(response: 0.34, dampingFraction: 0.88)  // filters, chips, segments
    static let navigationSpring  = Animation.spring(response: 0.36, dampingFraction: 0.86)  // tabs, toggles
    static let hoverEase         = Animation.easeOut(duration: 0.18)                        // hover scale, small controls
    static let cardHoverEase     = Animation.easeOut(duration: 0.16)                        // list card hover
    static let contentCrossfade  = Animation.easeInOut(duration: 0.22)                      // tab/sheet transitions
}
```

The doc comment is the point: *"slightly higher damping, slightly longer response — reduces the cheap 'bounces
twice' feel, closer to system controls."* A larger, older set lives in `Utilities/SmoothAnimations.swift`
(`cardHover`, `cardPress`, `heroTransition`, `listAppear`) plus a `CardHoverEffect` modifier (scale 1.03 hover /
0.97 press) and a `HeroAnimationState` for grid→detail hero transitions.

**Applicability: Adopt as-is.** Five constants, immediate consistency win, zero risk.

### 4.4 The big UI performance finding: they abandoned `LazyVGrid`

`Components/ExploreGrid/` — 7 files, ~2,500 lines. `ExploreGridContainer` is an `NSViewRepresentable` wrapping an
`NSScrollView` + `NSCollectionView` with a custom `ExploreGridCollectionViewLayout` (waterfall, aspect-ratio-driven
heights, column count by width: >1200→4, >800→3, else 2). The file comment is blunt:

> *"Bridges a generic NSCollectionView + cell reuse into SwiftUI, replacing LazyVGrid to achieve 60 fps scrolling."*

Details worth noting:

- Cells are `ExploreGridItem` subclasses per content type (`WallpaperGridCell`, `MediaGridCell`, `AnimeGridCell`).
- Scroll position restore is token-driven, so rebuilding the collection view doesn't jump the user's place.
- Overlay scrollbars are suppressed with a custom `NSScroller` subclass that draws nothing and fails hit-testing,
  plus a `tile()` override because the system re-attaches scrollers.
- Two-phase scroll: while a collapsible header still has travel, wheel events collapse the header and the grid stays
  pinned at y=0; only then does the grid scroll. Reversed on scroll-up at the top.
- Recent release notes (`Docs/appcast.xml`, 38.0.139) show them *still* fixing `reloadItems` index-out-of-bounds and
  AppKit internal assertion crashes in this component. It is not free.

`Components/WaterfallChunkLayout.swift` documents an even nastier trap:

> *"On macOS 26, a SwiftUI `Layout` protocol implementation triggers a degenerate path in SwiftUICore
> (`LayoutEngineBox.explicitAlignment` / `UnaryLayoutEngine.sizeThatFits` infinite loop inside the system library),
> showing up as intermittent 5+ second main-thread hangs at 100% CPU."*

Their workaround: precompute every card's absolute `(x, y, w, h)` in a pure Swift function and place them in a
`ZStack` with `.position()`, sizing the chunk with `.frame(height:)` so an outer `LazyVStack` stays lazy — never
invoking `Layout` measure/place at all. Chunks of 30 cards; laziness comes from the image loader instead.

**Applicability:**

- The `NSCollectionView` bridge: **Adapt, but only if you have a symptom.** Wallwright's library is a local folder
  of videos — tens to low hundreds of items, not an infinite network feed. `LazyVGrid` is probably fine at that size
  and is dramatically less code. Revisit only if scrolling actually stutters.
- The `Layout`-protocol hazard: **worth knowing.** If Wallwright ever writes a custom `Layout` conformance and sees
  mysterious main-thread hangs on macOS 26, this is the cause and `ZStack` + `.position()` is the fix.

### 4.5 Card entrance animation done right — `Components/PerformanceModifiers.swift`

`FadeInOnAppearModifier` solves a bug Wallwright's library grid will hit if it ever adds entrance animation:
`LazyVGrid` recycles offscreen cells and resets `@State`, so scrolling back up replays the fade-in and you see a
wall of blank cards. Fix: a process-global LRU `Set<String>` (max 1000) of item IDs that have already animated;
first appearance animates with a staggered spring, later appearances render immediately with `nil` animation.
Stagger index is clamped to 12 so page-2 items don't animate a minute late.

Also in the same file:

- `ThrottledHoverModifier` — throttles `onHover` state updates (default 50 ms) with a trailing update, so fast
  scrolling doesn't fire hundreds of state changes.
- `ParallaxScrollModifier` — quantizes the parallax offset to 5 px steps *specifically to reduce animation
  invalidation frequency*. A neat example of "make the effect cheaper by making it coarser."

**Applicability: Adopt the LRU-appear idea and the hover throttle** if Wallwright's grid has hover effects. ~40
lines each.

### 4.6 Settings UI primitives — `Views/SettingsSharedComponents.swift`

A tiny DSL: `MacSettingsForm` (scroll + 24 pt section spacing + consistent padding), `MacSettingsSection(header:)`
(rounded card, `white.opacity(0.05)` fill, `0.08` hairline stroke), and row primitives. `Views/SettingsView.swift`
is still 2,701 lines even with this, and per-source tabs are split into `Views/Settings/*Tab.swift`.

**Applicability: Adapt.** The section/row primitive pair is worth having; the 2,700-line settings view is the
cautionary half of the lesson.

### 4.7 Other UI components worth a look

| Component | File | Note |
|---|---|---|
| Shimmer skeleton loading | `Components/LoadingAnimations.swift` (1,015) | Standard `.shimmer()` gradient-sweep modifier plus a large set of loading states |
| "Next wallpaper" toast | `Components/LiquidGlassNextItemToast.swift` | Preview card for the upcoming item, driven by a `NextItemPreviewable` protocol so wallpapers and media share one view. **Directly relevant to Wallwright's playlist** — a "coming up next" peek is a cheap, nice UX addition |
| Audio visualizer | `Components/LiquidGlassAudioVisualizer.swift` | Spectrum bars fed by `SystemAudioCaptureService` |
| Clock overlay | `Components/LiquidGlassClockView.swift` + `Services/LiquidGlassClockOverlayManager.swift` | See §5 |
| Crop / pan-zoom overlay | `Services/CropAdjustOverlayController.swift` | Fullscreen per-display overlay: drag to pan, scroll to zoom, ESC to exit, with its own preview render independent of the live wallpaper layer. Good pattern for a direct-manipulation adjustment mode |
| Hero-driven palette | `Models/HeroPalette.swift` | Derives the page's accent/backdrop palette from the wallpaper's dominant colors, with per-category fallbacks. Cute; **overkill for Wallwright** |
| Explore atmosphere | `Utilities/ExploreAtmosphere.swift` (1,180) | Ambient background gradients + animated-GIF probing with a bounded-concurrency actor and a `nonisolated` `NSCache` sync read so SwiftUI `body` can hit the cache synchronously and avoid a re-render. That last trick is a good general SwiftUI pattern |

### 4.8 Where Wallwright is already better

Be honest about these:

- **Modals.** WaifuX uses plain `.sheet()` in 17 places. Wallwright's scrim + card + spring + click-outside-to-dismiss
  is better macOS UX; WaifuX has nothing to teach here.
- **Localization.** `Services/LocalizationService.swift` is a 4,486-line hand-rolled dictionary with a `t("key")`
  function. Wallwright's `Localizable.xcstrings` is the correct modern answer.
- **File size discipline.** 6,760-line and 5,541-line files. Wallwright's per-concern files are healthier.
- **Focus.** Wallwright's "one playlist, video only, delete everything else" decisions look visibly *right* once you
  see what the alternative grows into.

---

## 5. Catalogue — everything else findable

Each item tagged **[UI/UX]**, **[perf]**, or **[both]**, with an applicability rating:
*adopt as-is* / *adapt* / *interesting, not applicable* / *already have it* / *not worth it for a personal project*.

### Playback & scheduling

**`Services/WallpaperSchedulerService.swift` (2,312) + `Models/SchedulerConfig.swift`** — **[perf]** — *adapt (partially)*
Per-display scheduler configs; modes are timed / "switch on playback end" / "switch on unlock" (encoded as sentinel
`intervalMinutes` values). Worth stealing:

- **A one-shot `DispatchSourceTimer` fired at the earliest due deadline and recomputed after each fire**, with
  `leeway = .milliseconds(200)` and a `minimumTimerDelay` of 0.25 s — instead of a 1 Hz repeating timer. Much
  friendlier to power.
- **`NSProcessInfo.beginActivity` held while a rotation is armed**, so App Nap doesn't stall the timer.
- Failure handling: a failed apply retries in 15 s instead of waiting a full interval; a missing external-volume
  library backs off to 60 s instead of stat-ing every path each tick.
- Generation counters (`timedRotationGeneration`, `globalRotationGeneration`) invalidate in-flight async batches when
  the user changes settings mid-flight — a pattern Wallwright's playlist should use too.
- Post-apply cooldown (1.5 s) plus a per-screen in-flight set to stop the on-end notification double-firing, and a
  separate `globalOnEndSwitchCooldownUntil` because a shared decoder produces one logical end event that every
  attached display observes. *(Relevant if you adopt shortlist #2.)*

Explicitly **not** recommended: their multi-mode, multi-config-per-display model. Wallwright's single-playlist
decision is sound.

**`Services/DynamicWallpaperAutoPauseManager.swift` (1,919)** — **[perf]** — *adapt* — see shortlist #4.
Policies: pause when another app is foreground (Finder excluded, evaluated per screen), pause displays the mouse
isn't on, pause when a fullscreen window covers the screen, pause when window coverage ≥ a user threshold, pause on
battery. Implementation notes worth stealing even without the whole thing:

- `CGWindowListCopyWindowInfo` runs on a `.utility` queue, never the main thread.
- Coverage decisions require `requiredStableFullscreenSamples = 2` consecutive agreeing samples.
- 3% hysteresis gap on the coverage threshold so a window hovering at the boundary doesn't oscillate.
- A 1 s grace window after display sleep / wake / unlock during which coverage results are distrusted, plus
  scheduled re-checks after it expires (AX observers need rebinding after a display transition).
- Debounced app-activation handling so rapid Cmd-Tab doesn't thrash, and a `suppressForegroundPauseUntil` window so
  "user collapsed the main window to the menu bar" isn't misread as "user switched to another app".
- Remembers which screens were *already manually paused* before an automatic pause, so resuming doesn't un-pause
  them. **Wallwright's battery-vs-lock-vs-manual pause distinction is the same class of problem** — this is a more
  general solution to it, and it is the closest analogue to the countdown-during-battery-pause logic you just added.

**`Services/PowerSourceMonitor.swift`, `SleepPreventer.swift`, `SystemMemoryPressure.swift`** — **[perf]** — *adapt*.
Small and focused; memory-pressure handling drops Kingfisher caches.

### Video processing

**`Services/VideoOptimizationQueueService.swift` (2,883) + `VideoOptimizationQueueCheckpointStore.swift` +
`VideoOptimizationRecordStore.swift`** — **[perf]** — *adapt (the queue design)*
A persistent, checkpointed background job queue for expensive per-video work (loop analysis, frame interpolation,
transcode), with in-place file replacement (`FileManager.replaceItemAt` against a hidden sibling temp file, plus a
`videoOptimizationFileDidReplace` notification so a live player can react to its own source file being swapped).
**This is exactly the pattern Wallwright just moved toward** when it lifted in-flight download state off view-local
`@State` onto persistently-owned `ObservableObject`s — WaifuX goes one step further with an on-disk checkpoint store
so work survives a quit. Worth reading `VideoOptimizationQueueCheckpointStore.swift` before extending Wallwright's
import/transcode state.

**`Services/VideoLoopAnalysisService.swift` (1,050)** — **[both]** — *adapt (worth the effort)* — see shortlist #8.
Note the API shape: the service "deliberately has no knowledge of queues, wallpaper application, library state, or
UI. Callers own scheduling and record the returned outcome." Outcome is a 3-case enum
(`applied(firstContentFrame:lastIncludedFrame:)` / `notNeeded` / `noReliablePoint`). Good boundary design.

**Frame interpolation** (`VideoWallpaperManager.swift:10-31` + `Metal/FrameInterpolationMetalInterpolator.swift` +
the queue service) — **[perf]** — *not worth it for a personal project*. Offline Vision optical flow → Metal warp →
re-encode → replace the source file, targeting a fixed 30/60/90/120. Hours of complexity for an effect most people
won't notice on a wallpaper.

**Letterbox auto-crop** (`videoLetterboxContentCrops`, `VideoLetterboxCrop` at `VideoWallpaperManager.swift:5648`) —
**[UI/UX]** — *adapt*. Detects baked-in black bars in the source, computes `zoomMultiplier = 1/(1 - blackRatio)`, and
applies it only in fill-the-screen mode. Results cached, including a negative cache. Small, self-contained, and a
real quality win on Steam Workshop / YouTube sourced videos, which are full of letterboxed content. Gated behind an
`auto_remove_video_letterbox` default (off).

**`Services/VideoTranscodeService.swift`, `VideoToolboxProcessor.swift`, `SuperResolutionService.swift`** —
**[perf]** — *interesting, not applicable*. VideoToolbox transcode; SR via MetalPerformanceShaders bicubic/Lanczos +
sharpen. Wallwright's ffmpeg-based compatibility transcode is simpler and adequate.

**`Services/VideoThumbnailCache.swift`, `LocalImageThumbnailCache.swift`, `Utilities/VideoPreloader.swift`** —
**[perf]** — *adapt*. `VideoPreloader` is an `actor` caching resolved `AVAsset`s (max 4) and, for CDNs that lie about
`Accept-Ranges` (returning 200 for a Range request, causing AVFoundation error `-11850`), downloads the whole file
to a cache dir and hands AVPlayer a file URL instead. Useful if Wallwright ever previews remote videos.

### Multi-display

**`Utilities/NSScreen+Wallpaper.swift`** — **[both]** — *adopt as-is* — see shortlist #6. Also `maxRefreshRate` via
`CGDisplayCopyDisplayMode` with a 60 Hz fallback for ProMotion (which can report 0).

**`Services/ExternalDisplayConnectionCoordinator.swift`** — **[UI/UX]** — *adapt*. Detects genuinely *new* external
displays (persisted `known_fingerprints` set, migrated from a legacy key) and prompts once about applying a
wallpaper, debounced against the storm of `didChangeScreenParameters` notifications a hotplug produces. The
fingerprint deliberately excludes resolution/scale/position, because macOS mode negotiation and desktop rearrangement
would otherwise make the same monitor look "new".

**`Services/GlobalWallpaperSyncCoordinator.swift`** — **[perf]** — *adapt*. Serializes "apply to all displays" as one
transaction with a single durable rollback snapshot. The header comment states the ownership rule well: *"the
coordinator owns transaction ordering; renderer/player services retain ownership of their own process and playback
state."*

**`Services/DesktopWallpaperSyncManager.swift`** — **[UI/UX]** — *adapt* — see §3.2 (Spaces + menu-bar sampling).

### Overlays

**Clock overlay** — `Services/LiquidGlassClockOverlayManager.swift` (1,240), `Components/LiquidGlassClockView.swift`,
`Models/LiquidGlassClockConfiguration.swift`, `Metal/LiquidGlassMetalRenderer.swift` — **[both]** — *compare, adopt
selectively*. Direct counterpart to Wallwright's `ClockOverlay.swift`. Differences:

- One transparent `NSWindow` **per screen** at `desktopWindow + 2` (their grain overlay is at `+1`), hosting an
  `MTKView`.
- **`MTKView.preferredFramesPerSecond = 1`** plus a `shouldRedraw()` minute-change check that skips submission
  entirely — a clock does not need 60 fps. **If Wallwright's clock redraws on a timer, this is the pattern.**
- Rendering suspends when the video wallpaper is paused and freezes entirely when the clock is hidden. It subscribes
  to `VideoWallpaperManager.$isPaused`, `$currentVideoURL`, *and* `$wallpaperChangeCount` — the last as a
  belt-and-braces signal for "same URL re-applied", which `$currentVideoURL` wouldn't publish. **Wallwright could use
  the same change-counter trick** for any observer that must react to re-applies.
- Re-orders windows to front 0.5 s after `activeSpaceDidChangeNotification`; rebuilds on display hotplug; has a
  Dock-safe-area observer so the clock avoids the Dock.

Wallwright's manual `mouseDown`/`mouseDragged` dragging and its Rainmeter "Summit" layout have no counterpart here —
WaifuX's clock is positioned by configuration, not direct manipulation. **Wallwright's is better on interaction;
WaifuX's is better on render economy.** Take the 1 fps + skip-if-unchanged idea, keep your dragging.

**`Services/StaticWallpaperGrainManager.swift`, `NotchOverlayManager.swift`** — **[UI/UX]** — *interesting*.
Independent overlay windows for film grain and for the notch area, layered above the wallpaper so wallpaper switches
don't disturb them. The "each cosmetic effect gets its own overlay window at its own level" decomposition is clean
and worth copying if Wallwright grows more overlays.

### Audio

**`Services/SystemAudioCaptureService.swift`** — **[perf]** — *interesting, not applicable*. Captures the system
audio mixdown via **CoreAudio Process Tap** (`CATapDescription` + `AudioHardwareCreateProcessTap`, macOS 14.4+) into
an aggregate device, then vDSP FFT for spectrum. Notably: **no virtual loopback driver and no Screen Recording
permission**, unlike the older ScreenCaptureKit route. Worth knowing this API exists.
Related: `NowPlayingService.swift`, `AppleMusicLyricsService.swift`, `WallpaperWebAudioRelay.swift`.

### App-level architecture

**`App/WaifuXApp.swift` (1,513)** — **[both]**

- **`AppExitDiagnostics`** — *adopt as-is*, ~90 lines. Installs `atexit` plus handlers for
  SIGTERM/INT/QUIT/ABRT/ILL/BUS/SEGV, writing to a raw `open()`/`write()`/`fsync()` fd in Application Support. Uses
  `StaticString` inside the signal handler so nothing allocates. For a wallpaper app that lives in the menu bar for
  weeks, "why did it disappear overnight" is *the* support question, and this answers it.
- **`EdgeToEdgeHostingView`** — *interesting*. Overrides `safeAreaRect` / `safeAreaInsets` / `safeAreaLayoutGuide` to
  zero, **but only on macOS < 15**, with a comment that forcing them on Sequoia+ makes the SwiftUI layout engine
  oscillate. Useful if Wallwright ever fights title-bar safe area.

**`Utilities/AppResponsivenessMonitor.swift`** — **[perf]** — *adapt (a trimmed version)*. A utility-queue
`DispatchSourceTimer` pings the main thread every 1 s and logs a stall if the ack takes >2.5 s, tagged with current
tab / detail depth / window visibility / scene phase. A 40-line version is a cheap early-warning system for
main-thread hangs.

**State management** — **[both]** — *cautionary*. The pattern is `@MainActor final class X: ObservableObject` with
`static let shared`, everywhere — `VideoWallpaperManager`, `WallpaperEngineXBridge`, `WallpaperSchedulerService`,
`DynamicWallpaperAutoPauseManager`, `LiquidGlassClockOverlayManager`, `StatusBarController`, … dozens of them, wired
together with Combine subscriptions on each other's `@Published` properties. It works, and Swift 6 concurrency is
taken seriously (`@unchecked Sendable` with explicit locks, `OSAllocatedUnfairLock`, `nonisolated(unsafe)` with
justifying comments). But the singleton graph is a big part of why the files are so large. **Wallwright's
`PlaylistViewModel` / `GlobalHotkeyManager` split is the same pattern at a healthy size — the lesson is where it
stops scaling, not that it's wrong.**

**`Services/StatusBarController.swift` (1,086)** — **[UI/UX]** — *compare*. Custom `NSView`-based `NSMenuItem` rows,
including a live volume slider (`WallpaperVolumeSliderView`: `NSImageView` + continuous `NSSlider`, icon updating
with value). Wallwright already does custom menu rows with hotkey-hint labels and already knows the `NSMenu.copy()`
/ `NSCoding` crash. **Wallwright is not behind here** — but a menu-bar volume slider is an easy, nice addition.

### Build, release, and dev tooling — `Tools/`, `scripts/`, `.github/`

**[both]** — *adopt selectively*. The most transferable non-code part of the repo.

- **XcodeGen.** `project.yml` (12 KB) is the source of truth; the `.xcodeproj` is generated and *not* in git. Kills
  `project.pbxproj` merge conflicts forever. Shared schemes are declared in the yml so a fresh clone can Cmd+R.
  **Wallwright's `.xcodeproj` is in git — this is a real quality-of-life upgrade if you ever work across machines.**
- **`VERSION` file + `scripts/sync-version.sh`** — one file is the version; CI seds it into `project.yml`. No more
  "bumped Info.plist but not the project".
- **`.github/workflows/ci.yml`** — builds every push to main on `macos-26` / Xcode 26.6, SPM cache keyed on
  `project.yml`, `paths-ignore` for markdown.
- **`release.yml`** — tag `v*` → xcodegen → build → `create-dmg` → GitHub Release.
- **`update-homebrew-tap.yml`** — on release published, downloads the DMG, computes SHA-256, rewrites the cask in a
  separate tap repo, pushes. (The cask body is base64-embedded in the YAML to dodge quoting hell — hacky but
  effective. The cask's `postflight` runs `lsregister -f`, `pluginkit -e use -i <ext id>`, `killall WallpaperAgent`.)
- **`pages.yml`** — deploys `landing/` + `Docs/` (which holds `appcast.xml`) to GitHub Pages.
- **Sparkle** for in-app updates, appcast at `Docs/appcast.xml`, changelog auto-generated from commits by
  `scripts/generate-appcast-changelog.py` (release notes are literally structured commit messages — and are the best
  available changelog for this repo).
- **`scripts/install-githooks.sh` + `scripts/githooks/`** — repo-local hooks.
- `scripts/bundle-dylibs.py`, `organize-dylibs.py`, `fix-dylib-paths.sh` — `otool -L` / `install_name_tool` rewriting
  of Homebrew absolute paths to `@loader_path/lib`, then re-codesign. **Directly relevant if Wallwright ever bundles
  ffmpeg/yt-dlp instead of requiring them on PATH.** `scripts/build-wallpaper-wgpu.sh` shows the whole dance,
  including the `Resources/Resources/` nesting gotcha that Xcode folder-references create.
- **Embedding a zip via `.incbin`** (also `build-wallpaper-wgpu.sh`, consumed by `WallpaperEngineEmbeddedAssets.swift`):
  assets zipped → embedded via an assembly `.incbin` into a universal `.o` → linked via `OTHER_LDFLAGS` → unzipped at
  runtime. Clever, and *not* something Wallwright needs.
- `Tools/generate_app_icon.py` — programmatic app-icon generation from parameters.
- `Tools/WebWallpaperBakeDemo.swift` (1,912) — a standalone harness for the bake pipeline. Keeping a runnable demo
  for the gnarliest subsystem is good practice.
- `Tests/` is thin: two files (`ConcurrentDownloadBenchmark.swift`, `DetailDownloadActivityRegression.swift`) plus
  `WallHavenTests/`. **A 168k-line app with ~2 test files** — do not draw architectural confidence from this repo's
  test coverage.

### Content pipeline (mostly not applicable)

- **Remote rule engine** — `Services/RuleLoader.swift`, `RuleRepository.swift`, `AnimeRuleStore.swift`,
  `KazumiRuleLoader.swift`, `Rules/`, `ComicRules/template.js`, plus a separate `WaifuX-Profiles` GitHub repo.
  Scraping selectors live outside the app and sync at launch, so a site redesign is a rule update rather than a
  release. **[UI/UX]** — *interesting, not applicable* (Wallwright has no scrapers), **but** the general pattern —
  ship behavior that breaks when third parties change, as remotely-updatable config — is exactly the shape of
  Wallwright's `steamcmd` / `yt-dlp` integration if it ever needs per-site handling.
- `Services/WorkshopService.swift` (3,722) + `WorkshopSourceManager.swift` + `Resources/steamcmd/` + a Steam login
  WebView. Wallwright already has Workshop import; theirs is bigger, not obviously better.
- `Services/Sync/*` (10 files) — WebDAV cloud sync with a conflict resolver and separate file/metadata engines.
  **[both]** — *not worth it for a personal project*.
- `Services/ImportService.swift`, `DownloadTaskService.swift`, `DownloadPathManager.swift`,
  `DirectoryMigrationService.swift`. Worth a skim: `DownloadTaskService` validates media file *headers* (not
  extensions) to catch the case where a hotlink-protected CDN returns a big HTML error page saved as `.mp4` — a
  failure mode Wallwright's YouTube/Workshop import could plausibly hit. **[perf]** — *adapt*.

---

## 6. Impressive but overkill — explicit "don't do this" list

Trust-calibration section. All of these are genuinely well-built and genuinely wrong for Wallwright.

| Thing | Why not |
|---|---|
| Vendoring a Rust/wgpu renderer | Wallwright removed scene rendering on purpose. Re-adding it via a 40 MB binary blob you can't debug, plus ~4,000 lines of process supervision, would undo the single best scoping decision in the project. |
| Realtime Metal compositing for video | Nobody does it, including WaifuX. `AVPlayerLayer` already rides the hardware decoder and the WindowServer compositor. You'd be replacing free work with your own. |
| WallpaperExtensionKit lock screen | macOS 26 only, so it's additive to `AerialsInjector`, not a replacement. Entirely private API. ~3,000 lines. Revisit only if `AerialsInjector` becomes unfixable — and then use their bridging header as the map. |
| Frame interpolation | Enormous machinery (Vision optical flow + Metal + re-encode + file replacement) for an effect nobody will notice on a background image. |
| Super-resolution service | Same. |
| Hand-rolled localization service | Strictly worse than `.xcstrings`, which Wallwright already uses. |
| WebDAV cloud sync | 10 files, conflict resolution, two engines. For syncing a personal wallpaper library between your own Macs, iCloud Drive or a symlink is the answer. |
| Multi-source scraping + remote rule repo | No content sources to scrape. |
| Their scheduler's per-display config matrix | Wallwright's explicit single-playlist decision is better. Steal the *timer mechanics* (one-shot deadline timer, `beginActivity`, generation counters), not the config model. |
| `NSCollectionView` grid bridge | Only if you actually measure a scroll problem in a local library of tens/hundreds of items. It cost them ongoing AppKit assertion crashes. |
| Their file sizes | 6,760 lines in one file is the thing to actively avoid, not emulate. |

---

## 7. Quick file map for a return visit

```
README.md / README.en.md / README.ja.md     product scope, feature table, disclaimers
project.yml                                 XcodeGen source of truth (targets, SPM deps, post-build scripts)
VERSION                                     38.0.139

App/WaifuXApp.swift                         @main, AppExitDiagnostics, EdgeToEdgeHostingView

── VIDEO PIPELINE (the important part) ──
Services/VideoWallpaperManager.swift        6760 lines. Window/layer setup ~4969, player config ~4836,
                                            freeze-frame container ~6020, transitions ~4123, audio ~424/4947,
                                            WindowServer forcing ~317-422, lock-screen glue ~1951/2488
Services/DesktopWallpaperSyncManager.swift  Spaces sync + menu-bar re-sampling
Services/DynamicWallpaperAutoPauseManager.swift  AX-driven auto-pause (1919)
Services/WallpaperSchedulerService.swift    deadline-timer rotation (2312)
Utilities/NSScreen+Wallpaper.swift          screen identity, fingerprints, ordering, refresh rate
Services/GlobalWallpaperSyncCoordinator.swift / ExternalDisplayConnectionCoordinator.swift

── GPU / OUT-OF-PROCESS ──
wallpaper-wgpu                              40 MB prebuilt Rust binary, NO SOURCE IN REPO
Services/WallpaperEngineXBridge.swift       process supervision, JSON control files, SIGSTOP/SIGCONT (4353)
wallpaperengine-cli.swift                   WKWebView web-wallpaper daemon, single file, built by swiftc (5753)
Services/BakeService.swift
Services/SceneOfflineBakeService.swift
Services/SceneBakeEligibilityService.swift  scene → MP4 offline bake (the key idea)
Metal/                                      4 files, all offline or 1 fps; none in the wallpaper hot path

── LOCK SCREEN (macOS 26 private extension point) ──
WaifuXWallpaperExtension/WallpaperExtension-Bridging-Header.h   the reverse-engineered protocols
WaifuXWallpaperExtension/WaifuXWallpaperExtension.swift         XPC type allowlist + selector table
WaifuXWallpaperExtension/IOSurfaceFrameRenderer.swift           double-buffered IOSurface → AVSampleBufferDisplayLayer
WaifuXWallpaperExtension/WallpaperXPCHandler.swift              protocol implementation (1267)
Services/LockScreenFramePusher.swift                            app-side decode + surface write
Services/WallpaperExtensionSocketServer.swift                   unix socket frame signalling

── DESIGN / UI ──
DesignSystem/LiquidGlassDesignSystem.swift  tokens, level scale, adaptive native/fallback modifier (1119)
DesignSystem/LiquidGlassControls.swift      toggle/switch/pressable button style
Utilities/AppFluidMotion.swift              5 motion tokens — copy this file
Utilities/SmoothAnimations.swift            older/larger motion set + CardHoverEffect + HeroAnimationState
Components/PerformanceModifiers.swift       LRU fade-in-once, throttled hover, quantized parallax
Components/ExploreGrid/                     NSCollectionView bridge replacing LazyVGrid (7 files)
Components/WaterfallChunkLayout.swift       ZStack + .position to dodge the macOS 26 SwiftUI Layout hang
Views/SettingsSharedComponents.swift        MacSettingsForm / MacSettingsSection primitives
Design/                                     app icon artwork only — not a design system

── TOOLING ──
.github/workflows/{ci,release,pages,update-homebrew-tap}.yml
scripts/                                    version sync, dylib bundling, incbin embedding, git hooks
Docs/appcast.xml                            Sparkle feed (also the best available changelog)
```

---

## 8. One-paragraph summary if you read nothing else

WaifuX is a 168k-line, commercially-shaped macOS ACG app whose *video wallpaper* engine uses exactly the same
architecture as Wallwright — `AVQueuePlayer` + `AVPlayerLooper` + `AVPlayerLayer` in a borderless desktop-level
`NSWindow` — with no Metal and no wgpu anywhere in that path. The Rust/wgpu component is a vendored, source-less
40 MB binary used only for Wallpaper Engine *scene* wallpapers, and their own preferred way to run those is to
**pre-render them to MP4 and play them with AVPlayer**, which is strong independent validation of Wallwright's
video-only scoping. What they add on top of the shared architecture is years of tuning: a freeze-frame layer that
eliminates loop-boundary black flashes, a shared decoder across displays showing the same file (capped at two),
storage-tiered buffering, track-level muting, spurious-`didChangeScreenParameters` filtering, stable physical
display fingerprints, AX-observer-driven auto-pause with hysteresis and post-wake grace windows, and a pile of
WindowServer-poking incantations for "the desktop layer won't recomposite while the app is inactive". On the UI side
the transferable parts are a five-constant motion-token file, a level-based design-token scale behind one adaptive
native/fallback modifier, and an animate-once-per-item LRU for grid entrance animations; their
`NSCollectionView`-replaces-`LazyVGrid` bridge is impressive but solves a scale problem Wallwright doesn't have.
Their build tooling (XcodeGen + a `VERSION` file + Sparkle + auto-updated Homebrew cask) is worth copying wholesale.
Everything else — the GPU renderer, the private macOS 26 lock-screen extension, frame interpolation, cloud sync,
remote scraping rules — is impressive, well-engineered, and disproportionate for a personal project.
