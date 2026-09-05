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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Real desktop vibrancy, not `.ultraThinMaterial` — that SwiftUI material only blurs
            // whatever's WITHIN this window (useless once the window itself is the thing that's
            // supposed to look like glass). `WindowGlassBackground` wraps an `NSVisualEffectView`
            // in `.behindWindow` mode, which macOS composites against the real desktop and other
            // windows — but only once `MainWindowController` has actually made this window
            // non-opaque (see its own comment); on an opaque window this would just render as a
            // flat gray fill.
            // The window itself stays non-opaque/`.clear` at the AppKit level regardless of this
            // setting (see `MainWindowController`'s own comment) — toggling `isOpaque` dynamically
            // at runtime is a real flicker risk, so "off" is just painting a normal opaque color
            // over the same clear window instead of reconfiguring the window itself.
            if globalSettingsViewModel.settings.windowVibrancy {
                WindowGlassBackground()
                    .ignoresSafeArea()
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
            HSplitView {
                VStack(spacing: 5) {
                    TopTabBar(contentViewModel: viewModel)
                    ZStack {
                        // The Library tab's content used to be a `switch` case like every other
                        // tab — but each `switch` case is a distinct view identity in SwiftUI, so
                        // leaving it (by switching to any browse tab) fully deallocated
                        // `WallpaperExplorer` and every `ExplorerItem`/`ThumbnailImage` inside it,
                        // and returning rebuilt the whole thing from zero: re-ran `sortedWallpapers`,
                        // re-triggered every card's `ThumbnailImage` cache-key stat call (a fresh
                        // `Coordinator` has no `lastCheckedURL` to short-circuit against), and
                        // restarted every card's `backfillMetadataIfNeeded` `.task` — a real,
                        // confirmed freeze on a library of any size, worst right after browsing an
                        // online source tab. Kept permanently mounted here instead, toggling
                        // visibility (opacity + hit-testing) rather than existence — the browse
                        // tabs below still tear down/rebuild via `switch` on tab changes among
                        // themselves, since those aren't the tab someone bounces back to constantly.
                        if viewModel.wallpapers.isEmpty {
                            // Nothing imported yet — the search/filter/sort toolbar and filter
                            // sidebar have nothing to act on, so skip them rather than show them
                            // empty above a blank grid.
                            if viewModel.topTabBarSelection == 0 {
                                LibraryEmptyStateView()
                            }
                        } else {
                            VStack(spacing: 5) {
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
                                    .buttonStyle(.glass)
                                    .controlSize(.large)
                                    // `.glassProminent` renders as an opaque matte fill, not the
                                    // translucent lens `LibraryQuickControls`' own `.glass`-styled
                                    // buttons beside it use — mismatched against the rest of the
                                    // bottom bar. Plain `.glass` matches. No `.tint()` — with the
                                    // Graphite system accent, tinting just recolors the fill gray
                                    // while flattening the translucency (confirmed live on the
                                    // Pause button, 2026-09-05); untinted keeps the pale glass look.
                                    .help("Open Wallpaper (⌘I)")
                                    Text("^[\(viewModel.visibleWallpaperCount) wallpaper](inflect: true)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 4)
                                    Spacer()
                                    LibraryQuickControls(contentViewModel: viewModel)
                                }
                                .padding(.top, 8)
                            }
                            .opacity(viewModel.topTabBarSelection == 0 ? 1 : 0)
                            .allowsHitTesting(viewModel.topTabBarSelection == 0)
                        }

                        switch viewModel.topTabBarSelection {
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
                        case 7:
                            InboxView(contentViewModel: viewModel)
                        default:
                            EmptyView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                // This column was relying entirely on SwiftUI's automatic top safe-area inset for
                // clearance under the transparent title bar — nothing here gave it a fixed value of
                // its own. That inset isn't a stable constant: opening any of the Displays/Clock/
                // Playlist/Import popups adds another `.ignoresSafeArea()` view (the dimming scrim)
                // as a sibling in the same outer `ZStack`, which changed how much top inset SwiftUI
                // reported here — confirmed live (2026-09-05) as the whole toolbar/search/grid
                // column visibly jumping up while a popup was open. Ignoring the safe area here and
                // supplying the standard title-bar height explicitly makes this immune to whatever
                // else is going on elsewhere in the ZStack.
                .padding(.top, 28)
                .ignoresSafeArea(.container, edges: .top)
                WallpaperPreview(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                    .frame(maxWidth: 320)
                    // Scoped to just this panel (via `.overlay`, sized to its own bounds) rather
                    // than floating over the whole window — a window-wide toast centered near the
                    // top collided with the top tab bar's own row, which sits at almost the same
                    // height. Anchoring here instead ties it visually to the wallpaper it's
                    // confirming, which this panel is already showing the details of.
                    .overlay(alignment: .top) {
                        if let toastMessage = viewModel.toastMessage {
                            Label(toastMessage, systemImage: "checkmark.circle.fill")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .popupCardStyle()
                                .padding(.top, 12)
                                .allowsHitTesting(false)
                                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        }
                    }
                    // Same fix as the left column's — this panel relied on the same ambient top
                    // safe-area inset for its own clearance, so it jumped up right along with the
                    // toolbar/grid whenever a popup's scrim added another `.ignoresSafeArea()`
                    // sibling. Confirmed live (2026-09-05).
                    .padding(.top, 28)
                    .ignoresSafeArea(.container, edges: .top)
            }
            // The scrim below blocks *clicks* on the grid underneath via its own tap gesture, but
            // `.onHover` uses separate hit-testing that a semi-transparent Color layer with just a
            // tap gesture doesn't shadow — grid items were still lighting up on hover right through
            // the dimmed popup overlay, even though clicks were correctly blocked. Disabling hit
            // testing entirely on the background while any popup is up stops hover from reaching
            // it at all, not just taps.
            .allowsHitTesting(!(viewModel.isDisplaySettingsReveal || viewModel.isClockSettingsReveal || viewModel.isPlaylistSettingsReveal || viewModel.isEditWallpaperReveal || viewModel.isYouTubeImportReveal || viewModel.isSteamWorkshopImportReveal || viewModel.isDirectURLImportReveal || viewModel.isCommandPaletteReveal))

            // Displays/Clock/Playlist/YouTube/Steam as a click-outside-to-dismiss overlay instead
            // of a modal .sheet — sheets on macOS block all interaction with the window behind
            // them, so there's no way to click elsewhere to close one; this scrim-based popover
            // can be dismissed by clicking anywhere outside the panel itself. YouTube/Steam import
            // specifically need this: their downloads run independently of the view (see
            // YouTubeImportViewModel/SteamWorkshopImportViewModel), so closing the popup to keep
            // browsing no longer loses progress the way dismissing a real .sheet used to.
            if viewModel.isDisplaySettingsReveal || viewModel.isClockSettingsReveal || viewModel.isPlaylistSettingsReveal
                || viewModel.isEditWallpaperReveal || viewModel.isYouTubeImportReveal || viewModel.isSteamWorkshopImportReveal
                || viewModel.isDirectURLImportReveal || viewModel.isCommandPaletteReveal {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture(perform: dismissAllPopups)
                    // Escape closing a dialog is a basic, expected macOS convention — every one of
                    // these popups (bar the Command Palette, which already had its own) was missing
                    // it entirely, the X button or an outside click were the only ways out. One
                    // handler here covers all of them at once, same as the outside-click dismiss
                    // above already does, rather than adding it individually to each sheet.
                    .onExitCommand(perform: dismissAllPopups)
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
                        // `.id()` forces SwiftUI to tear down and recreate this view (re-running its
                        // `init`, re-seeding `@State private var title`) whenever the wallpaper being
                        // edited changes — the background scrim already disables all hit-testing on
                        // the grid while this sheet is open (see its own comment a few lines up), so
                        // `hoveredWallpaper` can't actually change to a DIFFERENT wallpaper while this
                        // branch stays selected in practice today. Explicit all the same: relying on
                        // that scrim to be what keeps `@State` correctly reset is exactly the kind of
                        // incidental protection a future refactor could break without anyone noticing
                        // the safety implications, and this costs nothing.
                        EditWallpaperSheet(viewModel: viewModel, wallpaperViewModel: wallpaperViewModel, wallpaper: hoveredWallpaper)
                            .id(hoveredWallpaper.wallpaperDirectory)
                            .frame(width: 420, height: 560)
                    } else if viewModel.isYouTubeImportReveal {
                        YouTubeImportSheet(viewModel: viewModel, model: viewModel.youTubeImportViewModel)
                    } else if viewModel.isSteamWorkshopImportReveal {
                        SteamWorkshopImportSheet(viewModel: viewModel, model: viewModel.steamWorkshopImportViewModel)
                    } else if viewModel.isDirectURLImportReveal {
                        DirectURLImportSheet(viewModel: viewModel, model: viewModel.directURLImportViewModel)
                    } else if viewModel.isCommandPaletteReveal {
                        CommandPaletteView(contentViewModel: viewModel)
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                // A single `.shadow(radius: 30)` (SwiftUI's default black-33%, no offset) reads as
                // a diffuse halo, not a floating panel. Two layered, downward-offset shadows plus a
                // native hairline edge give it actual directional depth — the "0 0 0 0.5px + soft
                // spread" combination the macOS design reference calls out as the defining look of
                // floating panels on this platform. `.separatorColor` rather than a hand-tuned
                // opacity — it's Apple's own semantic token for exactly this, already correct in
                // both light and dark and under increased-contrast accessibility settings.
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
                .shadow(color: .black.opacity(0.12), radius: 28, y: 14)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            // ⌘K quick-switcher trigger — a real keyboardShortcut on an otherwise-invisible button
            // rather than a global NSEvent monitor, so it's automatically scoped to this window and
            // suspended for free whenever a text field or another control wants the keystroke.
            // Guarded against opening while a different popup is already up — without this, ⌘K
            // while e.g. Display Settings is open silently flipped `isCommandPaletteReveal` to true
            // with nothing visibly happening (the Group's if/else-if chain shows whichever popup's
            // condition comes first), which reads as the shortcut just not working. Closing is
            // always allowed regardless of what else is showing.
            Button {
                if viewModel.isCommandPaletteReveal {
                    viewModel.isCommandPaletteReveal = false
                } else if !(viewModel.isDisplaySettingsReveal || viewModel.isClockSettingsReveal || viewModel.isPlaylistSettingsReveal
                            || viewModel.isEditWallpaperReveal || viewModel.isYouTubeImportReveal || viewModel.isSteamWorkshopImportReveal
                            || viewModel.isDirectURLImportReveal) {
                    viewModel.isCommandPaletteReveal = true
                }
            } label: { EmptyView() }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : AppMotion.popupTransition, value: viewModel.toastMessage)
        .animation(AppMotion.popupTransition, value: viewModel.isDisplaySettingsReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isClockSettingsReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isPlaylistSettingsReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isEditWallpaperReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isYouTubeImportReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isSteamWorkshopImportReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isDirectURLImportReveal)
        .animation(AppMotion.popupTransition, value: viewModel.isCommandPaletteReveal)
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
            guard !isPresented else { return }
            guard let url = viewModel.pendingDirectURLDownload else {
                // Sheet closed without a completed download (cancelled, or dismissed) — clear any
                // Inbox link association now rather than leaving it stuck, or a later, unrelated
                // Direct URL import would wrongly mark THIS cancelled link `.completed` (see
                // `cancelPendingSheetImport`'s own doc comment). A no-op if the sheet wasn't opened
                // from an Inbox link's Import button.
                AppDelegate.shared.inboxLinksStore.cancelPendingSheetImport()
                return
            }
            viewModel.pendingDirectURLDownload = nil
            // If this sheet was opened from an Inbox link's Import button, mark that row completed
            // — the only reliable "did this actually finish" signal, since the sheet can always be
            // cancelled instead. A no-op for every other way this sheet gets opened.
            AppDelegate.shared.inboxLinksStore.markSheetImportCompletedIfPending()
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

    /// Shared by the scrim's outside-click dismiss and Escape — whichever of these popups is
    /// actually open, this is a no-op for the rest, so calling all eight unconditionally is simpler
    /// than tracking which one is currently active.
    private func dismissAllPopups() {
        viewModel.isDisplaySettingsReveal = false
        viewModel.isClockSettingsReveal = false
        viewModel.isPlaylistSettingsReveal = false
        viewModel.isEditWallpaperReveal = false
        viewModel.isYouTubeImportReveal = false
        viewModel.isSteamWorkshopImportReveal = false
        viewModel.isDirectURLImportReveal = false
        viewModel.isCommandPaletteReveal = false
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: .init(), wallpaperViewModel: .init())
            .environmentObject(GlobalSettingsViewModel())
    }
}

/// True desktop-blurring vibrancy for the whole main window, dressed up with the cues that read as
/// "glass" rather than flat frosted blur: a specular rim light tracing the window edge (brightest
/// where a light source hitting curved glass would catch, per `Corner`) and a faint diagonal tint
/// for a sense of depth/volume. Only actually visible once the owning window has been made
/// non-opaque with a `.clear` background (`MainWindowController`/`AppDelegate.setSettingsWindow`) —
/// on a normal opaque window the blur layer would just render as a flat, undifferentiated fill.
struct WindowGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            VisualEffectMaterial()

            // Diffuser — `.behindWindow` blending composites against WHATEVER is actually behind
            // the window, not just the desktop picture: another app's window overlapping this one
            // shows through too, and `.sidebar` (chosen for being noticeably more translucent than
            // the semantically "correct" `.underWindowBackground`) let sharp edges/text from a
            // dark window behind Wallwright bleed through as a visible artifact. This trades back
            // a little of that vibrancy — still meaningfully more transparent than the original
            // `.underWindowBackground` — for not showing distracting fragments of unrelated windows.
            Color(nsColor: .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.35 : 0.20)
                .allowsHitTesting(false)

            // Depth wash — subtle enough to read as "glass has volume" without tinting content
            // legibility. Flips lighter-corner/darker-corner between themes so it still reads as
            // catching light from the same conceptual direction rather than looking inverted.
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.05), .clear, Color.black.opacity(0.16)]
                    : [Color.white.opacity(0.35), .clear, Color.black.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)

            // Refractive accent caustic — a whisper of the system accent color, as if light were
            // bending through the glass's own volume rather than just reflecting off its surface.
            // Kept low-opacity deliberately: this reads as tint, not as a colored overlay.
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.09 : 0.05), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 700
            )
            .allowsHitTesting(false)

            // Top meniscus glint — a hint of light at the top edge, not a bright stripe. Confirmed
            // live this needed to come down significantly from an earlier, much brighter pass.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.white.opacity(colorScheme == .dark ? 0.12 : 0.2), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1.5)
                Spacer()
            }
            .allowsHitTesting(false)

            // Specular rim — a continuous rounded corner (rather than a sharp `Rectangle`) is meant
            // to hug the window's own rounded chrome instead of fighting it at the corners, but that
            // only works if the radius actually approximates the real, OS-controlled physical
            // window-corner radius (~10-12pt) — this app's own internal corner-radius tier (see
            // `WallpaperPreview.swift`'s tier comment) is a DIFFERENT thing, for OUR OWN drawn
            // components, and doesn't apply here. Confirmed live: the earlier `cornerRadius: 20`
            // (reasoned from that tier instead) was measurably larger than the physical window
            // corner, so the stroke's curve cut inward and read as a separate inner white frame
            // instead of hugging the glass edge. Opacity also confirmed too strong at 0.6-0.85 —
            // a hairline whisper reads as a light-catching edge; that read as a wireframe outline.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.15 : 0.25),
                            Color.white.opacity(0.03),
                            .clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        }
    }
}

/// The raw `NSVisualEffectView` bridge `WindowGlassBackground` layers its specular/tint dressing
/// on top of.
private struct VisualEffectMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // `.sidebar`, not `.hudWindow` (a fixed-dark overlay style, e.g. Quick Look's panel — not
        // built to be a whole window's own light/dark-adaptive background) or `.underWindowBackground`
        // (Apple's own semantically-correct choice for "behind a window's content," but tuned heavy
        // and close to opaque specifically to guarantee text contrast — reads as flat matte plastic
        // rather than glass). `.sidebar` is noticeably more translucent/vibrant in practice (the
        // same material behind Finder's own sidebar), letting the desktop's actual color and motion
        // show through much more than the semantically "correct" choice did.
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // Not `.active` — that keeps compositing the live blur even while this window is in the
        // background behind some other app, continuously re-sampling whatever's behind it (for
        // Wallwright specifically, that can be its own actively-playing video wallpaper) for no
        // visible benefit, since the user isn't even looking at this window then.
        // `.followsWindowActiveState` only pays that cost while the window is actually key/frontmost.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
