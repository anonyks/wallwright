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

    @State private var isDetectingCrop = false
    /// Transient feedback shown after a crop attempt either way — "cropped to WxH" or "no black
    /// bars found" — cleared the next time the sheet's opened for a (possibly different) wallpaper.
    @State private var cropResultMessage: String?

    @State private var isAutoTrimming = false
    /// Same idea as `cropResultMessage` — transient feedback after an Auto Trim attempt either way.
    @State private var autoTrimResultMessage: String?

    @State private var isManualCropping = false
    /// Normalized (0...1) crop rectangle within the video's own native pixel frame — NOT within the
    /// fixed 340x191.25 box it's drawn in. `ThumbnailImage`'s `.aspectRatio(16/9, contentMode: .fit)`
    /// is backed by `NSImageView.imageScaling = .scaleProportionallyUpOrDown`, which letterboxes/
    /// pillarboxes a non-16:9 video instead of stretching it — box-normalized and native-pixel-
    /// normalized coordinates are only the same fraction for an exactly-16:9 video. `CropOverlay`
    /// itself accounts for the difference (see its own `contentRect`), so this value is always
    /// genuinely native-pixel-normalized regardless of the video's aspect ratio.
    @State private var manualCropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var isApplyingManualCrop = false

    init(viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel, wallpaper: WEWallpaper) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
        self.wallpaper = wallpaper
        self._title = State(initialValue: wallpaper.project.title)
    }

    private var project: WEProject { wallpaper.project }

    var body: some View {
        VStack(spacing: 12) {
            PopupHeader(title: "Edit Wallpaper") {
                viewModel.isEditWallpaperReveal = false
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
                                .overlay {
                                    if isManualCropping {
                                        CropOverlay(
                                            boxSize: CGSize(width: 340, height: 191.25),
                                            nativeWidth: project.videoWidth ?? 0,
                                            nativeHeight: project.videoHeight ?? 0,
                                            targetAspect: targetAspect,
                                            rect: $manualCropRect
                                        )
                                    }
                                }
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
                            .glassFieldStyle()
                            .onSubmit(commitTitle)
                            .onChange(of: viewModel.isEditWallpaperReveal) { _, isPresented in
                                // Commit an in-progress title edit rather than silently dropping it
                                // if the popup is dismissed (click-outside) before Return is pressed.
                                // Also tear down an abandoned frame-chooser session so its AVPlayer
                                // doesn't keep decoding after the sheet's gone.
                                if !isPresented {
                                    commitTitle()
                                    cancelFrameChooser()
                                    isManualCropping = false
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
                                    .glassFieldStyle()
                                    .onSubmit(commitNewTag)
                                    // Without this, Escape had nothing here to consume it, so
                                    // AppKit bubbled it up to dismiss this entire sheet instead —
                                    // discarding any other unsaved edits just to back out of
                                    // adding one tag.
                                    .onKeyPress(.escape) {
                                        newTag = ""
                                        isAddingTag = false
                                        return .handled
                                    }
                                Button("Add", action: commitNewTag)
                                Button {
                                    newTag = ""
                                    isAddingTag = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Cancel")
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
    ///
    /// UI propagation happens first, synchronously — nothing it does touches disk — and the actual
    /// write moves to a background queue after. Confirmed live (2026-08-31): every title rename or
    /// tag add/remove was blocking the main thread on a synchronous encode+write, same anti-pattern
    /// as the already-fixed `ContentViewModel.refresh()` bug, just for a single small file instead
    /// of the whole library — still real, visible stutter on every keystroke-commit.
    private func updateProject(_ mutate: (inout WEProject) -> Void) {
        var updated = project
        mutate(&updated)
        propagateUpdatedProject(updated)
        let destination = wallpaper.wallpaperDirectory.appending(path: "project.json")
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(updated) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    /// The propagation half of `updateProject`, split out so `confirmChosenFrame` (whose own write
    /// goes through `VideoImporter.regenerateThumbnail` instead, since it also rewrites
    /// `preview.jpg`) can reuse it without a second write to `project.json`.
    private func propagateUpdatedProject(_ updated: WEProject) {
        let updatedWallpaper = WEWallpaper(using: updated, where: wallpaper.wallpaperDirectory)
        viewModel.hoveredWallpaper = updatedWallpaper
        // Every screen currently showing this wallpaper needs the update, not just whichever one
        // happens to be selected in the Settings UI — `wallpaperViewModel.wallpapers` is a per-screen
        // dictionary (a real, reachable multi-monitor case: the same wallpaper assigned to two
        // displays, or just a different screen selected in Display Settings than the one being
        // edited here). This matters especially for a crop: `VideoCropDetector.crop`/
        // `VideoImporter.applyCrop` always re-encodes to `.mp4`, and when the source was a
        // different container (`.mov`), the original file is deleted outright (see `applyCrop`'s own
        // doc comment) — a screen left pointing at the stale `WEProject` would still reference a
        // filename that no longer exists on disk at all, not just outdated dimensions.
        for (screenId, screenWallpaper) in wallpaperViewModel.wallpapers
        where screenWallpaper.wallpaperDirectory.isSameWallpaperDirectory(as: wallpaper.wallpaperDirectory) {
            wallpaperViewModel.wallpapers[screenId] = updatedWallpaper
        }
        // `updateWallpaperInPlace`, not `refresh()` — see its own doc comment: a full library
        // rescan here could race the background `project.json` write just below and read back
        // stale (pre-edit) content, silently reverting the edit that was just made.
        viewModel.updateWallpaperInPlace(updatedWallpaper)
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
                    Button("Set Start", action: setTrimStart)
                    Button("Set End", action: setTrimEnd)
                    // Finds a fade-in/fade-out black stretch and sets both trim points itself,
                    // rather than scrubbing by hand to find where the real content starts/ends —
                    // most useful for exactly what "Set Trim Start/End" are least suited to: a
                    // gradual fade rather than a sharp cut, where there's no single frame that's
                    // obviously "the" boundary to scrub to.
                    Button("Auto Trim") {
                        Task { await autoTrimBlackFrames() }
                    }
                    .disabled(isAutoTrimming || project.videoDuration == nil)
                    if isAutoTrimming {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if project.trimStart != nil || project.trimEnd != nil {
                        Text(trimRangeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let autoTrimResultMessage {
                    HStack {
                        Spacer()
                        Text(autoTrimResultMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else if isManualCropping {
                HStack {
                    Button("Cancel") {
                        isManualCropping = false
                    }
                    .disabled(isApplyingManualCrop)
                    Spacer()
                    if isApplyingManualCrop {
                        ProgressView().controlSize(.small)
                    }
                    Button("Apply Crop") {
                        Task { await applyManualCrop() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplyingManualCrop)
                }
                Text("Drag the corners to frame what to keep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    Button("Choose Frame", action: beginFrameChooser)
                    Menu("Crop") {
                        Button("Auto — Detect Black Bars") {
                            Task { await detectAndCropBlackBars() }
                        }
                        Button("Manual…", action: beginManualCrop)
                    }
                    .fixedSize()
                    .disabled(isDetectingCrop)
                    Spacer()
                }
                if isDetectingCrop {
                    HStack(spacing: 6) {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("Checking for black bars…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if let cropResultMessage {
                    HStack {
                        Spacer()
                        Text(cropResultMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
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
        // `replaceCurrentItem(with: nil)`, not just dropping the reference — same fix as
        // `VideoWallpaperViewModel.deinit`, with the same confirmed-live reasoning (114MB decoder
        // buffer pool freed on teardown): merely letting the `AVPlayer` deallocate wasn't reliably
        // releasing its `VTDecompressionSession`.
        scrubPlayer?.replaceCurrentItem(with: nil)
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

    private func autoTrimBlackFrames() async {
        guard let duration = project.videoDuration else { return }
        isAutoTrimming = true
        autoTrimResultMessage = nil
        defer { isAutoTrimming = false }
        let url = wallpaper.wallpaperDirectory.appending(path: project.file)
        guard let result = await VideoBlackFrameDetector.detectBlackTrim(at: url, duration: duration) else {
            autoTrimResultMessage = "No black fade-in/fade-out found"
            return
        }
        updateProject {
            if let trimStart = result.trimStart { $0.trimStart = trimStart }
            if let trimEnd = result.trimEnd { $0.trimEnd = trimEnd }
        }
        // Built from `result` directly, not the reactive `trimRangeText` — `wallpaper` is a plain
        // value-type property on this view, so it won't reflect `updateProject`'s change until
        // SwiftUI re-renders with fresh parameters, which hasn't happened yet at this point in the
        // same function call.
        let startText = result.trimStart.map(Self.formatTime) ?? project.trimStart.map(Self.formatTime) ?? "—"
        let endText = result.trimEnd.map(Self.formatTime) ?? project.trimEnd.map(Self.formatTime) ?? "—"
        autoTrimResultMessage = "Trimmed \(startText) – \(endText)"
    }

    /// Re-encodes the file in place, so unlike trim (a playback-time constraint, easy to preview
    /// and undo instantly) this takes a few real seconds and can't be "reset" back to the original
    /// — the black bars, once cropped away, are genuinely gone from the file. Worth it for the same
    /// reason the manual version was: no crop/fill setting at the display layer can remove bars
    /// that are part of the video's own pixels.
    private func detectAndCropBlackBars() async {
        isDetectingCrop = true
        cropResultMessage = nil
        defer { isDetectingCrop = false }
        if let updated = await VideoImporter.detectAndCropBlackBars(for: wallpaper) {
            propagateUpdatedProject(updated)
            if let width = updated.videoWidth, let height = updated.videoHeight {
                cropResultMessage = "Cropped to \(width)\u{00D7}\(height)"
            }
        } else {
            cropResultMessage = "No black bars found"
        }
    }

    /// The actual aspect ratio of the screen this wallpaper is set on — `.frame` is in points, not
    /// real pixels, but aspect ratio is scale-invariant so that doesn't matter here. Falls back to
    /// 16:9 only if no screen can be resolved at all (e.g. every display was just disconnected).
    private var targetAspect: CGFloat {
        let screen = NSScreen.screens.first(where: { WallpaperViewModel.screenId(for: $0) == wallpaperViewModel.selectedScreenId })
            ?? NSScreen.main
        guard let screen, screen.frame.height > 0 else { return 16.0 / 9.0 }
        return screen.frame.width / screen.frame.height
    }

    private func beginManualCrop() {
        manualCropRect = Self.defaultCropRect(
            nativeWidth: project.videoWidth ?? 0, nativeHeight: project.videoHeight ?? 0, targetAspect: targetAspect
        )
        cropResultMessage = nil
        isManualCropping = true
    }

    /// Largest `targetAspect` rectangle that fits centered in the box, in the video's own
    /// native-pixel terms — same starting point `applyManualCrop` will crop to if the user hits
    /// Apply without touching the handles at all.
    private static func defaultCropRect(nativeWidth: Int, nativeHeight: Int, targetAspect: CGFloat) -> CGRect {
        let normalizedAspect = CropOverlay.normalizedAspect(nativeWidth: nativeWidth, nativeHeight: nativeHeight, targetAspect: targetAspect)
        var width: CGFloat = 0.92
        var height = width / normalizedAspect
        if height > 0.92 {
            height = 0.92
            width = height * normalizedAspect
        }
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func applyManualCrop() async {
        guard let nativeWidth = project.videoWidth, let nativeHeight = project.videoHeight,
              nativeWidth > 0, nativeHeight > 0
        else {
            cropResultMessage = "Couldn't read this video's dimensions"
            isManualCropping = false
            return
        }
        let crop = VideoCropRect(
            x: Int((manualCropRect.minX * CGFloat(nativeWidth)).rounded()),
            y: Int((manualCropRect.minY * CGFloat(nativeHeight)).rounded()),
            width: Int((manualCropRect.width * CGFloat(nativeWidth)).rounded()),
            height: Int((manualCropRect.height * CGFloat(nativeHeight)).rounded())
        )
        isApplyingManualCrop = true
        defer { isApplyingManualCrop = false }
        if let updated = await VideoImporter.cropManually(for: wallpaper, to: crop) {
            propagateUpdatedProject(updated)
            if let width = updated.videoWidth, let height = updated.videoHeight {
                cropResultMessage = "Cropped to \(width)\u{00D7}\(height)"
            }
        } else {
            cropResultMessage = "Crop failed"
        }
        isManualCropping = false
    }
}

/// Draggable crop-rectangle overlay for the manual crop flow — four corner handles resize from
/// that corner, and dragging inside the rectangle moves it. Resize is locked to `targetAspect`
/// (the actual screen this wallpaper is set on, resolved by the caller — see
/// `EditWallpaperSheet.targetAspect`) rather than freeform: the live wallpaper is rendered with
/// `resizeAspectFill`, which crops again to fit the monitor, so a crop at some other aspect ratio
/// would just get silently re-cropped at display time in a way the user can't see or control here —
/// locking to the real screen aspect means what's framed here is what actually shows. `rect` is
/// normalized (0...1) within `boxSize`; native pixel dimensions are only needed to translate the
/// fixed *pixel* aspect ratio into the right *normalized* one (see `normalizedAspect` — box-
/// normalized and native-pixel-normalized fractions match per-axis, but only an unscaled aspect
/// ratio needs the native size to convert between the two).
private struct CropOverlay: View {
    let boxSize: CGSize
    let nativeWidth: Int
    let nativeHeight: Int
    let targetAspect: CGFloat
    @Binding var rect: CGRect

    private let minSize: CGFloat = 0.15
    private let handleDiameter: CGFloat = 14

    @State private var gestureStartRect: CGRect?

    static func normalizedAspect(nativeWidth: Int, nativeHeight: Int, targetAspect: CGFloat) -> CGFloat {
        guard nativeWidth > 0, nativeHeight > 0 else { return 1 }
        return targetAspect * CGFloat(nativeHeight) / CGFloat(nativeWidth)
    }

    private var normalizedAspect: CGFloat {
        Self.normalizedAspect(nativeWidth: nativeWidth, nativeHeight: nativeHeight, targetAspect: targetAspect)
    }

    /// The sub-rect (normalized 0...1 within `boxSize`) the video's own pixels actually occupy.
    /// `rect`'s box-fills-exactly-with-no-letterboxing assumption doesn't hold: `ThumbnailImage`
    /// with `.aspectRatio(16/9, contentMode: .fit)` is backed by `NSImageView.imageScaling =
    /// .scaleProportionallyUpOrDown`, which preserves the video's own native aspect ratio and
    /// CENTERS it in the box — not a stretch-to-fill. For any video that isn't exactly 16:9 (the
    /// box's own fixed aspect — 340/191.25 = 16/9 exactly), that leaves letterbox or pillarbox bars
    /// this overlay used to treat as if they were draggable crop area, silently skewing every crop
    /// coordinate against the real video content. Every other computation in this view (`rect`,
    /// `denormalize`, drag deltas) is now expressed relative to THIS rect instead of the full box,
    /// so `applyManualCrop`'s direct `rect * native dimensions` multiply is correct again.
    static func contentRect(nativeWidth: Int, nativeHeight: Int, boxAspect: CGFloat) -> CGRect {
        guard nativeWidth > 0, nativeHeight > 0, boxAspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let nativeAspect = CGFloat(nativeWidth) / CGFloat(nativeHeight)
        if nativeAspect > boxAspect {
            // Video is relatively WIDER than the box (e.g. 21:9 in a 16:9 box) — full box width,
            // letterboxed top/bottom.
            let heightFraction = boxAspect / nativeAspect
            return CGRect(x: 0, y: (1 - heightFraction) / 2, width: 1, height: heightFraction)
        } else {
            // Video is relatively TALLER/narrower than the box (e.g. 4:3 or vertical 9:16 in a
            // 16:9 box) — full box height, pillarboxed left/right.
            let widthFraction = nativeAspect / boxAspect
            return CGRect(x: (1 - widthFraction) / 2, y: 0, width: widthFraction, height: 1)
        }
    }

    private var contentRect: CGRect {
        Self.contentRect(nativeWidth: nativeWidth, nativeHeight: nativeHeight, boxAspect: boxSize.width / boxSize.height)
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    var body: some View {
        let pixelRect = denormalize(rect)
        ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: boxSize))
                path.addRect(pixelRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: pixelRect.width, height: pixelRect.height)
                .position(x: pixelRect.midX, y: pixelRect.midY)
                .contentShape(Rectangle())
                .gesture(dragGesture { start, dx, dy in
                    var moved = start
                    moved.origin.x = min(max(start.minX + dx, 0), 1 - start.width)
                    moved.origin.y = min(max(start.minY + dy, 0), 1 - start.height)
                    return moved
                })

            ForEach(Corner.allCases, id: \.self) { corner in
                handle(at: cornerPoint(corner, in: pixelRect)) { start, dx, _ in
                    resizedLocked(start, dx: dx, corner: corner)
                }
            }
        }
        .frame(width: boxSize.width, height: boxSize.height)
    }

    private func cornerPoint(_ corner: Corner, in pixelRect: CGRect) -> CGPoint {
        CGPoint(
            x: corner.isLeft ? pixelRect.minX : pixelRect.maxX,
            y: corner.isTop ? pixelRect.minY : pixelRect.maxY
        )
    }

    /// Drives resize off the horizontal drag delta only, then derives height from `normalizedAspect`
    /// — simpler and just as controllable as tracking both axes, since the aspect is fixed anyway
    /// (only one degree of freedom, size, is actually being chosen). The opposite corner is the
    /// anchor and never moves.
    private func resizedLocked(_ start: CGRect, dx: CGFloat, corner: Corner) -> CGRect {
        let anchorX = corner.isLeft ? start.maxX : start.minX
        let anchorY = corner.isTop ? start.maxY : start.minY
        let movingX = (corner.isLeft ? start.minX : start.maxX) + dx

        let maxWidth = corner.isLeft ? anchorX : (1 - anchorX)
        var width = min(max(abs(movingX - anchorX), minSize), maxWidth)

        let maxHeight = corner.isTop ? anchorY : (1 - anchorY)
        var height = width / normalizedAspect
        if height > maxHeight {
            height = maxHeight
            width = height * normalizedAspect
        }

        let minX = corner.isLeft ? anchorX - width : anchorX
        let minY = corner.isTop ? anchorY - height : anchorY
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private func handle(at point: CGPoint, update: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1))
            .frame(width: handleDiameter, height: handleDiameter)
            .position(point)
            .gesture(dragGesture(update: update))
    }

    /// `gestureStartRect` freezes `rect` at the first `onChanged` of whichever gesture is active —
    /// every later delta in that same drag is applied against that frozen start, not the
    /// continuously-mutating live value, so corner/move drags stay linear instead of compounding.
    private func dragGesture(update: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = gestureStartRect ?? rect
                if gestureStartRect == nil { gestureStartRect = start }
                // `rect` lives in content-normalized space (0...1 of the actual video area, see
                // `contentRect`'s doc comment) — a raw point delta needs dividing by the CONTENT's
                // own pixel size, not the outer box's, or a drag would move the crop rect faster or
                // slower than the mouse whenever the two differ (any non-16:9 video).
                let dx = value.translation.width / (boxSize.width * contentRect.width)
                let dy = value.translation.height / (boxSize.height * contentRect.height)
                rect = update(start, dx, dy)
            }
            .onEnded { _ in gestureStartRect = nil }
    }

    /// Maps `r` from content-normalized space (0...1 of the actual video area — see `contentRect`'s
    /// doc comment) to real box-pixel coordinates for drawing.
    private func denormalize(_ r: CGRect) -> CGRect {
        let content = contentRect
        let contentPixelRect = CGRect(
            x: content.minX * boxSize.width, y: content.minY * boxSize.height,
            width: content.width * boxSize.width, height: content.height * boxSize.height
        )
        return CGRect(
            x: contentPixelRect.minX + r.minX * contentPixelRect.width,
            y: contentPixelRect.minY + r.minY * contentPixelRect.height,
            width: r.width * contentPixelRect.width,
            height: r.height * contentPixelRect.height
        )
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
