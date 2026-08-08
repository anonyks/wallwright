//
//  LibraryQuickControls.swift
//  Wallwright
//
//  Display + Playlist quick-access controls — moved out of the top tab bar and into the bottom
//  toolbar row (next to "Add Wallpaper") since that's where the "manage your library" actions
//  belong, and it puts something in the row that used to just be a big empty gap below it. Clock
//  and Settings stay up top since those get reached for far more often while just browsing.
//

import SwiftUI

struct LibraryQuickControls: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var playlistViewModel = AppDelegate.shared.playlistViewModel

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    viewModel.isDisplaySettingsReveal = true
                } label: {
                    Image(systemName: "display")
                        .frame(width: 18, height: 18)
                }
                .help("Displays")

                // Same split-button shape as the Clock control up top, but the main icon is
                // context-sensitive: with an active library multi-selection, one click adds those
                // wallpapers straight to the playlist — no detour through the sheet's own "Add
                // Selected" button. With no selection it falls back to its plain toggle role (open
                // the sheet / deactivate the playlist).
                HStack(spacing: 2) {
                    let hasSelection = !viewModel.selectedWallpapers.isEmpty
                    let mainAction = {
                        if hasSelection {
                            let selected = viewModel.selectedWallpaperItems()
                            playlistViewModel.addWallpapers(selected.map(\.wallpaperDirectory))
                            viewModel.clearSelection()
                        } else if playlistViewModel.isActive {
                            playlistViewModel.deactivate()
                        } else {
                            viewModel.isPlaylistSettingsReveal = true
                        }
                    }
                    let mainIcon = hasSelection
                        ? "list.bullet.badge.plus"
                        : (playlistViewModel.isActive ? "list.bullet.circle.fill" : "list.bullet")
                    let mainHelp = hasSelection
                        ? "Add \(viewModel.selectedWallpapers.count) Selected to Playlist"
                        : (playlistViewModel.isActive ? "Deactivate Playlist" : "Playlists")

                    if hasSelection || playlistViewModel.isActive {
                        Button(action: mainAction) {
                            Image(systemName: mainIcon)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color.accentColor)
                        .help(mainHelp)
                    } else {
                        Button(action: mainAction) {
                            Image(systemName: mainIcon)
                                .frame(width: 18, height: 18)
                        }
                        .help(mainHelp)
                    }
                    Button {
                        viewModel.isPlaylistSettingsReveal = true
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 14, height: 18)
                    }
                    .help("Playlist settings")
                }
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
        }
        .fixedSize()
    }
}
