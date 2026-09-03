//
//  ExplorerItemMenu.swift
//  Wallwright
//
//  Created by Haren on 2023/8/29.
//

import SwiftUI

struct ExplorerItemMenu: SubviewOfContentView {
    
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    var hoveredWallpaper: WEWallpaper
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel, current hoveredWallpaper: WEWallpaper) {
        self.wallpaperViewModel = wallpaperViewModel
        self.viewModel = viewModel
        self.hoveredWallpaper = hoveredWallpaper
    }
    
    var body: some View {
        Group {
            Section {
                Button {
                    viewModel.hoveredWallpaper = hoveredWallpaper
                    viewModel.isEditWallpaperReveal = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }

            Section {
                Button {
                    AppDelegate.shared.playlistViewModel.addWallpapers([hoveredWallpaper.wallpaperDirectory])
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
            }

            Section {
                Button(role: .destructive) {
                    viewModel.hoveredWallpaper = hoveredWallpaper
                    viewModel.isRemoveConfirming = true
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                if viewModel.selectedWallpapers.count > 1 {
                    Button(role: .destructive) {
                        viewModel.isBatchRemoveConfirming = true
                    } label: {
                        Label("Delete \(viewModel.selectedWallpapers.count) Selected…", systemImage: "trash")
                    }
                }
            }

            Section {
                Button {
                    NSWorkspace.shared.selectFile(nil,
                                                  inFileViewerRootedAtPath: hoveredWallpaper.wallpaperDirectory.path(percentEncoded: false))
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
