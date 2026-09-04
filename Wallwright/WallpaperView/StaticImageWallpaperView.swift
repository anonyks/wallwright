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

        // Both branches below decode off-main and hop back — `decodedForScreen` in particular
        // decodes at the screen's own native pixel resolution (up to 5K/6K+), and doing that
        // synchronously here (this function runs on the main thread either way — `makeNSView`/
        // `updateNSView` are both main-thread AppKit callbacks) blocked the run loop for the
        // duration on every wallpaper switch/cycle change. `loadGeneration` guards against a stale
        // decode (from a since-superseded wallpaper) landing after a newer one already has.
        coordinator.loadGeneration += 1
        let generation = coordinator.loadGeneration
        if wallpaper.project.isDynamicDesktop == true {
            coordinator.startCycling(url: url, view: view, maxPixelSize: maxPixelSize)
        } else if let screen {
            // Decoded at the screen's own native pixel resolution, not the source's — confirmed
            // live (2026-08-09) an 8K (7652x4073) wallpaper source was decoding to a ~119MB
            // IOSurface on a screen that physically only shows 3024x1964 pixels. Same fix as
            // `VideoWallpaperViewModel`'s `preferredMaximumResolution` cap already does for video.
            DispatchQueue.global(qos: .userInitiated).async { [weak view, weak coordinator] in
                let cgImage = ThumbnailDownsampler.decodedForScreen(at: url, screen: screen)
                DispatchQueue.main.async {
                    guard let view, let coordinator, coordinator.loadGeneration == generation else { return }
                    view.layer?.contents = cgImage
                }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak view, weak coordinator] in
                let image = NSImage(contentsOf: url)
                DispatchQueue.main.async {
                    guard let view, let coordinator, coordinator.loadGeneration == generation else { return }
                    view.layer?.contents = image
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
        private var timer: Timer?
        private var lastFrameIndex: Int?
        private var appearanceObservation: NSKeyValueObservation?
        /// Bumped every time a new static (non-cycling) decode is kicked off — lets a completion
        /// handler tell whether it's still the most recent request before touching `view.layer`, so
        /// a stale decode from a since-superseded wallpaper (the user flipped to a different image,
        /// a video, or a Dynamic Desktop before the first one finished) can't clobber newer content
        /// that already landed. See `updateWallpaper`'s own comment for why this decode is async at all.
        var loadGeneration = 0

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
            // A 2-frame Dynamic Desktop is Apple's Light/Dark appearance toggle (see
            // DynamicDesktopHEIC.currentFrameIndex's own doc comment) — without this, switching
            // system appearance (Control Center, a scheduled sunset, Night Shift) left the desktop
            // stuck on the old frame for up to the full 300s until the timer happened to catch it.
            // KVO on NSApp.effectiveAppearance re-applies immediately instead. Harmless for any
            // other (time-based) frame count too — applyFrame just recomputes the same index it
            // already would have, a no-op via the lastFrameIndex guard below.
            appearanceObservation = NSApp.observe(\.effectiveAppearance, options: []) { [weak self, weak view] _, _ in
                guard let self, let view else { return }
                self.applyFrame(url: url, view: view, maxPixelSize: maxPixelSize)
            }
        }

        func stopCycling() {
            timer?.invalidate()
            timer = nil
            appearanceObservation = nil
            lastFrameIndex = nil
        }

        private func applyFrame(url: URL, view: NSView, maxPixelSize: CGFloat?) {
            let frameCount = DynamicDesktopHEIC.frameCount(in: url)
            let index = DynamicDesktopHEIC.currentFrameIndex(frameCount: frameCount)
            guard index != lastFrameIndex else { return }
            // `DynamicDesktopHEIC.frame(at:in:maxPixelSize:)` is a real pixel decode (not just
            // reading the container's frame directory, which `frameCount`/`currentFrameIndex`
            // above already do cheaply) — for a large 5K/6K Dynamic Desktop source, decoding on the
            // calling thread (main, in all three callers: initial load, the 5-minute timer, and the
            // Light/Dark appearance KVO) blocks the whole app's run loop for the duration. Only ever
            // fires on an actual frame change (rare — hours apart for a time-based cycle, or a
            // discrete user action for the 2-frame appearance case), but when it does, decoding off
            // main avoids a real, visible hitch for something this infrequent.
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
                guard let cgImage = DynamicDesktopHEIC.frame(at: index, in: url, maxPixelSize: maxPixelSize) else { return }
                DispatchQueue.main.async {
                    // `lastFrameIndex` is only advanced here, on a confirmed successful decode — it
                    // used to be set eagerly right after the `guard` above, before the decode even
                    // started. A transient failure (memory pressure, file contention, a corrupted
                    // frame) would still leave `lastFrameIndex` pointing at the now-"current" index,
                    // so the `guard index != lastFrameIndex` on every later tick for as long as that
                    // same index remains correct would keep skipping the retry — the view stuck on
                    // the last successfully-decoded frame for hours, until the clock moved on to a
                    // completely different index.
                    self?.lastFrameIndex = index
                    view?.layer?.contents = cgImage
                }
            }
        }

        deinit {
            timer?.invalidate()
            appearanceObservation = nil
        }
    }
}
