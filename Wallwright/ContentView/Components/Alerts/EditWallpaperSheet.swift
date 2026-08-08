//
//  EditWallpaperSheet.swift
//  Wallwright
//
//  Right-click → Edit on a grid item. Self-contained popup (not the sidebar detail panel) with a
//  preview, title/tag editing, and a manual "Has Audio" override — for the rare case the automatic
//  AVAsset probe (see VideoImporter.probeVideoMetadata) gets a silent/near-silent audio track wrong.
//

import SwiftUI
import AVKit

struct EditWallpaperSheet: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    var wallpaper: WEWallpaper

    @State private var title: String
    @State private var isAddingTag = false
    @State private var newTag = ""
    @State private var hoveredTag: String?

    @State private var isChoosingFrame = false
    @State private var scrubPlayer: AVPlayer?
    @State private var isSavingFrame = false

    init(viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel, wallpaper: WEWallpaper) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
        self.wallpaper = wallpaper
        self._title = State(initialValue: wallpaper.project.title)
    }

    private var project: WEProject { wallpaper.project }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Text("Edit Wallpaper")
                    .font(.largeTitle.bold())
                HStack {
                    Spacer()
                    Button {
                        viewModel.isEditWallpaperReveal = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }

            ScrollView {
                VStack(spacing: 16) {
                    Group {
                        if isChoosingFrame, let scrubPlayer {
                            VideoFrameScrubberView(player: scrubPlayer)
                        } else {
                            ThumbnailImage(contentsOf: project == .invalid || project.preview.isEmpty
                                ? Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
                                : wallpaper.wallpaperDirectory.appending(path: project.preview))
                                .resizable()
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                // See ExplorerItem.swift's identical `.id()` comment. Placed after
                                // ThumbnailImage's own custom `.resizable()`/`.aspectRatio()` rather than
                                // before them, same reason.
                                .id(project.thumbnailTimestamp)
                        }
                    }
                    // ThumbnailImage's `sizeThatFits` only returns a sane size when BOTH dimensions
                    // are proposed (see its doc comment) — `.frame(maxWidth: .infinity)` alone
                    // leaves height unconstrained inside this ScrollView, which falls back to
                    // the raw gif file's native pixel size and blows the frame up to whatever
                    // huge size that is. A concrete frame, same as `WallpaperPreview` uses for
                    // this exact view, keeps it sane — the scrubber gets the same frame so
                    // swapping between the two doesn't jump the sheet's layout around.
                    .frame(width: 340, height: 191.25)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                    if project != .invalid, project.type.lowercased() == "video" {
                        frameChooserControls
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitTitle)
                            .onChange(of: viewModel.isEditWallpaperReveal) { _, isPresented in
                                // Commit an in-progress title edit rather than silently dropping it
                                // if the popup is dismissed (click-outside) before Return is pressed.
                                // Also tear down an abandoned frame-chooser session so its AVPlayer
                                // doesn't keep decoding after the sheet's gone.
                                if !isPresented {
                                    commitTitle()
                                    cancelFrameChooser()
                                }
                            }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Tags")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                isAddingTag = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        tagsView
                        if isAddingTag {
                            HStack {
                                TextField("New Tag", text: $newTag)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(commitNewTag)
                                Button("Add", action: commitNewTag)
                            }
                        }
                    }

                    if project.type.lowercased() == "video" {
                        Divider()

                        Toggle("Has Audio", isOn: Binding(
                            get: { project.hasAudio ?? false },
                            set: { newValue in updateProject { $0.hasAudio = newValue } }
                        ))
                        .toggleStyle(.switch)
                    }
                }
                .padding()
                .popupCardStyle()
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
    }

    private var tagsView: some View {
        FlowLayout(spacing: 6) {
            if let tags = project.tags, !tags.isEmpty {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.footnote)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: Capsule())
                        .overlay(alignment: .topTrailing) {
                            if hoveredTag == tag {
                                Button {
                                    removeTag(tag)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white, .red)
                                .symbolRenderingMode(.palette)
                                .offset(x: 5, y: -5)
                            }
                        }
                        .onHover { hovered in
                            hoveredTag = hovered ? tag : nil
                        }
                }
            } else {
                Text("No Tags")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.title else {
            title = project.title
            return
        }
        updateProject { $0.title = trimmed }
    }

    private func commitNewTag() {
        defer {
            newTag = ""
            isAddingTag = false
        }
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateProject { proj in
            var tags = Set(proj.tags ?? [])
            tags.insert(trimmed.capitalized)
            proj.tags = tags.sorted()
        }
    }

    private func removeTag(_ tag: String) {
        updateProject { proj in
            var tags = Set(proj.tags ?? [])
            tags.remove(tag)
            proj.tags = tags.sorted()
        }
    }

    /// Writes the mutated project straight to `project.json` (same atomic-write convention as
    /// every other in-app edit — see `WallpaperPreview`'s title/tag editors) and pushes the result
    /// back through `hoveredWallpaper` so this popup, the grid, and (if it's the active wallpaper)
    /// the live desktop all reflect the change immediately.
    private func updateProject(_ mutate: (inout WEProject) -> Void) {
        var updated = project
        mutate(&updated)
        guard let data = try? JSONEncoder().encode(updated) else { return }
        try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)
        propagateUpdatedProject(updated)
    }

    /// The propagation half of `updateProject`, split out so `confirmChosenFrame` (whose own write
    /// goes through `VideoImporter.regenerateThumbnail` instead, since it also rewrites
    /// `preview.jpg`) can reuse it without a second write to `project.json`.
    private func propagateUpdatedProject(_ updated: WEProject) {
        let updatedWallpaper = WEWallpaper(using: updated, where: wallpaper.wallpaperDirectory)
        viewModel.hoveredWallpaper = updatedWallpaper
        if wallpaperViewModel.currentWallpaper.wallpaperDirectory.isSameWallpaperDirectory(as: wallpaper.wallpaperDirectory) {
            wallpaperViewModel.currentWallpaper = updatedWallpaper
        }
        viewModel.refresh()
    }

    private var frameChooserControls: some View {
        VStack(spacing: 8) {
            if isChoosingFrame {
                HStack {
                    Button("Cancel", action: cancelFrameChooser)
                        .disabled(isSavingFrame)
                    Spacer()
                    if isSavingFrame {
                        ProgressView().controlSize(.small)
                    }
                    Button("Use This Frame") {
                        Task { await confirmChosenFrame() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSavingFrame)
                }
                HStack {
                    Button("Set Trim Start", action: setTrimStart)
                    Button("Set Trim End", action: setTrimEnd)
                    Spacer()
                    if project.trimStart != nil || project.trimEnd != nil {
                        Text(trimRangeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button("Choose Thumbnail Frame", action: beginFrameChooser)
                    Spacer()
                }
                if project.trimStart != nil || project.trimEnd != nil {
                    HStack(spacing: 6) {
                        Spacer()
                        Text(trimRangeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Reset") {
                            updateProject {
                                $0.trimStart = nil
                                $0.trimEnd = nil
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        Spacer()
                    }
                }
            }
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Shows immediate feedback after *either* button — "Set Trim Start" alone (with no end point
    /// yet) previously showed nothing at all, which read as the click not having done anything.
    private var trimRangeText: String {
        let startText = project.trimStart.map(Self.formatTime) ?? "—"
        let endText = project.trimEnd.map(Self.formatTime) ?? "—"
        return "Trim: \(startText) – \(endText)"
    }

    /// Only spins up a real `AVPlayer` (and thus a real decoder) when the user explicitly opts in
    /// here — opening the sheet itself stays on the cheap static `preview.jpg` via `ThumbnailImage`.
    private func beginFrameChooser() {
        let player = AVPlayer(url: wallpaper.wallpaperDirectory.appending(path: project.file))
        player.pause()
        scrubPlayer = player
        isChoosingFrame = true
    }

    private func cancelFrameChooser() {
        scrubPlayer?.pause()
        scrubPlayer = nil
        isChoosingFrame = false
    }

    private func confirmChosenFrame() async {
        guard let scrubPlayer else { return }
        let seconds = CMTimeGetSeconds(scrubPlayer.currentTime())
        guard seconds.isFinite, seconds >= 0 else { return }
        isSavingFrame = true
        defer { isSavingFrame = false }
        if let updated = await VideoImporter.regenerateThumbnail(for: wallpaper, atSeconds: seconds) {
            propagateUpdatedProject(updated)
        }
        cancelFrameChooser()
    }

    /// Unlike `confirmChosenFrame`, these deliberately stay in the scrub session (no
    /// `cancelFrameChooser()` call) — the user can set both trim points, and re-check the
    /// thumbnail, in one sitting rather than reopening the scrubber twice.
    private func setTrimStart() {
        guard let scrubPlayer else { return }
        let seconds = CMTimeGetSeconds(scrubPlayer.currentTime())
        guard seconds.isFinite, seconds >= 0 else { return }
        if let end = project.trimEnd, seconds >= end { return } // refuse an inverted range
        updateProject { $0.trimStart = seconds }
    }

    private func setTrimEnd() {
        guard let scrubPlayer else { return }
        let seconds = CMTimeGetSeconds(scrubPlayer.currentTime())
        guard seconds.isFinite, seconds >= 0 else { return }
        if let start = project.trimStart, seconds <= start { return }
        updateProject { $0.trimEnd = seconds }
    }
}

/// Minimal wrapping horizontal-then-vertical layout for the tag chips — `HStack` alone clips
/// overflow instead of wrapping, and this sheet doesn't need anything fancier than left-to-right
/// wrap.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = origin.y + rowHeight
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : origin.x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
