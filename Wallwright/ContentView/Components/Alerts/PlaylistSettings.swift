//
//  PlaylistSettings.swift
//  Wallwright
//
//  In-app playlist management for the single rotation — build it from the library's existing
//  cmd-click multi-select, reorder items, and pick shuffle/switch-mode behavior. Mirrors
//  ClockSettings' structure (title bar + close button, ScrollView body, glassEffect container).
//

import SwiftUI

struct PlaylistSettings: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var playlistViewModel: PlaylistViewModel

    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self.playlistViewModel = AppDelegate.shared.playlistViewModel
    }

    var body: some View {
        VStack(spacing: 12) {
            PopupHeader(title: "Playlist") {
                viewModel.isPlaylistSettingsReveal = false
            }

            Text("Rotate through a chosen set of wallpapers automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Plain VStack, not a ScrollView — this section's content is short and fixed, and a
            // ScrollView here greedily expanded to fill the sheet's height even with nothing to
            // scroll, shoving the Items card below it down and leaving a large empty gap.
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(playlistViewModel.isActive ? "Deactivate" : "Activate") {
                        if playlistViewModel.isActive {
                            playlistViewModel.deactivate()
                        } else {
                            playlistViewModel.activate()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(playlistViewModel.isActive ? .red : .accentColor)
                    .disabled(!playlistViewModel.isActive && playlistViewModel.playlist.itemDirectories.isEmpty)

                    Spacer()

                    if playlistViewModel.isActive {
                        Label("Active", systemImage: "play.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }

                Toggle("Shuffle", isOn: $playlistViewModel.playlist.shuffleEnabled)
                    .toggleStyle(.switch)

                Picker("Switch Mode", selection: $playlistViewModel.playlist.switchMode) {
                    Text("Per Wallpaper Loop").tag(PlaylistSwitchMode.perWallpaper)
                    Text("Timed").tag(PlaylistSwitchMode.timed)
                }

                if playlistViewModel.playlist.switchMode == .timed {
                    HStack {
                        Text("Interval")
                        Slider(value: $playlistViewModel.playlist.timedIntervalMinutes, in: 1...120, step: 1)
                        TextField("", value: $playlistViewModel.playlist.timedIntervalMinutes, format: .number)
                            .frame(width: 50)
                        Text("min")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .popupCardStyle()

            // Deliberately its own top-level container, NOT nested inside a ScrollView —
            // a macOS List's row-drag gesture (which `.onMove` relies on for real click-and-drag
            // reordering) competes with an ancestor ScrollView's pan gesture and reliably loses,
            // silently breaking dragging. The List already scrolls its own content within its
            // fixed height, so it doesn't need — and shouldn't have — an outer ScrollView anyway.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Items (\(playlistViewModel.playlist.itemDirectories.count))")
                        .font(.headline)
                    Spacer()
                    Button {
                        let selected = viewModel.selectedWallpaperItems()
                        playlistViewModel.addWallpapers(selected.map(\.wallpaperDirectory))
                        viewModel.clearSelection()
                    } label: {
                        Label("Add Selected", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.selectedWallpapers.isEmpty)
                }

                if playlistViewModel.playlist.itemDirectories.isEmpty {
                    Text("⌘-click wallpapers, then Add Selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let itemCount = playlistViewModel.playlist.itemDirectories.count
                    List {
                        // Drag-to-reorder (`.onMove`) doesn't actually work here even with the
                        // List pulled out of the enclosing ScrollView — confirmed by direct
                        // testing, not just theory — so it's dropped entirely rather than left in
                        // as dead, misleading UI. The chevron/xmark buttons are the only
                        // reordering mechanism.
                        ForEach(Array(playlistViewModel.playlist.itemDirectories.enumerated()), id: \.element) { index, directory in
                            HStack {
                                Text(itemTitle(for: directory))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    playlistViewModel.moveItems(from: IndexSet(integer: index), to: index - 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                Button {
                                    playlistViewModel.moveItems(from: IndexSet(integer: index), to: index + 2)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == itemCount - 1)
                                Button {
                                    playlistViewModel.removeItems(at: IndexSet(integer: index))
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(itemCount) * 28 + 8, 260))
                    .scrollContentBackground(.hidden)
                }
            }
            .padding()
            .popupCardStyle()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
    }

    private func itemTitle(for directory: URL) -> String {
        viewModel.wallpapers.first(where: { $0.wallpaperDirectory.isSameWallpaperDirectory(as: directory) })?.project.title
            ?? directory.lastPathComponent
    }
}
