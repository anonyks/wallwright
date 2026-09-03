//
//  CommandPaletteView.swift
//  Wallwright
//
//  ⌘K quick-switcher — jump to any source/action, or fuzzy-find and apply a library wallpaper,
//  without leaving the keyboard. Reuses the same scrim-popup presentation every other popup in
//  this app already uses (see ContentView), so this adds no new presentation machinery, just one
//  more panel type. Filtering runs over `viewModel.wallpapers`, already in memory — no disk or
//  network access of its own.
//

import SwiftUI

private struct PaletteRow: Identifiable {
    // A stable, content-derived id, not `UUID()` — the row arrays below are computed properties,
    // re-evaluated on every body pass (every keystroke, every hover), so a fresh UUID per row on
    // every render made SwiftUI treat each row as a brand-new view each time, which is exactly the
    // kind of unstable identity that causes hover/selection state to flicker instead of animate.
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let matchText: String
    let action: () -> Void
}

struct CommandPaletteView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Suppresses hover-driven selection for a moment after a keyboard nav — without this, arrowing
    /// down scrolls a *different* row under a mouse cursor that never actually moved, that row's
    /// `onHover` fires as a fresh "true", and it snaps `selectedIndex` right back to wherever the
    /// mouse happens to be resting. Confirmed live: this made keyboard nav look stuck cycling within
    /// whichever section the mouse was sitting over. 250ms comfortably covers the 120ms scroll
    /// animation plus settle time; a genuine subsequent mouse move past that window still works.
    @State private var hoverSuppressedUntil = Date.distantPast

    private func moveSelection(by delta: Int) {
        hoverSuppressedUntil = Date().addingTimeInterval(0.25)
        selectedIndex = min(max(selectedIndex + delta, 0), max(allRows.count - 1, 0))
    }

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    private func dismiss() {
        viewModel.isCommandPaletteReveal = false
    }

    private var goToRows: [PaletteRow] {
        [
            PaletteRow(id: "Installed", icon: "square.grid.2x2.fill", title: "Installed", subtitle: "Library", matchText: "installed library") {
                self.viewModel.topTabBarSelection = 0
            },
            PaletteRow(id: "MotionBgs", icon: "globe", title: "MotionBgs", subtitle: "Video source", matchText: "motionbgs video") {
                self.viewModel.topTabBarSelection = 1
            },
            PaletteRow(id: "MoeWalls", icon: "sparkles", title: "MoeWalls", subtitle: "Video source", matchText: "moewalls video") {
                self.viewModel.topTabBarSelection = 2
            },
            PaletteRow(id: "Wallper.app", icon: "photo.artframe", title: "Wallper.app", subtitle: "Video source", matchText: "wallper video") {
                self.viewModel.topTabBarSelection = 3
            },
            PaletteRow(id: "DesktopHut", icon: "square.grid.3x3.fill", title: "DesktopHut", subtitle: "Video source", matchText: "desktophut video") {
                self.viewModel.topTabBarSelection = 4
            },
            PaletteRow(id: "UHDPaper", icon: "photo.on.rectangle.angled", title: "UHDPaper", subtitle: "Image source", matchText: "uhdpaper image") {
                self.viewModel.topTabBarSelection = 5
            },
            PaletteRow(id: "AlphaCoders", icon: "star.fill", title: "AlphaCoders", subtitle: "Image source", matchText: "alphacoders image") {
                self.viewModel.topTabBarSelection = 6
            }
        ]
    }

    private var importRows: [PaletteRow] {
        [
            PaletteRow(id: "Import from Folder", icon: "plus.rectangle.on.folder.fill", title: "Import from Folder", subtitle: "⌘I", matchText: "import folder open") {
                AppDelegate.shared.openImportFromFolderPanel()
            },
            PaletteRow(id: "Import from YouTube", icon: "play.rectangle.fill", title: "Import from YouTube", subtitle: "", matchText: "import youtube video") {
                self.viewModel.isYouTubeImportReveal = true
            },
            PaletteRow(id: "Import from Steam Workshop", icon: "gamecontroller.fill", title: "Import from Steam Workshop", subtitle: "", matchText: "import steam workshop") {
                self.viewModel.isSteamWorkshopImportReveal = true
            },
            PaletteRow(id: "Import from URL", icon: "link", title: "Import from URL", subtitle: "", matchText: "import url direct link") {
                self.viewModel.isDirectURLImportReveal = true
            }
        ]
    }

    private var actionRows: [PaletteRow] {
        [
            PaletteRow(id: "Displays", icon: "display", title: "Displays", subtitle: "⌘D", matchText: "displays monitor screen") {
                self.viewModel.isDisplaySettingsReveal = true
            },
            PaletteRow(id: "Clock Overlay", icon: "clock", title: "Clock Overlay", subtitle: "", matchText: "clock overlay time") {
                self.viewModel.isClockSettingsReveal = true
            },
            PaletteRow(id: "Playlist", icon: "list.bullet", title: "Playlist", subtitle: "", matchText: "playlist shuffle rotation") {
                self.viewModel.isPlaylistSettingsReveal = true
            },
            PaletteRow(id: "Settings", icon: "gearshape.fill", title: "Settings", subtitle: "⌘,", matchText: "settings preferences") {
                AppDelegate.shared.openSettingsWindow()
            }
        ]
    }

    /// Capped well below the full library — this is a jump-to tool, not a second grid to scroll.
    private var wallpaperRows: [PaletteRow] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return viewModel.wallpapers
            .filter { $0.project != .invalid && $0.project.title.localizedCaseInsensitiveContains(query) }
            .prefix(8)
            .map { wallpaper in
                PaletteRow(
                    id: wallpaper.wallpaperDirectory.path(percentEncoded: false),
                    icon: wallpaper.project.type.lowercased() == "video" ? "video.fill" : "photo.fill",
                    title: wallpaper.project.title.isEmpty ? "Untitled" : wallpaper.project.title,
                    subtitle: "",
                    matchText: wallpaper.project.title
                ) {
                    self.viewModel.clearSelection()
                    AppDelegate.shared.wallpaperViewModel.nextCurrentWallpaper = wallpaper
                    AppDelegate.shared.playlistViewModel.wallpaperWasManuallyPicked(wallpaper)
                    self.viewModel.topTabBarSelection = 0
                    self.viewModel.showToast("Applied \u{201C}\(wallpaper.project.title.isEmpty ? "Untitled" : wallpaper.project.title)\u{201D}")
                }
            }
    }

    private func filtered(_ rows: [PaletteRow]) -> [PaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { $0.matchText.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Grouped under labeled headers rather than one flat list — with up to 8 wallpaper matches
    /// plus 15 fixed nav/import/action rows, an undifferentiated list read as a wall of text with
    /// no way to tell "jump to a source" apart from "apply this wallpaper" at a glance.
    private var sections: [(title: String, rows: [PaletteRow])] {
        var result: [(String, [PaletteRow])] = []
        if !wallpaperRows.isEmpty { result.append(("Wallpapers", wallpaperRows)) }
        let goTo = filtered(goToRows)
        if !goTo.isEmpty { result.append(("Go to", goTo)) }
        let imports = filtered(importRows)
        if !imports.isEmpty { result.append(("Import", imports)) }
        let actions = filtered(actionRows)
        if !actions.isEmpty { result.append(("Actions", actions)) }
        return result
    }

    private var allRows: [PaletteRow] { sections.flatMap(\.rows) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to a source, action, or wallpaper…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard allRows.indices.contains(selectedIndex) else { return .ignored }
                        allRows[selectedIndex].action()
                        dismiss()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(12)
            .onChange(of: query) { _, _ in selectedIndex = 0 }

            Divider()

            // `ScrollViewReader` + `scrollTo` — without this, arrowing past the visible rows moved
            // `selectedIndex` (and its highlight) into rows still off-screen below the fold, with
            // nothing visibly tracking it. The list itself never followed the selection.
            ScrollViewReader { scrollProxy in
                ScrollView {
                    // Computed once per render, not once per row — `sections` re-filters the
                    // entire library (via `filtered`), and the old code called `allRows`
                    // (`sections.flatMap`) inside the inner `ForEach` to look up each row's index,
                    // recomputing that whole filter once per displayed row instead of once total.
                    let currentSections = sections
                    let rows = currentSections.flatMap(\.rows)
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if rows.isEmpty {
                            // Icon + message — every other empty/error state in the app pairs the
                            // two (BrowseStateView, LibraryEmptyStateView, WallpaperExplorer's own
                            // "no matches"); this was the one place that didn't.
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.tertiary)
                                Text("No matches")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        } else {
                            ForEach(currentSections, id: \.title) { section in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 4)
                                    ForEach(section.rows) { row in
                                        let index = rows.firstIndex(where: { $0.id == row.id }) ?? 0
                                        paletteRow(row, isSelected: index == selectedIndex)
                                            .id(row.id)
                                            .onTapGesture {
                                                row.action()
                                                dismiss()
                                            }
                                            .onHover { hovering in
                                                guard hovering, Date() > hoverSuppressedUntil else { return }
                                                selectedIndex = index
                                            }
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedIndex) { _, newValue in
                    guard allRows.indices.contains(newValue) else { return }
                    let targetId = allRows[newValue].id
                    if reduceMotion {
                        scrollProxy.scrollTo(targetId, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) {
                            scrollProxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 480)
        .onAppear { isSearchFocused = true }
    }

    private func paletteRow(_ row: PaletteRow, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.icon)
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.primary : .secondary)
            Text(row.title)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !row.subtitle.isEmpty {
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.18))
            }
        }
        // Rows are driven by the search field's arrow-key selection, not independent Tab stops
        // (matching Spotlight/Alfred-style palettes, where the text field keeps focus throughout) —
        // but VoiceOver's cursor navigates independently of Tab order, so without this a screen
        // reader user gets nothing when moving through the list.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.subtitle.isEmpty ? row.title : "\(row.title), \(row.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
