//
//  ThumbnailImage.swift
//  Wallwright
//
//  Created by Haren on 2023/8/15.
//
//  Static thumbnail loader — renamed from "GifImage": every call site passes a plain
//  `preview.jpg`, not an actual animated GIF, so the animation support this used to carry
//  (NSImageView.animates, the GIF loop-count rep hack, a bundle-resource-name init nothing used)
//  was pure unused complexity. Stripped down to just what's actually needed: load an image off
//  the main thread and display it.
//

import Cocoa
import SwiftUI

/// Process-lifetime cache so a thumbnail only ever decodes once per session, not once per tab
/// switch. Switching tabs destroys and rebuilds the entire grid subtree (a fresh `NSImageView` and
/// `Coordinator` per cell every time), so without this, every already-seen thumbnail went back
/// through a full async disk decode — no longer a freeze (that's fixed), but a real few-second
/// blank-then-populate delay on every single visit to the Library tab. Keyed identically to
/// `ThumbnailImage.currentKey()` (path + modification date), so a regenerated thumbnail still
/// invalidates correctly. `NSCache` is thread-safe and evicts under memory pressure on its own.
private let thumbnailImageCache = NSCache<NSString, NSImage>()

struct ThumbnailImage: NSViewRepresentable {

    var url: URL

    var isResizable: Bool = false
    var contentMode: ContentMode = .fill

    init(contentsOf url: URL) {
        self.url = url
    }

    func makeNSView(context: Context) -> NSImageView {
        let nsView = NSImageView()

        nsView.canDrawSubviewsIntoLayer = true
        nsView.imageScaling = .scaleProportionallyUpOrDown
        updateModifiers(nsView, coordinator: context.coordinator)

        return nsView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        updateModifiers(nsView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// `updateNSView` fires on every SwiftUI update to this view, not just when `url` actually
    /// changed (hover state, selection, an unrelated sibling re-render — anything that touches the
    /// enclosing view hierarchy). Without this, every grid tile re-decoded its image from disk on
    /// every one of those, which for a library of hundreds of wallpapers was real, redundant
    /// CPU/disk work on every hover. Keyed on modification date too, not just the path — a
    /// regenerated thumbnail (`VideoImporter.regenerateThumbnail`, `ImageImporter.commitImport`)
    /// can write new bytes to the *same* filename, which a path-only cache would miss.
    final class Coordinator {
        var lastLoadedKey: String?
        var loadTask: Task<Void, Never>?
    }

    private func currentKey() -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(mtime?.timeIntervalSince1970 ?? 0)"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        guard isResizable else {
            return nsView.sizeThatFits(nsView.frame.size)
        }
        if let width = proposal.width, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        // One or both dimensions weren't proposed — e.g. inside a LazyVGrid, where a row's
        // height is still being negotiated from its content. Returning nil here used to fall
        // through to AppKit's own intrinsic-size guess, which for an NSImageView with a loaded
        // image collapses to a degenerate size and breaks the aspectRatio() modifier wrapping
        // this view. Falling back to the loaded image's own pixel size keeps it concrete and
        // correctly proportioned so that modifier can still scale it down to fit.
        return nsView.image?.size
    }

    private func updateModifiers(_ nsView: NSImageView, coordinator: Coordinator) {
        let key = currentKey()
        if key != coordinator.lastLoadedKey {
            coordinator.lastLoadedKey = key
            coordinator.loadTask?.cancel()

            if let cached = thumbnailImageCache.object(forKey: key as NSString) {
                // Already decoded this session (e.g. the last time this tab was visible) — assign
                // synchronously, no blank frame while an async Task spins up for nothing.
                nsView.image = cached
            } else {
                // `NSImage(contentsOf:)` decodes synchronously — fine for one cell reusing its own
                // cached NSView, but switching tabs tears down and rebuilds the entire grid subtree,
                // so every visible thumbnail used to decode synchronously on the main thread, back to
                // back, in one pass. Confirmed live (2026-08-07) that was a real, visible freeze on
                // switching back to the Library tab. Decoding off the main thread here, then hopping
                // back to assign `nsView.image`, keeps the same caching behavior but stops a dozen-plus
                // simultaneous decodes from blocking the main thread at once.
                let url = self.url
                coordinator.loadTask = Task { [weak nsView, weak coordinator] in
                    let image = await Task.detached(priority: .userInitiated) {
                        NSImage(contentsOf: url)
                    }.value

                    guard !Task.isCancelled, let image, let nsView, let coordinator,
                          coordinator.lastLoadedKey == key
                    else { return }

                    thumbnailImageCache.setObject(image, forKey: key as NSString)
                    nsView.image = image
                }
            }
        }
        if self.isResizable {
            switch self.contentMode {
            case .fill:
                nsView.imageScaling = .scaleAxesIndependently
            case .fit:
                nsView.imageScaling = .scaleProportionallyUpOrDown
            }
        }
    }

    func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: Image.ResizingMode = .stretch) -> Self {
        var view = self
        view.isResizable = true
        return view
    }

    func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> Self {
        var view = self
        view.contentMode = contentMode
        return view
    }
}
