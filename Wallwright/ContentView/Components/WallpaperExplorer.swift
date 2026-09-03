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
                    // Keyed by the wallpaper's own `Identifiable` id, not array position — a
                    // position-keyed `ForEach` reuses a grid slot's view identity for whatever
                    // wallpaper now lands at that index on any reorder (sort/filter change, an
                    // import landing mid-list), which can transiently show a card's hover/border
                    // `@State` and in-flight thumbnail `.task` against the wrong wallpaper.
                    ForEach(items) { wallpaper in
                        ExplorerItem(viewModel: viewModel, wallpaperViewModel: wallpaperViewModel, wallpaper: wallpaper)
                            .contextMenu {
                                ExplorerItemMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel, current: wallpaper)
                            }
                    }
                }
                .padding(EdgeInsets(top: 4, leading: 2, bottom: 40, trailing: 12))
            }
        }
        // At the ScrollView level, not the LazyVGrid's — a LazyVGrid only has a hit-testable
        // frame around its actual content, so the inter-item spacing and everything below the
        // last row wouldn't register a right-click at all. ScrollView's own frame fills the whole
        // visible area, and a card's own separate .contextMenu above still wins when right-
        // clicking directly on one (SwiftUI resolves nested context menus to the innermost hit).
        // explorerIconSize already existed and already drove the grid's column sizing — there was
        // just no control anywhere to actually change it.
        .contextMenu {
            Button {
                viewModel.explorerIconSize = 120
            } label: {
                if viewModel.explorerIconSize == 120 { Label("Small", systemImage: "checkmark") }
                else { Text("Small") }
            }
            Button {
                viewModel.explorerIconSize = 200
            } label: {
                if viewModel.explorerIconSize == 200 { Label("Normal", systemImage: "checkmark") }
                else { Text("Normal") }
            }
            Button {
                viewModel.explorerIconSize = 280
            } label: {
                if viewModel.explorerIconSize == 280 { Label("Large", systemImage: "checkmark") }
                else { Text("Large") }
            }
        }
    }
}
