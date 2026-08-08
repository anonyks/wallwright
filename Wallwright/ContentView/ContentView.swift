//
//  ContentView.swift
//  Wallwright
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI

protocol SubviewOfContentView: View {
    var viewModel: ContentViewModel { get set }
    
//    init(contentViewModel viewModel: ContentViewModel)
}

struct ContentView: View {
    @EnvironmentObject var globalSettingsViewModel: GlobalSettingsViewModel
    
    @ObservedObject var viewModel: ContentViewModel
    
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    @State var isDropTargeted = false
    @State var isParseFinished = false
    @State var isFilterReveal = true
    
    @State var isDockIconHidden = false
    
    @State var project: WEProject!
    @State var projectUrl: URL!
    @State var greet: String = "Hello, world!"
    
    var body: some View {
        ZStack {
            HSplitView {
                VStack(spacing: 5) {
                    TopTabBar(contentViewModel: viewModel)
                    switch viewModel.topTabBarSelection {
                    case 0:
                        ExplorerTopBar(contentViewModel: viewModel)
                            .environmentObject(globalSettingsViewModel)
                        HStack(spacing: 0) {
                            HStack(spacing: 0) {
                                // MARK: Filter Results
                                FilterResults(viewModel: viewModel)
                            }
                            .frame(width: viewModel.isFilterReveal ? 225 : 0)
                            .opacity(viewModel.isFilterReveal ? 1 : 0)

                            WallpaperExplorer(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                            .onDrop(of: [.fileURL], delegate: viewModel)
                            .padding(.leading, viewModel.isFilterReveal ? 10 : 0)
                        }
                        // A single animation covering the whole reveal (width, opacity, AND the
                        // explorer's leading padding) instead of two separate, differently-tuned
                        // animations on the same click — previously the sidebar sprang open on one
                        // curve while its neighbor's padding eased in on another, a visible seam on
                        // one user action. `AppMotion.popupTransition` matches every other popup's feel.
                        .animation(AppMotion.popupTransition, value: viewModel.isFilterReveal)
                        HStack {
                            Button {
                                AppDelegate.shared.openImportFromFolderPanel()
                            } label: {
                                Image(systemName: "plus.rectangle.on.folder.fill")
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .help("Open Wallpaper")
                            Spacer()
                            LibraryQuickControls(contentViewModel: viewModel)
                        }
                        .padding(.top, 8)
                    case 1:
                        MotionBgsView(contentViewModel: viewModel)
                    case 2:
                        MoeWallsView(contentViewModel: viewModel)
                    case 3:
                        WallperView(contentViewModel: viewModel)
                    case 4:
                        DesktopHutView(contentViewModel: viewModel)
                    case 5:
                        UhdPaperView(contentViewModel: viewModel)
                    case 6:
                        AlphaCodersView(contentViewModel: viewModel)
                    default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                WallpaperPreview(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                    .frame(maxWidth: 320)
            }
            // The scrim below blocks *clicks* on the grid underneath via its own tap gesture, but
            // `.onHover` uses separate hit-testing that a semi-transparent Color layer with just a
            // tap gesture doesn't shadow — grid items were still lighting up on hover right through
            // the dimmed popup overlay, even though clicks were correctly blocked. Disabling hit
            // testing entirely on the background while any popup is up stops hover from reaching
            // it at all, not just taps.
            .allowsHitTesting(!(viewModel.isDisplaySettingsReveal || viewModel.isClockSettingsReveal || viewModel.isPlaylistSettingsReveal || viewModel.isEditWallpaperReveal || viewModel.isYouTubeImportReveal || viewModel.isSteamWorkshopImportReveal || viewModel.isDirectURLImportReveal))

            // Displays/Clock/Playlist/YouTube/Steam as a click-outside-to-dismiss overlay instead
            // of a modal .sheet — sheets on macOS block all interaction with the window behind
            // them, so there's no way to click elsewhere to close one; this scrim-based popover
            // can be dismissed by clicking anywhere outside the panel itself. YouTube/Steam import
            // specifically need this: their downloads run independently of the view (see
            // YouTubeImportViewModel/SteamWorkshopImportViewModel), so closing the popup to keep
            // browsing no longer loses progress the way dismissing a real .sheet used to.
            if viewModel.isDisplaySettingsReveal || viewModel.isClockSettingsReveal || viewModel.isPlaylistSettingsReveal
                || viewModel.isEditWallpaperReveal || viewModel.isYouTubeImportReveal || viewModel.isSteamWorkshopImportReveal
                || viewModel.isDirectURLImportReveal {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.isDisplaySettingsReveal = false
                        viewModel.isClockSettingsReveal = false
                        viewModel.isPlaylistSettingsReveal = false
                        viewModel.isEditWallpaperReveal = false
                        viewModel.isYouTubeImportReveal = false
                        viewModel.isSteamWorkshopImportReveal = false
                        viewModel.isDirectURLImportReveal = false
                    }
                    .transition(.opacity)

                Group {
                    if viewModel.isDisplaySettingsReveal {
                        DisplaySettings(viewModel: viewModel)
                            .padding()
                            .frame(width: 520, height: 500)
                    } else if viewModel.isClockSettingsReveal {
                        ClockSettings(viewModel: viewModel)
                            .padding()
                            .frame(width: 480, height: 560)
                    } else if viewModel.isPlaylistSettingsReveal {
                        PlaylistSettings(viewModel: viewModel)
                            .padding()
                            .frame(width: 520, height: 600)
                    } else if viewModel.isEditWallpaperReveal, let hoveredWallpaper = viewModel.hoveredWallpaper {
                        EditWallpaperSheet(viewModel: viewModel, wallpaperViewModel: wallpaperViewModel, wallpaper: hoveredWallpaper)
                            .frame(width: 420, height: 560)
                    } else if viewModel.isYouTubeImportReveal {
                        YouTubeImportSheet(viewModel: viewModel, model: viewModel.youTubeImportViewModel)
                    } else if viewModel.isSteamWorkshopImportReveal {
                        SteamWorkshopImportSheet(viewModel: viewModel, model: viewModel.steamWorkshopImportViewModel)
                    } else if viewModel.isDirectURLImportReveal {
                        DirectURLImportSheet(viewModel: viewModel, model: viewModel.directURLImportViewModel)
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 30)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(AppMotion.popupTransition, value: viewModel.isDisplaySettingsReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isClockSettingsReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isPlaylistSettingsReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isEditWallpaperReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isYouTubeImportReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isSteamWorkshopImportReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isDirectURLImportReveal)
        // Replicates the old `.sheet(onDismiss:)` hand-off (YouTube/Steam download → next review
        // step) now that these are popups, not sheets. `.onChange` fires the instant the boolean
        // flips — well before the popup's own 0.3s spring dismiss transition (`.animation(...)`
        // above) actually finishes — so presenting a real .sheet (ImportReviewSheet/
        // PackageImportReviewSheet) right here would hit the exact same silent-no-op race the
        // original `.sheet(onDismiss:)` comment on `pendingYouTubeDownload` describes: SwiftUI
        // doesn't reliably show a new sheet while another presentation is still mid-transition.
        // A short delay lets the popup's own dismiss animation actually complete first.
        .onChange(of: viewModel.isYouTubeImportReveal) { _, isPresented in
            guard !isPresented, let url = viewModel.pendingYouTubeDownload else { return }
            viewModel.pendingYouTubeDownload = nil
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                await viewModel.enqueueImports([url])
            }
        }
        .onChange(of: viewModel.isSteamWorkshopImportReveal) { _, isPresented in
            guard !isPresented, let result = viewModel.pendingSteamWorkshopDownload else { return }
            viewModel.pendingSteamWorkshopDownload = nil
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                viewModel.enqueuePackageImport(directory: result.contentDirectory, project: result.project, sourceId: result.project.workshopid?.rawValue)
            }
        }
        .onChange(of: viewModel.isDirectURLImportReveal) { _, isPresented in
            guard !isPresented, let url = viewModel.pendingDirectURLDownload else { return }
            viewModel.pendingDirectURLDownload = nil
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                // Route by the downloaded file's own extension — DirectURLImporter itself doesn't
                // know or care what kind of file it fetched, so the dispatch happens here, the
                // same place YouTube/Steam downloads already hand off to their own pipelines.
                if ImageImporter.importableExtensions.contains(url.pathExtension.lowercased()) {
                    await viewModel.enqueueImageImports([url])
                } else {
                    await viewModel.enqueueImports([url])
                }
            }
        }
        .confirmationDialog("Remove Wallpaper",
                            isPresented: $viewModel.isRemoveConfirming) {
            if let url = viewModel.hoveredWallpaper?.wallpaperDirectory {
                let replacement = viewModel.autoRefreshWallpapers.first {
                    !$0.wallpaperDirectory.isSameWallpaperDirectory(as: url)
                }
                Button("Delete Immediately", role: .destructive) {
                    try? FileManager.default.removeItem(at: url)
                    wallpaperViewModel.removeWallpaperFromAllScreens(directory: url, replacement: replacement)
                    AppDelegate.shared.playlistViewModel.removeWallpaperFromPlaylist(directory: url)
                    viewModel.selectedWallpapers.remove(url)
                    viewModel.hoveredWallpaper = nil
                    viewModel.refresh()
                }
                Button("Move to Trash") {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    wallpaperViewModel.removeWallpaperFromAllScreens(directory: url, replacement: replacement)
                    AppDelegate.shared.playlistViewModel.removeWallpaperFromPlaylist(directory: url)
                    viewModel.selectedWallpapers.remove(url)
                    viewModel.hoveredWallpaper = nil
                    viewModel.refresh()
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.hoveredWallpaper = nil
            }
        } message: {
            Text("\(viewModel.hoveredWallpaper?.project.title ?? "invalid wallpaper")")
        }
        .confirmationDialog("Remove Wallpapers",
                            isPresented: $viewModel.isBatchRemoveConfirming) {
            Button("Delete All \(viewModel.selectedWallpapers.count) Immediately", role: .destructive) {
                let replacement = viewModel.autoRefreshWallpapers.first {
                    !viewModel.selectedWallpapers.contains($0.wallpaperDirectory)
                }
                for url in viewModel.selectedWallpapers {
                    try? FileManager.default.removeItem(at: url)
                    wallpaperViewModel.removeWallpaperFromAllScreens(directory: url, replacement: replacement)
                    AppDelegate.shared.playlistViewModel.removeWallpaperFromPlaylist(directory: url)
                }
                viewModel.clearSelection()
                viewModel.refresh()
            }
            Button("Move All \(viewModel.selectedWallpapers.count) to Trash") {
                let replacement = viewModel.autoRefreshWallpapers.first {
                    !viewModel.selectedWallpapers.contains($0.wallpaperDirectory)
                }
                for url in viewModel.selectedWallpapers {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    wallpaperViewModel.removeWallpaperFromAllScreens(directory: url, replacement: replacement)
                    AppDelegate.shared.playlistViewModel.removeWallpaperFromPlaylist(directory: url)
                }
                viewModel.clearSelection()
                viewModel.refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let items = viewModel.selectedWallpaperItems()
            let names = items.prefix(3).map(\.project.title).joined(separator: ", ")
            let suffix = items.count > 3 ? " and \(items.count - 3) more" : ""
            Text("Remove \(items.count) wallpapers: \(names)\(suffix)")
        }
        .alert(isPresented: $viewModel.importAlertPresented, error: viewModel.importAlertError) { _ in
        } message: { error in
            // The plain error: overload never actually showed `failureReason` (e.g. "This
            // wallpaper is a 'scene' type — only video is supported") — just the generic
            // "Couldn't Import X" from errorDescription, silently dropping the actual reason.
            if let reason = error.failureReason, !reason.isEmpty {
                Text(reason)
            }
        }
        .sheet(isPresented: $globalSettingsViewModel.isFirstLaunch) {
            FirstLaunchView()
                .environmentObject(globalSettingsViewModel)
        }
        .sheet(isPresented: Binding(
            get: { !viewModel.pendingImports.isEmpty },
            set: { isPresented in if !isPresented { viewModel.pendingImports.removeAll() } }
        )) {
            ImportReviewSheet(viewModel: viewModel)
        }
        .sheet(isPresented: Binding(
            get: { !viewModel.pendingImageImports.isEmpty },
            set: { isPresented in if !isPresented { viewModel.pendingImageImports.removeAll() } }
        )) {
            ImageImportReviewSheet(viewModel: viewModel)
        }
        .sheet(isPresented: Binding(
            get: { !viewModel.pendingPackageImports.isEmpty },
            set: { isPresented in if !isPresented { viewModel.pendingPackageImports.removeAll() } }
        )) {
            PackageImportReviewSheet(viewModel: viewModel)
        }
        .frame(minWidth: 1000, minHeight: 640, idealHeight: 800)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: .init(), wallpaperViewModel: .init())
            .environmentObject(GlobalSettingsViewModel())
    }
}
