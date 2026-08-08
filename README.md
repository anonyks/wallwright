Wallwright
=========

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Wallwright is a live wallpaper engine for macOS. It plays video wallpapers on your desktop, lock screen, and screensaver at once, with a built-in library manager, playlist rotation, and a clock overlay.

Fork of [Unayung/wallpaper-engine-mac](https://github.com/Unayung/wallpaper-engine-mac), descended from [haren724/wallpaper-player-mac](https://github.com/haren724/wallpaper-player-mac). Not affiliated with the commercial Wallpaper Engine on Steam.

## Features

- Video wallpapers synced across desktop, lock screen, and screensaver
- Multi-display support with a per-screen wallpaper picker
- Playlist rotation, pinning, and a recent-wallpapers menu
- Drag-repositionable clock overlay with custom formats and gradients
- Battery-aware playback with configurable triggers
- Menu bar controls for playback, volume, and system usage

## Import

- Folder, `.zip`, or a bare video file, via File > Import or drag-and-drop
- YouTube, by URL
- Steam Workshop, by item URL or ID
- Manually, by placing wallpaper folders in `~/Library/Application Support/Wallwright/`

## Browse & Download

Built-in browsers for free wallpaper sites, with search and one-click download.

- **Video**: [MotionBgs](https://motionbgs.com), [MoeWalls](https://moewalls.com), [Wallper.app](https://www.wallper.app), [DesktopHut](https://www.desktophut.com)
- **Image**: [UHDPaper](https://www.uhdpaper.com), [AlphaCoders](https://alphacoders.com)

Wallwright is not affiliated with any of these sites. Media remains subject to each site's own terms.

## Supported Types

Video and static images.

## External Tools

Optional, used only by the feature that needs them.

| Tool | Used for | Install |
|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | YouTube import | `brew install yt-dlp` |
| [ffmpeg](https://ffmpeg.org) | Transcoding unsupported formats | `brew install ffmpeg` |
| [steamcmd](https://developer.valvesoftware.com/wiki/SteamCMD) | Steam Workshop import | `brew install steamcmd` |

## Build & Run

```sh
git clone <this-repo-url> Wallwright
cd Wallwright
open "Wallwright.xcodeproj"
```

Requires macOS 26+ and Xcode 26+. Select "Sign to Run Locally", then `Cmd + R`.

## Credits

- **MrWindDog**, **[Haren Chen](https://github.com/haren724)**: original architecture
- **[Chen Chia Yang](https://github.com/Unayung)**: scene rendering, multi-display support
- **[1ris_W](https://github.com/Erica-Iris)**: Chinese localization
- **[Klaus Zhu](https://github.com/klauszhu1105)**: app icons
- **[baysonfox](https://github.com/baysonfox)**, **[Toby Shi](https://github.com/Toby-Shi-cloud)**, **Keria**: additional contributions
- **[Raunak Gupta](https://github.com/Raunik2)**: lock-screen and Aerial registration, clock overlay, and battery/command plumbing, adapted from [LivePaper](https://github.com/Raunik2/LivePaper) (MIT)

## License

[GPL-3.0](LICENSE), same as the original project.
