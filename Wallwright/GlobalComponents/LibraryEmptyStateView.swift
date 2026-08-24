//
//  LibraryEmptyStateView.swift
//  Wallwright
//
//  Shown only when the library has never had a wallpaper imported — distinct from
//  WallpaperExplorer's own "no matches" message, which covers the filtered-to-zero case and needs
//  the search/filter/sort toolbar still visible so the user can reset whatever's hiding results.
//  Here there's nothing to filter yet, so the toolbar and filter sidebar are skipped entirely
//  rather than shown empty and useless above a blank grid.
//

import SwiftUI

struct LibraryEmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No wallpapers yet")
                .font(.title3.weight(.semibold))
            Text("Import a video or image from your files, or browse one of the sources in the sidebar to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                AppDelegate.shared.openImportFromFolderPanel()
            } label: {
                Label("Import Wallpaper", systemImage: "plus.rectangle.on.folder.fill")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
