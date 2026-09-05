//
//  ExplorerItem.swift
//  Wallwright
//
//  Created by Haren on 2023/8/25.
//

import SwiftUI

struct ExplorerItem: SubviewOfContentView {
    
    @ObservedObject var viewModel: ContentViewModel
    // Deliberately NOT `@ObservedObject` — this object also carries `playRate`/`playVolume`
    // (mutated continuously while dragging the sidebar's Volume/Playback Rate sliders), and
    // `@ObservedObject` re-renders on ANY `@Published` change on the observed object, not just
    // the one field (`currentWallpaper`) this view actually cares about. With 58+ grid items each
    // independently subscribed, every slider tick was re-evaluating all of them. This view only
    // ever needs to WRITE `nextCurrentWallpaper` (on tap); the one thing it needs to read
    // (`isCurrent`) comes in as a plain value computed once by the parent instead.
    let wallpaperViewModel: WallpaperViewModel

    var wallpaper: WEWallpaper
    let isCurrent: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cornerRadius: CGFloat { 10 }

    var body: some View {
        let isMultiSelected = viewModel.isSelected(wallpaper)

        // A real Button, not a ZStack + `.onTapGesture` — the latter left the entire grid (the
        // app's core interaction) outside the Tab/focus order and invisible to VoiceOver, since a
        // tap gesture on a plain view carries no accessibility or focus semantics at all. `.plain`
        // keeps the existing custom visuals; the focus ring and keyboard activation (Space/Return)
        // come for free once it's a real control.
        Button {
            if NSEvent.modifierFlags.contains(.command) {
                viewModel.toggleSelection(for: wallpaper)
            } else {
                viewModel.clearSelection()
                wallpaperViewModel.nextCurrentWallpaper = wallpaper
                AppDelegate.shared.playlistViewModel.wallpaperWasManuallyPicked(wallpaper)
                viewModel.showToast("Applied \u{201C}\(wallpaper.project.title.isEmpty ? "Untitled" : wallpaper.project.title)\u{201D}")
            }
        } label: {
            ZStack(alignment: .bottom) {
                // `wallpaper.project` is already decoded (ContentViewModel.refresh() did that once for
                // the whole grid) — re-decoding project.json from disk here again, per item, per
                // render, was pure redundant I/O for information already sitting in memory.
                ThumbnailImage(contentsOf: wallpaper.project == .invalid || wallpaper.project.preview.isEmpty
                    ? Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
                    : wallpaper.wallpaperDirectory.appending(path: wallpaper.project.preview))
                .resizable()
                // Removing this (in an earlier attempt to fix the double hover-scale below) broke
                // the card's whole layout: `.aspectRatio(_, contentMode: .fit)`'s size proposal
                // depends on something in this exact chain position, even though `.scaleEffect` is
                // documented as a rendering-only transform — confirmed live via screenshot, every
                // card's ZStack blew up to fill the grid row instead of matching the 16:9 image,
                // with the topLeading impact-dot overlay floating far above the actual thumbnail.
                // Hardcoded to 1.0 (not tied to `isHovered`) so it can't reintroduce the double-
                // scale-on-hover this was originally trying to fix, while keeping whatever layout
                // role it plays intact.
                .scaleEffect(1.0)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
                // `preview.jpg`'s filename never changes when its content is regenerated (see
                // VideoImporter.regenerateThumbnail) — only the bytes on disk do. Without a signal
                // that actually differs, SwiftUI can (and does, confirmed live) skip re-invoking this
                // NSViewRepresentable's updateNSView, leaving the grid tile showing the stale image
                // even though the file itself is already correct. `.id()` forces it to be treated as
                // a new view whenever the one thing that DOES change (the picked timestamp) changes.
                // Placed after ThumbnailImage's own custom `.resizable()`/`.aspectRatio()` (which are
                // declared directly on its concrete type, not generic View modifiers, and disappear
                // once the chain becomes `some View`) rather than before them.
                .id(wallpaper.project.thumbnailTimestamp)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

                // Same fade-the-trailing-edge treatment WallpaperPreview's sidebar already used
                // for long titles — this used to hard-truncate with "…" via `.lineLimit(2)` instead,
                // for both video and image cards alike (never a type-specific gap, just a feature
                // that only existed in the sidebar until now).
                //
                // A FIXED height, not `minHeight` — `FadingTitleText` wraps a `GeometryReader`,
                // which greedily expands to fill whatever height its parent offers. The sidebar's
                // HStack row naturally kept that small, but this ZStack doesn't constrain height at
                // all, so `minHeight` alone let it balloon to a large chunk of the card — and since
                // its internal alignment centers the text vertically within whatever height it gets,
                // the title floated in the middle of the card instead of sitting at the bottom.
                // Confirmed live (2026-08-07).
                FadingTitleText(text: wallpaper.project.title)
                    .frame(maxWidth: .infinity, maxHeight: 18)
                    .padding(.leading, 6)
                    // `FadingTitleText` only knows the width its own container gives it — it has
                    // no idea the duration badge is sitting on top of it as a separate overlay in
                    // this same ZStack, so a long title just fades over its own last 40% and can
                    // run straight under that badge's corner instead of clearing it. Reserving
                    // extra trailing space only when a duration badge will actually be shown pushes
                    // the fade zone to end before that corner. Confirmed live (2026-08-08) on
                    // "Minecraft forrest and fireflies (4k...", where the badge sat directly on top
                    // of the tail of the title instead of the text fading out first.
                    .padding(.trailing, wallpaper.project.durationText != nil ? 46 : 6)
                    .padding(.vertical, 6)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                // `.strokeBorder`, not `.stroke` — the latter centers the line ON the shape's
                // boundary (half inside, half outside), which visibly bled outside the thumbnail's
                // own clipped bounds at the corners. `.strokeBorder` keeps the full line width
                // inside instead. Width nudged down slightly (3 → 2.5) since strokeBorder no
                // longer extends outward, to keep roughly the same perceived thickness.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2.5)
            }
            .overlay {
                if isHovered && !isCurrent {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isMultiSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title3)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                let impact = WallpaperImpactEstimator.estimate(for: wallpaper)
                Circle()
                    .fill(impact.color)
                    .frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
                    .padding(7)
                    .help("Estimated system impact: \(impact.label)")
            }
            .overlay(alignment: .topTrailing) {
                // Shares the corner with the multi-select checkmark — the checkmark takes priority
                // when both would apply, since selection state is the more actionable signal.
                if !isMultiSelected, wallpaper.project.hasAudio == true {
                    Image(systemName: "music.note")
                        .badgeStyle()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = wallpaper.project.durationText {
                    Text(duration)
                        .badgeStyle(font: .system(size: 7, weight: .semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(wallpaper.project.title)
        // Drag OUT — the library already accepts drops (see ContentView's `.onDrop`), but nothing
        // dragged back out to Finder, Messages, etc. Exports the actual media file, not the whole
        // wallpaper package folder (project.json and friends aren't useful outside the app). Pure
        // gesture plumbing — nothing runs unless a drag actually starts.
        .draggable(wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file))
        .shadow(color: .black.opacity(isHovered ? 0.25 : 0.12), radius: isHovered ? 6 : 3, y: 2)
        // Zoom/scale hover feedback is exactly the kind of repetitive motion Reduce Motion exists
        // to suppress — the border/shadow feedback above still communicates hover state without it.
        .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1.0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        // Backfills quality/duration/audio badges for wallpapers imported before those fields
        // existed — only runs for items actually scrolled into view (LazyVGrid), and only once per
        // wallpaper since the result is persisted to project.json (see `backfillMetadataIfNeeded`).
        .task(id: wallpaper.wallpaperDirectory) {
            await VideoImporter.backfillMetadataIfNeeded(for: wallpaper)
        }
    }
}

private extension View {
    /// Shared look for the small corner metadata badges (audio/quality/duration) — a dark
    /// semi-transparent pill with white content, matching the grid item's existing dark-gradient
    /// overlay aesthetic. Text badges (quality/duration) pass a smaller font than the default
    /// (used for the audio icon) so they read as secondary detail rather than competing with it.
    func badgeStyle(font: Font = .caption2.weight(.semibold)) -> some View {
        self
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
    }
}
