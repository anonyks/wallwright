# Vidwall (jaywcjlove/vidwall) — Reference Notes

Source: `references/vidwall/repo` (cloned locally). **Important caveat up front:** this
repo is *not* the app's source code. Its own README says so explicitly:

> "Declaration: This project is not an open-source project. The repository serves as
> the official website, used to collect issues and user demands. This is done to save
> costs, because without an official website, the application cannot pass the review."
> (`README.md:2-3`, mirrored in `README.zh.md:2-3`)

There is no Swift/Obj-C/source tree in this clone — only `README.md`/`README.zh.md`,
`CHANGELOG.md`/`.zh.md`, `feedback.md`/`.zh.md`, `privacy-policy.md`/`.zh.md`,
`terms-of-service.md`/`.zh.md`, `.github/ISSUE_TEMPLATE/bug_report.yml`,
`.github/workflows/ci.yml` (a docs-site deploy pipeline using `idoc`, not an app build),
and two screenshots (`assets/screenshots-1.png`, `assets/screenshots-2.png`). Everything
below is inferred from those artifacts — changelog wording, issue-template copy, and the
two screenshots — not from reading implementation code. Treat conclusions about *how*
something is implemented as speculation; conclusions about *what exists in the UI and
what shipped in which version* are solid (the changelog is precise and dated per release).

## What it is / positioning

Vidwall is a paid, App-Store-distributed macOS app ("Vidwall AppStore" badge, in-app
"paid unlock verification" per `CHANGELOG.md` v1.12.0) that turns 4K MP4/MOV video files
into a live desktop wallpaper: drag a video in, click to apply. It also supports "Set as
Screensaver" (v1.6.0) using what is presumably the standard macOS ScreenSaver mechanism,
not the undocumented aerial-injection trick Wallwright uses. It ships with real
localization/i18n discipline (`README.zh.md`, `CHANGELOG.zh.md`, `privacy-policy.zh.md`,
`terms-of-service.zh.md`, a dedicated `bug_report_cn.yml` issue template, and changelog
entries like v1.14.0 "Add more international languages" / "Improve localization and menu
layout"), a real privacy policy and terms of service (both effective June 23, 2025,
explicitly stating the app is 100% offline/local with no telemetry), a "My Apps"
cross-promotion panel for the author's other apps, and a "Vidwall Hub" companion
site/product linked from the status-bar menu. Overall maturity level: small-team/solo-dev
(author jaywcjlove, contact `kennyiseeyou@gmail.com`, Twitter `@jaywcjlove`) but with
App-Store-grade release/legal/support hygiene layered on — the kind of polish that comes
from having shipped through App Review multiple times, not from a large team.

## Concrete findings

### 1. No multi-playlist system — a flat video library, not Wallwright's playlist model
Screenshot 1 (`assets/screenshots-1.png`) shows the main window: a left sidebar with five
items — **Wallpaper, Download, General, My Apps, About** — and a single flat list of
imported videos in the "Wallpaper" pane (filename, resolution, format, a small
sun/brightness-looking icon, and a "..." overflow menu per row). There is no
playlist-management UI, no folders/tags/categories, and no per-playlist config visible in
either screenshot. The closest thing to Wallwright's playlist concept is a **single
setting called "playlist loop"** mentioned in `CHANGELOG.md` v1.13.0: "gate playlist loop
and optimize settings wallpaper view" and "restore wallpaper playback and video list
looping." Reading between the lines of the changelog: this looks like a paywall-gated
toggle ("gate" + the confirmed IAP flow in v1.12.0's "Resolve paid unlock verification
issue") that lets the *entire* imported video list auto-advance/loop, rather than a
proper multi-playlist / smart-shuffle / tag-based system. There's no evidence anywhere in
the changelog of shuffle, sequential-vs-random mode, per-item scheduling, or grouping —
i.e., Vidwall's rotation feature set is strictly simpler than what `PlaylistViewModel.swift`
already does in Wallwright (shuffle/sequential, natural-loop-end or timed switching,
battery-aware behavior).

**Verdict on the maintainer's earlier call to reject multi-playlist complexity:**
this comparison supports it. A commercial, App-Store-reviewed competitor with presumably
more design iteration than a side project *still* only ships a single flat list + one
loop toggle, and even that required a dedicated version (v1.13.0) to "gate" and fix
regressions ("restore wallpaper playback and video list looping" implies it broke
between releases). Multi-playlist/tagging is not something users are visibly asking
Vidwall for either (no such request pattern surfaces in the changelog across 15
versions). This is weak evidence Wallwright's existing single-playlist design is not
under-featured relative to the market — if anything Wallwright is already ahead
(shuffle + battery-aware timing) of what a shipped competitor bothered to build. Not
worth adding multi-playlist complexity on this evidence alone.

### 2. Status-bar menu is more feature-complete than a typical menu-bar item
Screenshot 2 (`assets/screenshots-2.png`) shows the status-bar dropdown with, in order:
"Open Vidwall", a checkable "Dynamic Wallpaper Enabled" toggle, "Enable Sound" toggle,
"Refresh Video Wallpaper" (manual reload/recovery action), "Open Vidwall Hub", then
Website / Rate App / Send Feedback / My Other Apps (submenu) / Settings… (⌘,) / Quit
Vidwall (⌘Q). `CHANGELOG.md` v1.8.0 added this ("add quick menu to status bar," "add
video file command menu," "add Enable Auto Fade"). Two things worth lifting into
Wallwright:
- **A manual "Refresh Video Wallpaper" action in the status item.** This is a cheap,
  high-value affordance: when playback silently breaks (which Wallwright's own
  `AerialsInjector`/`WallpaperAgent`-restart workaround suggests is a real risk class
  after lock/unlock or display changes), giving the user a one-click "kick it" command
  from the menu bar avoids a full quit/relaunch. UI/UX applicability: high, cheap to add.
- **Enable Sound as a top-level menu toggle**, not buried in a settings pane. Given
  Wallwright already runs a second muted audio-only `AVPlayer` as an audio-continuity
  workaround, exposing a quick mute/unmute toggle at the menu-bar level (mirroring
  whatever the in-window control is) would match this pattern cheaply.

### 3. The changelog is dominated by perf firefighting on exactly Wallwright's risk areas
Across 15 versions, roughly a third of changelog lines are `perf:`-tagged, and they cluster
tightly around list rendering and playback smoothness — not exotic problems:
- v1.4.0: "improve bulk import performance"
- v1.5.0: "optimize icon rendering performance," "improve image rendering quality,"
  "optimize playback stutter on click"
- v1.7.0: "optimize dynamic screensaver settings"
- v1.9.0: "optimize list display performance," "optimize video fade-in and fade-out settings"
- v1.12.0: "Optimize sidebar disable-hide behavior"

Takeaway/cautionary note: even a paid, iterated-on, App-Store product needed *multiple
releases* to smooth out thumbnail/list rendering and click-to-play stutter for what
Wallwright would consider a small feature (an import list with video thumbnails). This is
a warning sign for Wallwright's Steam Workshop/YouTube import UI, which lists many more
items with thumbnails than Vidwall's simple drag-drop list — expect thumbnail generation
and list-scroll performance to need dedicated tuning passes, not just get-it-working-once.
"Optimize playback stutter on click" (v1.5.0) specifically corroborates that starting
video playback synchronously with a UI click is a known stutter source — relevant to
Wallwright's per-display `AVPlayer` setup and to the Import UI's "keep browsing while a
download continues" pattern, which already sidesteps a similar class of UI-blocking issue.

### 4. Other concrete UI/UX signals worth noting
- **Drag-and-drop reordering of the video list** shipped in v1.10.0 ("enable drag-and-drop
  reordering in file list"), then its *style* was revisited again in v1.5.0 ("improve
  drag-and-drop style") — i.e., even the interaction affordance needed a visual polish
  pass after functionality landed. Minor but consistent with #3's lesson: ship, then
  expect a follow-up polish pass for any drag interaction.
- **Multi-select delete** landed very late (v1.15.0, the newest changelog entry): "add
  wallpaper selection deletion controls." For 14 prior versions, users apparently could
  only remove list items one at a time via the per-row "..." menu. Worth pre-empting
  in Wallwright's own explorer/import lists if bulk-delete isn't already there.
- **Adaptive fill screen option** (v1.15.0) — a content-fit/aspect mode toggle (fill vs.
  fit vs. letterbox, presumably) arriving only at the latest version, i.e., 15 releases in
  before addressing non-matching-aspect-ratio video handling. Wallwright should check
  whether its own `VideoWallpaperView` already handles mismatched video/display aspect
  ratios explicitly, since this was evidently a late/afterthought fix for a competitor.
- **Settings window resizability** was a dedicated fix in v1.3.0 ("Make the settings
  window resizable") — a reminder that fixed-size settings windows are a recurring papercut
  users notice enough to file, worth a quick self-check in Wallwright's own settings UI.
- **Privacy/ToS discipline**: `privacy-policy.md` and `terms-of-service.md` are both dated,
  short, and make a clear, checkable claim ("does not collect, store, or transmit any
  personal information... does not connect to remote servers"). For a GPL-3.0 hobby
  project this is probably overkill to replicate formally, but the *clarity* — one
  paragraph, no legalese, directly answers "does this phone home" — is a good model if
  Wallwright ever adds a public download page, given it too shells out to network tools
  (steamcmd/yt-dlp) that a privacy-conscious user would want called out explicitly.

## Surprising / cautionary
- **Nothing to learn from playlist/rotation sophistication** — the surprise is the
  *absence* of it. A commercial competitor with presumably many more users and feedback
  cycles never built past "one loopable list," which is a data point (not proof) that
  Wallwright's maintainer was right to resist multi-playlist scope creep.
  Wallwright's playlist stack today is more capable than the closest comparable shipped
  competitor.
- **This repo teaches nothing about implementation approach for the two priorities
  (UI/UX, performance)** — it's a marketing/support repo, not code. Any conclusion about
  *how* Vidwall solved list-rendering perf, screensaver integration, or per-video
  brightness (the sun icon in screenshot 1's row actions — likely a per-item
  brightness/dim control, but unconfirmed since no code is visible) is inference from
  changelog wording only, not verified implementation detail. Don't cite this doc as if
  it contains source-level evidence — flag that in any follow-up decision.
- App Review pressure clearly drives some of this polish (localization, ToS/privacy
  docs, a "My Apps" cross-promo panel, paid-unlock verification flows) that a GPL side
  project distributed outside the App Store has no equivalent forcing function for — so
  some of Vidwall's "maturity" is App-Store-compliance overhead rather than pure UX
  craftsmanship, and shouldn't be over-weighted as a UX benchmark on that basis alone.

## If I only had time for 3 things
1. **Add a "Refresh Wallpaper" action to Wallwright's status-bar/menu-bar menu** —
   cheap, directly addresses the same playback-recovery need that motivates
   `AerialsInjector`'s `WallpaperAgent` restarts, and gives the user a fast, visible
   recovery path instead of relying on background self-healing alone.
2. **Audit Import UI (Steam Workshop/YouTube) list rendering and thumbnail loading for
   the same stutter/perf issues Vidwall spent 4+ releases fixing** (bulk import perf,
   icon rendering perf, list display perf, click-to-play stutter) — proactively test with
   a large imported library before it becomes a real bug, since Wallwright's import
   surface area (with transcoding) is more complex than Vidwall's plain drag-drop.
3. **Do not build multi-playlist/tagging based on this comparison** — the evidence here
   argues against it, not for it. If playlist complexity gets revisited later, this repo
   is not the justification to point to.
