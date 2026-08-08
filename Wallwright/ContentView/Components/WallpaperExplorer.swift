//
//  WallpaperExplorer.swift
//  Wallwright
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct WallpaperExplorer: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }

    var body: some View {
        // Computed once and reused below — this used to be read twice per render (once for the
        // empty-check, once in the ForEach), each a fresh call into the sort/filter pipeline.
        let items = viewModel.autoRefreshWallpapers
        return ScrollView {
            // MARK: Items
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No wallpapers found")
                        .font(.title3.weight(.semibold))
                    Text("Expand or reset the categories in the filter sidebar, or try another search term.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: viewModel.explorerIconSize,
                                                       maximum: viewModel.explorerIconSize * 2),
                                              spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.0) { (index, wallpaper) in
                        ExplorerItem(viewModel: viewModel, wallpaperViewModel: wallpaperViewModel, wallpaper: wallpaper, index: index)
                            .contextMenu {
                                ExplorerItemMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel, current: wallpaper)
                            }
                    }
                }
                .padding(EdgeInsets(top: 4, leading: 2, bottom: 40, trailing: 12))
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.maxPage > 1 {
                GlassEffectContainer(spacing: 2) {
                    HStack(spacing: 2) {
                        ForEach(0..<viewModel.maxPage, id: \.self) { page in
                            let isCurrentPage = viewModel.currentPage == page + 1
                            Button {
                                viewModel.currentPage = page + 1
                            } label: {
                                Text("\(page + 1)")
                                    .font(.callout.weight(isCurrentPage ? .semibold : .regular))
                                    .frame(minWidth: 26, minHeight: 22)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(isCurrentPage ? Color.accentColor : .secondary)
                            .glassEffect(
                                isCurrentPage ? .regular.tint(.accentColor) : .regular,
                                in: Capsule()
                            )
                        }
                    }
                    .padding(4)
                }
                .padding(.bottom, 12)
            }
        }
    }
}
