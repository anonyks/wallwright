//
//  WallpaperPreview.swift
//  Wallwright
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI
import os

private let wallpaperDebugLog = Logger(subsystem: "com.wallwright.Wallwright", category: "VideoWallpaperDebug")

struct WallpaperPreview: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject var globalSettingsViewModel = AppDelegate.shared.globalSettingsViewModel

    @State var isEditingId = ""
    @State var title = ""
    @State var newTag = ""

    @State var hoveredTag: String?
    @State var isTagsHovered = false

    @State private var resolutionText: String?
    @State private var durationText: String?

    /// Ticks once a minute purely to force `dynamicFrameText` to re-evaluate — otherwise a Dynamic
    /// Desktop wallpaper's frame-of-day row would only ever show whatever it was at the moment
    /// this view last happened to redraw for some unrelated reason, not the actual current frame.
    @State private var dynamicFrameTick = Date()

    /// "Frame 8 of 16" for a Dynamic Desktop HEIC, so there's something concrete on screen proving
    /// detection + the time-of-day cycling logic are both actually working, rather than having to
    /// wait hours and squint at the desktop to notice a change. `currentFrameIndex` is a pure
    /// function of the current time, so this always matches (or is about to match, on the next
    /// timer tick) what `StaticImageWallpaperView` is actually rendering.
    private var dynamicFrameText: String? {
        _ = dynamicFrameTick
        let project = wallpaperViewModel.currentWallpaper.project
        guard project.isDynamicDesktop == true else { return nil }
        let url = wallpaperViewModel.currentWallpaper.wallpaperDirectory.appending(path: project.file)
        let frameCount = DynamicDesktopHEIC.frameCount(in: url)
        guard frameCount > 0 else { return nil }
        let index = DynamicDesktopHEIC.currentFrameIndex(frameCount: frameCount)
        return "Frame \(index + 1) of \(frameCount)"
    }

    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }

    var wallpaperSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(wallpaperViewModel.currentWallpaper.wallpaperSize), countStyle: .file)
    }

    /// Flags when the current rate would make an already-short clip loop faster than is easy to
    /// actually perceive (e.g. a 2s clip at 2x loops every second) — surfaced as information, not
    /// a limit: the full 0...2 range stays selectable regardless, this just explains what's
    /// happening instead of leaving a suddenly-flickery wallpaper unexplained.
    private var fastLoopWarning: String? {
        guard wallpaperViewModel.playRate > 0,
              let duration = wallpaperViewModel.currentWallpaper.project.videoDuration, duration > 0
        else { return nil }
        let effectiveLoop = duration / Double(wallpaperViewModel.playRate)
        guard effectiveLoop < 0.5 else { return nil }
        return String(format: "At %.1fx, this %.1fs clip loops about every %.2fs.", wallpaperViewModel.playRate, duration, effectiveLoop)
    }

    /// Prefers `project.videoWidth`/`videoHeight`/`videoDuration` — probed once at import time and
    /// persisted — over re-probing the file here. Only wallpapers imported before those fields
    /// existed fall back to `VideoImporter.backfillMetadataIfNeeded`, which probes once and
    /// persists the result so this stays free on every later visit.
    private func loadVideoInfo() async {
        let wallpaper = wallpaperViewModel.currentWallpaper
        guard wallpaper.project.type.lowercased() == "video" else {
            resolutionText = nil
            durationText = nil
            return
        }

        var project = wallpaper.project
        if project.videoWidth == nil || project.videoHeight == nil || project.videoDuration == nil {
            project = await VideoImporter.backfillMetadataIfNeeded(for: wallpaper) ?? project
        }

        if let width = project.videoWidth, let height = project.videoHeight {
            resolutionText = "\(width)\u{00D7}\(height)"
        } else {
            resolutionText = nil
        }
        durationText = project.durationText
    }

    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        ThumbnailImage(contentsOf: {
                            let project = wallpaperViewModel.currentWallpaper.project
                            return project == .invalid || project.preview.isEmpty
                                ? Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
                                : wallpaperViewModel.currentWallpaper.wallpaperDirectory.appending(path: project.preview)
                        }())
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(Color(nsColor: NSColor.controlBackgroundColor))
                            .frame(width: 280, height: 157.5)
                            // 12, not 16 — the app's corner radii otherwise form a deliberate tier
                            // (6 monitor picker → 8 tags/rows → 9 fields/pills → 10 grid cards → 12
                            // info cards → 20 popup shells); 16 was an unexplained outlier that
                            // belonged to none of them. 12 is the next tier up from the grid cards
                            // showing the exact same kind of content, appropriate for this being the
                            // larger "hero" instance of that same element.
                            .clipShape(RoundedRectangle(cornerRadius: 12.0))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                            // See ExplorerItem.swift's identical `.id()` comment — `preview.jpg`'s
                            // filename doesn't change when its content is regenerated, so this
                            // needs an explicit signal to guarantee a redraw. Currently masked by
                            // the `.animation(value: project)` below, but shouldn't depend on that.
                            // Placed after ThumbnailImage's own custom `.resizable()`/`.aspectRatio()`
                            // (declared directly on its concrete type, not generic View modifiers)
                            // rather than before them.
                            .id(wallpaperViewModel.currentWallpaper.project.thumbnailTimestamp)
                        HStack {
                            if isEditingId == "title" {
                                TextField("Wallpaper Title", text: $title)
                                    .onSubmit {
                                        var wallpaper = wallpaperViewModel.currentWallpaper

                                        wallpaper.project.title = title

                                        guard let data = try? JSONEncoder().encode(wallpaper.project) else { return }

                                        try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)

                                        wallpaperViewModel.currentWallpaper = wallpaper
                                        viewModel.refresh()

                                        isEditingId = ""
                                    }
                            } else {
                                FadingTitleText(text: wallpaperViewModel.currentWallpaper.project.title.isEmpty ? "Untitled" : wallpaperViewModel.currentWallpaper.project.title)
                                    .font(.headline)
                                    .frame(minWidth: 50, maxWidth: .infinity, alignment: .leading)
                                    .id("title")
                                    .onTapGesture(count: 2) {
                                        title = wallpaperViewModel.currentWallpaper.project.title
                                        isEditingId = "title"
                                    }
                                Button {
                                    viewModel.hoveredWallpaper = wallpaperViewModel.currentWallpaper
                                    viewModel.isEditWallpaperReveal = true
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Edit Wallpaper")
                            }
                        }
                    }
                    // Pause/Resume (and the Volume/Playback Rate sliders further down) only make
                    // sense for a video — a static image has no timeline/audio to pause, so this
                    // whole playback-transport block moved inside the video case below rather than
                    // showing unconditionally the way it used to.
                    if wallpaperViewModel.currentWallpaper.project.type.lowercased() == "video" {
                        Button {
                            if wallpaperViewModel.playRate == 0 {
                                wallpaperViewModel.isPausedByUser = false
                                AppDelegate.shared.resume()
                            } else {
                                wallpaperViewModel.isPausedByUser = true
                                AppDelegate.shared.pause()
                            }
                        } label: {
                            Label(
                                wallpaperViewModel.playRate == 0 ? "Resume" : "Pause",
                                systemImage: wallpaperViewModel.playRate == 0 ? "play.fill" : "pause.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        // Without an explicit tint, `.glassProminent` falls back to a neutral gray
                        // — this is the single primary action in the whole preview panel and was
                        // rendering with less visual weight than LibraryQuickControls' playlist
                        // button, a secondary control that already had the accent tint. Confirmed
                        // live (2026-08-08).
                        .tint(Color.accentColor)

                        // Only for a *policy* pause (battery/fullscreen-app/display-asleep/other-app-
                        // focused) — a manual pause is already self-explanatory from the button label
                        // alone, so this stays hidden then rather than stating the obvious.
                        if wallpaperViewModel.playRate == 0, !wallpaperViewModel.isPausedByUser,
                           let reason = globalSettingsViewModel.activePauseReasonText {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    VStack(spacing: 0) {
                        infoRow(icon: "square.stack.3d.up.fill", label: "Type") {
                            Text(wallpaperViewModel.currentWallpaper.project.type.capitalized)
                        }
                        if let dynamicFrameText {
                            Divider()
                            infoRow(icon: "sun.max.fill", label: "Dynamic Desktop") {
                                Text(dynamicFrameText)
                            }
                        }
                        if let resolutionText {
                            Divider()
                            infoRow(icon: "aspectratio.fill", label: "Resolution") {
                                Text(resolutionText)
                            }
                        }
                        if let durationText {
                            Divider()
                            infoRow(icon: "clock.fill", label: "Duration") {
                                Text(durationText)
                            }
                        }
                        Divider()
                        infoRow(icon: "internaldrive.fill", label: "File Size") {
                            Text(wallpaperSize)
                        }
                        Divider()
                        let impact = WallpaperImpactEstimator.estimate(for: wallpaperViewModel.currentWallpaper)
                        infoRow(icon: "bolt.fill", label: "Estimated Impact") {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(impact.color)
                                    .frame(width: 7, height: 7)
                                Text(impact.label)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

                    // Same animation applied once at this level, not duplicated inside both
                    // `ViewThatFits` branches — whichever branch SwiftUI picks animates identically
                    // either way, so the duplication bought nothing but a second value to keep in sync.
                    ViewThatFits(in: .horizontal) {
                        tags
                        ScrollView(.horizontal, showsIndicators: false) {
                            tags
                        }
                    }
                    .animation(AppMotion.popupTransition, value: isTagsHovered)
                    .onHover { isTagsHovered = $0 }

                    if isEditingId == "tags" {
                        HStack {
                            Button {
                                newTag = ""
                                isEditingId = ""
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            TextField("New Tag", text: $newTag)
                                .onSubmit {
                                    defer {
                                        newTag = ""
                                        isEditingId = ""
                                    }

                                    let trimmedTag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmedTag.isEmpty else { return }

                                    var wallpaper = wallpaperViewModel.currentWallpaper

                                    var tags = wallpaper.project.tags ?? []

                                    tags = Array(Set(tags)) // remove duplicate items

                                    tags.append(trimmedTag.capitalized)

                                    tags = Array(Set(tags)) // remove duplicate items

                                    wallpaper.project.tags = tags.sorted()

                                    guard let data = try? JSONEncoder().encode(wallpaper.project) else { return }

                                    try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)

                                    wallpaperViewModel.currentWallpaper = wallpaper
                                    viewModel.refresh()
                                }
                        }
                    }

                    switch wallpaperViewModel.currentWallpaper.project.type.lowercased() {
                    case "video":
                        VStack(spacing: 16) {
                            HStack {
                                Label("Volume", systemImage: "speaker.wave.3.fill")
                                Spacer()
                                Slider(value: $wallpaperViewModel.playVolume, in: 0...1).frame(width: 100)
                                Text(String(format: "%.0f", wallpaperViewModel.playVolume * 100) + "%")
                                    .frame(width: 35)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label("Playback Rate", systemImage: "play.fill")
                                    Spacer()
                                    Slider(value: $wallpaperViewModel.playRate, in: 0...2, step: 0.1).frame(width: 100)
                                    Text(String(format: "%.01fx", wallpaperViewModel.playRate))
                                        .frame(width: 35)
                                }
                                // Informational only — the full 0...2 range stays selectable either
                                // way, this just surfaces what the combination actually does rather
                                // than silently letting an already-short clip flash by unexplained.
                                if let fastLoopWarning {
                                    Label(fastLoopWarning, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    default:
                        EmptyView()
                    }
                }
                .blur(radius: wallpaperViewModel.currentWallpaper.project == .invalid ? 16.0 : 0)
                .overlay {
                    if wallpaperViewModel.currentWallpaper.project == .invalid {
                        Text("Please select a valid wallpaper")
                    }
                }
                .disabled(wallpaperViewModel.currentWallpaper.project == .invalid ? true : false)
                .animation(.default, value: wallpaperViewModel.currentWallpaper.project)
                .padding([.horizontal, .top])
                .task(id: wallpaperViewModel.currentWallpaper.wallpaperDirectory) {
                    await loadVideoInfo()
                }
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { tick in
                    dynamicFrameTick = tick
                }
            }

            HStack {
                Spacer()
                Button {
                    wallpaperDebugLog.notice("WallpaperPreview close (xmark) button tapped")
                    AppDelegate.shared.mainWindowController.close()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glassProminent)
                .contentShape(Rectangle())
                .help("Close")
            }
            .padding()
        }
    }

    private func infoRow(icon: String, label: LocalizedStringKey, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
            Spacer()
            trailing()
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.vertical, 7)
    }

    /// Shows all tags about current wallpaper in horizontal
    var tags: some View {
        HStack {
            if let tags = wallpaperViewModel.currentWallpaper.project.tags {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .padding(5)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 25.0))
                        .overlay(alignment: .topTrailing) {
                            if hoveredTag == tag {
                                Button {
                                    var wallpaper = wallpaperViewModel.currentWallpaper

                                    guard var tags = wallpaper.project.tags else { return } // else case seems impossible, however much safer

                                    tags = Array(Set(tags)) // remove duplicate items

                                    guard let index = tags.firstIndex(where: { $0 == tag }) else { return }

                                    tags.remove(at: index)

                                    wallpaper.project.tags = tags

                                    guard let data = try? JSONEncoder().encode(wallpaper.project) else { return }

                                    try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)

                                    wallpaperViewModel.currentWallpaper = wallpaper
                                    viewModel.refresh()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white, .red)
                                .symbolRenderingMode(.palette)
                                .offset(x: 5, y: -2.5)
                            }
                        }
                        .onHover { hovered in
                            if hovered {
                                hoveredTag = tag
                            } else {
                                hoveredTag = nil
                            }
                        }
                }
            } else {
                Text("No Tags")
                    .foregroundStyle(Color.secondary)
            }

            if isTagsHovered {
                Button {
                    isEditingId = "tags"
                } label: {
                    Image(systemName: "plus")
                        .font(.body)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .lineLimit(1)
    }
}

extension URL {
    /// Compares two wallpaper directory URLs by their standardized path rather than raw `URL`
    /// equality, which is fragile against trailing-slash or percent-encoding differences that
    /// can make two URLs pointing at the exact same folder compare as unequal.
    func isSameWallpaperDirectory(as other: URL) -> Bool {
        standardizedFileURL.path == other.standardizedFileURL.path
    }

    /// check if the URL is a directory and if it is reachable
    func isDirectoryAndReachable() throws -> Bool {
        guard try resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            return false
        }
        return try checkResourceIsReachable()
    }

    /// Returns total allocated size of the directory, including its subfolders or not. Only used
    /// as a fallback now — `WEWallpaper.wallpaperSize` prefers a cached value computed once at
    /// import time (see `WEProject.packageSizeBytes`), so this only runs for wallpapers imported
    /// before that existed.
    func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? {
        guard try isDirectoryAndReachable() else { return nil }
        if includingSubfolders {
            // Requesting the key directly from the enumerator (rather than `nil` + a second
            // `resourceValues` fetch per file) lets it use its own property cache, and iterating
            // it directly avoids materializing every file into an array first via `.allObjects`.
            guard let enumerator = FileManager.default.enumerator(
                at: self, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
            ) else { return nil }
            var total = 0
            for case let url as URL in enumerator {
                total += (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            }
            return total
        }
        return try FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil).lazy.reduce(0) {
                 (try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    .totalFileAllocatedSize ?? 0) + $0
        }
    }
}
