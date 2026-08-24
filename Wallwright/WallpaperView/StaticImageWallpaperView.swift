//
//  StaticImageWallpaperView.swift
//  Wallwright
//
//  Live-desktop renderer for a static image wallpaper — VideoWallpaperView's sibling for the
//  "image" type. No separate view model: unlike video, a static image has no persistent
//  decode/playback state to own across SwiftUI re-renders (no AVPlayer, no rate/volume, no
//  lock-unlock render-pipeline concerns — a plain CALayer.contents assignment doesn't have
//  AVPlayerLayer's remote-CAContext wedging problem), so this just reads the current wallpaper
//  directly from the shared WallpaperViewModel on every update. The one piece of persistent state
//  it does need — a periodic timer for Dynamic Desktop frame cycling — lives on the Coordinator,
//  same as `VideoFrameScrubberView`'s pattern elsewhere in this app.
//

import AppKit
import SwiftUI

struct StaticImageWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let screenId: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        // Fill and crop to aspect, matching VideoWallpaperView's `.resizeAspectFill` so switching
        // between a video and image wallpaper on the same screen looks consistent.
        view.layer?.contentsGravity = .resizeAspectFill
        updateWallpaper(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWallpaper(nsView, context: context)
    }

    private func updateWallpaper(_ view: NSView, context: Context) {
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let url = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
        let coordinator = context.coordinator

        // `updateNSView` can fire far more often than the wallpaper actually changes (any
        // unrelated SwiftUI re-render upstream) — only actually reload when the URL changed.
        guard coordinator.lastURL != url else { return }
        coordinator.lastURL = url
        coordinator.stopCycling()

        let screen = NSScreen.screens.first(where: { WallpaperViewModel.screenId(for: $0) == screenId })
        // The longer of the screen's two native pixel dimensions — enough for `resizeAspectFill`
        // to cover the screen at full quality regardless of orientation, without ever decoding
        // more detail than the screen can physically show.
        let maxPixelSize = screen.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }

        if wallpaper.project.isDynamicDesktop == true {
            coordinator.startCycling(url: url, view: view, maxPixelSize: maxPixelSize)
        } else if let screen {
            // Decoded at the screen's own native pixel resolution, not the source's — confirmed
            // live (2026-08-09) an 8K (7652x4073) wallpaper source was decoding to a ~119MB
            // IOSurface on a screen that physically only shows 3024x1964 pixels. Same fix as
            // `VideoWallpaperViewModel`'s `preferredMaximumResolution` cap already does for video.
            view.layer?.contents = ThumbnailDownsampler.decodedForScreen(at: url, screen: screen)
        } else {
            view.layer?.contents = NSImage(contentsOf: url)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
        private var timer: Timer?
        private var lastFrameIndex: Int?

        /// Draws the correct frame for right now, then checks again every 5 minutes — plenty
        /// granular for a 16-frame day (roughly one change per 1.5 hours) without re-decoding the
        /// file on every SwiftUI update the way a naive per-render check would.
        func startCycling(url: URL, view: NSView, maxPixelSize: CGFloat?) {
            applyFrame(url: url, view: view, maxPixelSize: maxPixelSize)
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self, weak view] _ in
                guard let self, let view else { return }
                self.applyFrame(url: url, view: view, maxPixelSize: maxPixelSize)
            }
            timer?.tolerance = 30
        }

        func stopCycling() {
            timer?.invalidate()
            timer = nil
            lastFrameIndex = nil
        }

        private func applyFrame(url: URL, view: NSView, maxPixelSize: CGFloat?) {
            let frameCount = DynamicDesktopHEIC.frameCount(in: url)
            let index = DynamicDesktopHEIC.currentFrameIndex(frameCount: frameCount)
            guard index != lastFrameIndex,
                  let cgImage = DynamicDesktopHEIC.frame(at: index, in: url, maxPixelSize: maxPixelSize)
            else { return }
            lastFrameIndex = index
            view.layer?.contents = cgImage
        }

        deinit {
            timer?.invalidate()
        }
    }
}
