//
//  VideoWallpaperView.swift
//  Wallwright
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import AVKit

struct VideoWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: VideoWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: VideoWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId), screenId: screenId))
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()

        view.player = viewModel.player

        // Read once, here, not threaded through `updateNSView` — changing this setting triggers a
        // full `rebuildWallpaperWindows()` instead (see `GlobalSettingsViewModel`'s own
        // `didChangeVideoFitCancellable`), which recreates this view fresh with the new value.
        view.videoGravity = wallpaperViewModel.wallpaper(for: screenId).project
            .fit(otherwise: AppDelegate.shared.globalSettingsViewModel.settings.videoFit).videoGravity

        // Backstop matching StaticImageWallpaperView's own layer background — without this, anything
        // not covered by the player layer (a frame swap, the brief gap before the first frame decodes)
        // showed through as a white border, since the window behind it was never explicitly opaque/black.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        // hide any unneeded ui component, we want just the video output
        view.controlsStyle = .none

        // Tried enabling this to keep audio alive through lock (Now Playing registration is
        // macOS's "don't suspend this background process" signal). Didn't fix the lock/screensaver
        // audio issue, and it hijacks hardware media keys (play/pause) into controlling the
        // wallpaper instead of whatever's actually playing (Spotify/Music) — net regression, so
        // it stays off.
        view.updatesNowPlayingInfoCenter = false

        // mark the flag as unneeded, improve performance and reduce power drain
        view.allowsVideoFrameAnalysis = false

        viewModel.playerView = view

        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        // Was file-path-only (`wallpaperDirectory.appending(path: project.file)`), which missed
        // edits to the SAME file's metadata — trimming (or retitling, retagging, re-picking the
        // thumbnail frame of) the wallpaper currently showing on this screen changes `project` but
        // not the video file itself, so that check saw "same path" and never reassigned
        // `viewModel.currentWallpaper`. `applyTrimEnd`/`seedTrimStartIfNeeded` only ever read
        // `viewModel.currentWallpaper.project`, not this file's own `selectedWallpaper` — so a live
        // trim edit silently had zero effect on playback until switching to a different wallpaper
        // and back forced a real path change. Comparing the full `project` too (`Equatable`) closes
        // that gap while still skipping a rebuild on every unrelated re-render (playRate/playVolume
        // changes below don't touch `project` at all).
        if !selectedWallpaper.wallpaperDirectory.isSameWallpaperDirectory(as: currentWallpaper.wallpaperDirectory)
            || !selectedWallpaper.project.hasSameContent(as: currentWallpaper.project) {
            viewModel.currentWallpaper = selectedWallpaper
        } else if !viewModel.isWallpaperChangePending {
            // Only the scaling can differ here. While a new wallpaper is still loading, it gets
            // its scaling when it's swapped in, not on the outgoing video.
            viewModel.applyVideoFit()
        }

        viewModel.playRate = wallpaperViewModel.playRate
        viewModel.playVolume = wallpaperViewModel.playVolume
    }
}
