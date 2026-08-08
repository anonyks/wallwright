//
//  HoverPreviewPlayer.swift
//  Wallwright
//
//  Shared grid-hover preview player — originally built for MotionBgs, now reused by DesktopHut
//  and Wallper.app too, so it lives here rather than private to one source's view.
//

import SwiftUI
import AVKit
import Combine

/// AVPlayerView has its own built-in scroll-to-seek gesture (independent of `controlsStyle`),
/// which grabs the scroll wheel whenever the cursor is over it — breaking grid scrolling while
/// hovering a preview. This preview is purely decorative (muted, looping, no controls, nothing
/// to interact with), so hit-testing is disabled entirely: returning nil makes AppKit skip this
/// view during event dispatch and hand scroll/mouse events straight to the ScrollView behind it.
final class NonInteractivePlayerView: AVPlayerView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Minimal, chrome-free, muted, looping video player for grid-hover previews. Even a tiny clip
/// takes a moment to fetch and decode its first frame over the network — without `onReady`, the
/// view would show solid black (`AVPlayerView`'s background) during that gap. Callers should keep
/// their static thumbnail underneath in a `ZStack` and only fade this in once `onReady` fires, so
/// the thumbnail bridges the gap instead of a black flash.
struct HoverPreviewPlayer: NSViewRepresentable {
    let url: URL
    var onReady: (() -> Void)? = nil

    func makeNSView(context: Context) -> AVPlayerView {
        let view = NonInteractivePlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        view.updatesNowPlayingInfoCenter = false
        view.allowsVideoFrameAnalysis = false

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.play()
        view.player = player

        context.coordinator.readyCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .filter { $0 == .readyToPlay }
            .first()
            .sink { [onReady] _ in onReady?() }

        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var looper: AVPlayerLooper?
        var readyCancellable: AnyCancellable?
    }
}
