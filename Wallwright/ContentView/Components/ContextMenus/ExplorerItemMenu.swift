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
                    viewModel.hoveredWallpaper = hoveredWallpaper
                    viewModel.isRemoveConfirming = true
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
                if viewModel.selectedWallpapers.count > 1 {
                    Button(role: .destructive) {
                        viewModel.isBatchRemoveConfirming = true
                    } label: {
                        Label("Remove Selected (\(viewModel.selectedWallpapers.count))", systemImage: "xmark.circle")
                    }
                }
            }

            Section {
                Button {
                    NSWorkspace.shared.selectFile(nil,
                                                  inFileViewerRootedAtPath: hoveredWallpaper.wallpaperDirectory.path(percentEncoded: false))
                } label: {
                    Label("Open in Finder", systemImage: "folder.badge.gearshape")
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
