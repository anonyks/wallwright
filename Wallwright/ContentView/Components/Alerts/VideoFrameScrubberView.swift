//
//  VideoFrameScrubberView.swift
//  Wallwright
//
//  Native AVKit scrub UI for picking a thumbnail frame in EditWallpaperSheet — reuses
//  AVPlayerView's own built-in scrubber (`.inline` controls style) rather than a custom slider
//  driving repeated AVAssetImageGenerator calls, since AVKit already decodes/scrubs for free.
//  Deliberately the opposite of VideoWallpaperView.swift's `.controlsStyle = .none` (that one
//  hides controls because it IS the wallpaper; this one needs them because it's a picker).
//

import SwiftUI
import AVKit

struct VideoFrameScrubberView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.updatesNowPlayingInfoCenter = false
        view.allowsVideoFrameAnalysis = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    // Belt-and-suspenders alongside `EditWallpaperSheet.cancelFrameChooser()`'s own
    // `replaceCurrentItem(with: nil)` (which already tears down the actual decoder session) —
    // this drops the view's own strong reference to `player` the moment SwiftUI removes it from
    // the hierarchy, rather than waiting on `AVPlayerView`'s own deallocation.
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}
