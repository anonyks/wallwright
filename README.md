<div align="center">

# Wallwright

**A native macOS live wallpaper engine.**
Video wallpapers on your desktop, lock screen, and screensaver — all in sync, all at once.

[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#build--run)
[![Latest release](https://img.shields.io/github/v/release/anonyks/wallwright)](https://github.com/anonyks/wallwright/releases/latest)
[![GitHub stars](https://img.shields.io/github/stars/anonyks/wallwright?style=flat&color=yellow)](https://github.com/anonyks/wallwright/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/anonyks/wallwright?style=flat)](https://github.com/anonyks/wallwright/fork)

</div>

---

Wallwright turns any video into a live desktop background — synced across your desktop, the
lock screen, and the screensaver at once, not just one of the three. It ships with a full
library manager, playlist rotation, a drag-anywhere clock overlay, and built-in browsers for
several free wallpaper sites, so you never have to leave the app to find something new.

Written for people who wanted [Wallpaper Engine](https://www.wallpaperengine.io) on Steam
but run macOS.

## Why Wallwright

Most open-source live-wallpaper projects for macOS are built once and left alone. Wallwright's
been through repeated, adversarial rounds of live-testing and bug fixing — decode races,
crash-recovery, per-display stability across reboots — the kind of engineering that a demo
doesn't show but a week of actual daily use exposes:

- **Survives reboots and monitor swaps.** Wallpaper assignments key off a stable per-display
  UUID, not the raw display ID macOS hands out fresh every boot — so your monitor setup doesn't
  get scrambled after a restart or a dock/undock.
- **Recovers from playback failures instead of freezing.** A corrupt file, a dropped external
  drive, an unplayable codec — Wallwright detects it and retries once, rather than leaving your
  desktop silently frozen on the last good frame with no explanation.
- **Actually pauses when it should.** Thermal throttling, low battery, another app in
  fullscreen, the display asleep — each is its own configurable trigger, checked live, not
  polled on a timer burning battery to ask "should I still be running?"
- **No wasted decode.** Video and audio are decoded once each, not twice — a bug present in
  most forks of this codebase that went unnoticed until it was profiled and fixed here.

None of that is visible in a screenshot. It's why the desktop stays correct at 3am on day 40,
not just in the demo.

## Features

- Video wallpapers synced across desktop, lock screen, and screensaver
- Multi-display support with a per-screen wallpaper picker
- Playlist rotation, pinning, and a recent-wallpapers menu
- Drag-repositionable clock overlay with custom formats and gradients
- Battery- and thermal-aware playback with configurable triggers
- Menu bar controls for playback, volume, and system usage
- Trim and crop editing, including auto-detection of black bars baked into a video
- Tag, audio, and media-type filtering in the library grid

## Import

- Folder, `.zip`, or a bare video file, via File > Import or drag-and-drop
- Any site yt-dlp supports, by URL, not just YouTube
- Steam Workshop, by item URL or ID
- Inbox: share a link from your phone over ntfy.sh, it shows up in-app ready to import
- Manually, by placing wallpaper folders in `~/Library/Application Support/Wallwright/`

## Browse & Download

Built-in browsers for free wallpaper sites, with search and one-click download.

- **Video**: [MotionBgs](https://motionbgs.com), [MoeWalls](https://moewalls.com), [Wallper.app](https://www.wallper.app), [DesktopHut](https://www.desktophut.com)
- **Image**: [UHDPaper](https://www.uhdpaper.com), [AlphaCoders](https://alphacoders.com)

Wallwright is not affiliated with any of these sites. Media remains subject to each site's own terms.

## Supported Types

Video and static images, including HEIC dynamic desktop wallpapers (the time-of-day-shifting
kind macOS ships by default).

## Install

Grab the latest signed build from **[Releases](https://github.com/anonyks/wallwright/releases/latest)** —
download, drag to Applications, done. No Xcode required.

Prefer to build it yourself, or want to modify it? See [Build & Run](#build--run) below.

## External Tools

Optional, used only by the feature that needs them. Wallwright looks for each one at the
standard Homebrew locations (`/opt/homebrew/bin`, `/usr/local/bin`) and `/usr/bin`, falling back
to `which` — a plain `brew install` is enough, no PATH setup needed.

| Tool | Used for | Install |
|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Video import from URL and the Inbox | `brew install yt-dlp` |
| [ffmpeg](https://ffmpeg.org) | Transcoding unsupported formats, crop detection | `brew install ffmpeg` |
| [steamcmd](https://developer.valvesoftware.com/wiki/SteamCMD) | Steam Workshop import | `brew install steamcmd` |

## Build & Run

```sh
git clone https://github.com/anonyks/wallwright.git
cd wallwright
open "Wallwright.xcodeproj"
```

Requires macOS 26+ and Xcode 26+. Select "Sign to Run Locally", then `Cmd + R`.

## Contributing

Issues and pull requests are welcome — see [open issues](https://github.com/anonyks/wallwright/issues)
for known gaps. This is a personal project maintained in spare time, so response time varies.

## Author

Wallwright is written and maintained by [anonyks](https://github.com/anonyks).

## Attribution

Wallwright is a fork, and a few specific mechanisms were adapted from other open-source work
rather than written from scratch. Credited here for that reason, not as active collaborators on
this project:

- **MrWindDog**, **[Haren Chen](https://github.com/haren724)**, **[Chen Chia Yang](https://github.com/Unayung)**: original architecture and scene rendering this project was forked from
- **[1ris_W](https://github.com/Erica-Iris)**, **[Klaus Zhu](https://github.com/klauszhu1105)**, **[baysonfox](https://github.com/baysonfox)**, **[Toby Shi](https://github.com/Toby-Shi-cloud)**, **Keria**: localization, icons, and other pieces present in the original fork
- **[Raunak Gupta](https://github.com/Raunik2)**: lock-screen sync, Aerial registration, and the command-pipe listener are adapted from [LivePaper](https://github.com/Raunik2/LivePaper) (MIT)
- **[kageroumado](https://github.com/kageroumado)**: the low-power-conditions auto-pause policy is modeled on [Phosphene](https://github.com/kageroumado/phosphene)'s PowerMonitor (MIT)

## License

[GPL-3.0](LICENSE), same as the original project.
