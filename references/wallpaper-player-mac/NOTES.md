# `haren724/wallpaper-player-mac` — Research Notes

**Repo studied:** `references/wallpaper-player-mac/repo` (cloned locally, default branch, `main`)
**Position in lineage:** per Wallwright's README, the chain is
`haren724/wallpaper-player-mac` → `MrWindDog/wallpaper-engine-mac` → `Unayung/wallpaper-engine-mac` → **Wallwright**.
This is the *oldest* traceable ancestor — the root of the tree, not a peer competitor.

---

## 0. Headline finding: there is no app source code in this repo

This is the single most important fact to record, because it reframes everything else.

The entire checkout is 636 KB and 14 tracked files (excluding `.git`). Every one of them is
documentation scaffolding or build plumbing — **there is no Swift application code**: no
`AppKit`/`SwiftUI` views, no window management, no video/media playback, no display handling.
Full tracked-file inventory:

```
.github/workflows/docs.yml
.gitignore
Package.swift
README.md
Sources/User_Documentation_en_US/Documentation.docc/Resources/documentation-art/WallpaperPlayer-icon@2x.png
Sources/User_Documentation_en_US/Documentation.docc/articles/import-your-first-wallpaper.md
Sources/User_Documentation_en_US/Documentation.docc/articles/supported-wallpaper-types.md
Sources/User_Documentation_en_US/Documentation.docc/homepage.md
Sources/User_Documentation_en_US/UserDocumentation.swift
Sources/User_Documentation_zh_CN/Documentation.docc/Resources/documentation-art/WallpaperPlayer-icon@2x.png
Sources/User_Documentation_zh_CN/Documentation.docc/articles/import-your-first-wallpaper.md
Sources/User_Documentation_zh_CN/Documentation.docc/articles/supported-wallpaper-types.md
Sources/User_Documentation_zh_CN/Documentation.docc/homepage.md
Sources/User_Documentation_zh_CN/UserDocumentation.swift
```

`Package.swift` (Swift 6.0 tools version) declares a package literally named
`Wallpaper_Player_Documentation` with two library targets,
`User_Documentation_en_US` and `User_Documentation_zh_CN` — each a DocC catalog, not an app
target. The one `.swift` file per locale (`UserDocumentation.swift`) is an empty stub class:

```swift
class User_Documentation {
}
```

So structurally this "repo" is a **documentation-only publishing package**. It exists to
generate a DocC static site (see `.github/workflows/docs.yml`, which builds both locales with
`swift package generate-documentation` and deploys to GitHub Pages under
`wallpaper-player-mac/en_us` and `/zh_cn`). The actual application was distributed as a
**closed/private-source TestFlight build** (`README.md` links
`https://testflight.apple.com/join/k781W6GF`) with community coordination happening off-GitHub,
in a QQ group (`228230228`). The README is bilingual (EN/中文), matching the docs' two locales.

The docs content itself is unfinished: `supported-wallpaper-types.md` is a bare title with no
body in both locales, and `import-your-first-wallpaper.md` in the English catalog still contains
a literal unfilled DocC placeholder token (`<!--@START_MENU_TOKEN@-->Text<!--@END_MENU_TOKEN@-->`).

**Why this matters for the research goal:** you cannot compare Wallwright's window-management,
playback, or performance code against this repo's *code*, because none exists here. What you
*can* compare is packaging/process choices, positioning, and the honest gap between marketing
claims and delivered artifact — all still relevant to UI/UX and to how a project's own tooling
either helps or hides its rough edges.

---

## 1. Concrete findings

### 1.1 SwiftPM + DocC for user-facing docs, auto-published via CI (process, not code)
- **File:** `Package.swift`, `.github/workflows/docs.yml`
- The package builds *two DocC targets* (one per locale) and a GitHub Actions workflow
  auto-generates and deploys them to GitHub Pages on every push to `main`, with
  `--hosting-base-path` scoped per locale so both docs sites coexist.
- **Applicability:** UI/UX-adjacent (onboarding/help experience), not performance. Wallwright
  today has no equivalent — no in-repo user documentation package, no auto-published help site.
  A single onboarding article ("Import your first wallpaper") plus a hosted docs site is cheap
  to stand up with this exact recipe and would reduce the load on `FirstLaunchView.swift` /
  README as the only onboarding surfaces. This is a case of the *ancestor having infrastructure
  Wallwright lost/never inherited*, not a code pattern to port — worth flagging as a real,
  low-cost pickup rather than nostalgia.

### 1.2 Bilingual-first from day one, structurally (not bolted on)
- **Files:** `Sources/User_Documentation_en_US/`, `Sources/User_Documentation_zh_CN/` (parallel
  target trees), `README.md` (EN + 中文 in the same file).
- Localization here is a first-class *target*, not a resource-strings afterthought: each locale
  gets its own DocC catalog target in `Package.swift`, its own directory tree, its own
  `UserDocumentation.swift` stub. Compare to Wallwright's `Localizable.xcstrings` — a single
  catalog of key/value strings, the more conventional Xcode approach.
- **Applicability:** UI/UX. Not a suggestion to restructure Wallwright's localization (the
  `.xcstrings` catalog is the correct modern approach and strictly better for maintaining UI
  strings), but a reminder that this lineage's origin explicitly targeted a Chinese-speaking
  audience as a first-class user base (QQ group, Simplified Chinese docs target, Chinese-first
  ordering in some places) — worth keeping in mind if Wallwright's localization coverage or
  onboarding copy has drifted English-only over generations of forking.

### 1.3 Positioning claim vs. delivered artifact — a cautionary gap
- **File:** `Sources/User_Documentation_zh_CN/Documentation.docc/homepage.md:17`:
  > "Wallpaper Player是macOS下完成度最高的壁纸软件之一" — *"Wallpaper Player is one of the
  > most complete/polished wallpaper apps on macOS."*
- The English counterpart (`homepage.md:17`) is softer: *"your ideal, brilliant and dynamic
  desktop picture manager."* Both are marketing copy sitting directly above docs that are
  literally empty stubs (`supported-wallpaper-types.md` has no content in either language) and a
  README pointing only to a TestFlight beta with no changelog, screenshots, or feature list.
- **Applicability:** Cautionary, UI/UX-adjacent. This is a pattern worth Wallwright's maintainer
  consciously avoiding: public-facing claims (README, App Store copy, GitHub description) that
  outrun what's actually verifiable/finished in the repo erode trust once someone looks under
  the hood — exactly the scrutiny this research task just performed. It's a one-line gut check
  worth applying periodically to Wallwright's own README/marketing copy: does every claim have a
  visible, working feature behind it in the current tree?

### 1.4 Closed-source-with-open-docs is a legitimate but fragile distribution model
- The maintainer (`haren724`, per file headers `Created by Haren on 2025/1/16`) chose to open
  only the documentation package and keep the app itself as a private TestFlight build. This
  explains why downstream forks (`MrWindDog`, `Unayung`, ultimately Wallwright) had to
  **re-derive or independently write** the actual AppKit/AVFoundation wallpaper-rendering
  implementation rather than inherit code from this root — Wallwright's codebase is not a literal
  descendant of this repo's source, only of its *idea and product concept*.
- **Applicability:** Historical/architectural. Explains why Wallwright's AVPlayer-per-display
  window architecture, `AerialsInjector.swift`, `PlaylistViewModel.swift`, etc. have no direct
  analog to trace here — they were built fresh by later forks, not carried forward. Any future
  "what did the original get right" question about *rendering/performance* specifically needs to
  be aimed at `MrWindDog/wallpaper-engine-mac` (the next hop in the lineage that presumably first
  published real source), not this repo.

---

## 2. What did the original get simpler that Wallwright has since made more complex?

Because there's no implementation to diff, this can only be answered at the *product-surface*
level, not the code level:

- **Scope discipline in the docs' own framing.** The homepage copy commits to one sentence of
  identity ("dynamic desktop picture manager," "supports multiple media types") and one onboarding
  doc. Wallwright's current feature surface — lock-screen/aerial injection
  (`AerialsInjector.swift`), a draggable clock overlay (`ClockOverlay.swift`), Carbon-based global
  hotkeys (`GlobalHotkeyManager.swift`), per-scenario pause policies, dual-AVPlayer audio
  workaround, multi-display window management — is real, earned complexity accumulated over
  several forks solving real bugs (the README commit log shows fixes for audio drops, freezes,
  multi-display support). None of it looks like accidental complexity from this vantage point;
  there's simply nothing here simple enough to be "the version before the complexity" to compare
  against. **The honest conclusion: this ancestor is too early/thin to source a simplification
  lesson from — that lesson more likely lives in `MrWindDog/wallpaper-engine-mac`, the closer,
  code-bearing ancestor.**
- The one process-level "simpler and lost" item is documented above (1.1): a docs-as-code,
  CI-published help site. That's the one concrete regression-of-simplicity worth acting on.

---

## 3. Surprising / cautionary

1. **Surprising:** A project positioned prominently enough to be the root of Wallwright's stated
   lineage has, at least in its current public state, *zero lines of application code* — it's
   pure documentation scaffolding pointing at a private TestFlight binary.
2. **Cautionary:** Marketing superlatives ("most complete/polished") sitting directly above
   empty doc stubs is a small but real trust hazard — worth avoiding in Wallwright's own README
   as it accumulates forks and features.
3. **Elegant (if narrow):** The dual-target, dual-locale DocC package + one-workflow GitHub Pages
   publish (`docs.yml`) is a genuinely clean, low-maintenance recipe for user-facing help docs
   that Wallwright could adopt wholesale with minimal adaptation.

---

## 4. If I only had time for 3 things

1. **Don't spend more research time on this repo for code-level performance/architecture
   comparisons — it has none.** Redirect any further "what did the ancestor get right/wrong"
   investigation to `MrWindDog/wallpaper-engine-mac`, which is the first link in the chain likely
   to contain actual rendering/window-management source to diff against Wallwright's current
   implementation.
2. **Adopt the docs-as-code pattern (§1.1)** for Wallwright: a small DocC (or equivalent) user
   docs target plus a GitHub Actions job publishing to Pages, seeded with just one real article
   ("Import your first wallpaper" / first-run walkthrough) to reduce onboarding load on
   `FirstLaunchView.swift` alone. Cheap, additive, no risk to existing playback code.
3. **Apply the §1.3 gut-check to Wallwright's own README/App-Store copy**: audit current
   superlative claims against what's actually shipped and verifiable in the current tree, given
   how easy it is for claims to outlive the code behind them across forks.
