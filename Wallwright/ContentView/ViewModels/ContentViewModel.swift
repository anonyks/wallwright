//
//  ContentViewModel.swift
//  Wallwright
//
//  Created by Haren on 2023/8/15.
//

import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

class ContentViewModel: ObservableObject, DropDelegate {
    /// Refreshes `wallpapers` (the disk-backed cache — see its doc comment) whenever anything
    /// actually changes the wallpapers directory, instead of the grid re-scanning disk and
    /// re-decoding every project.json on every unrelated UI change (hover, search keystroke,
    /// icon-size slider, ...). See `VideoImporter.wallpaperLibraryDidChangeNotification`.
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: VideoImporter.wallpaperLibraryDidChangeNotification)
            .receive(on: DispatchQueue.main)
            // Some call sites post this once per file in a loop (e.g. ImportPanels.swift's zip
            // import, one notification per selected zip) — without this, importing several files
            // at once triggers a full disk rescan (re-decoding every project.json) once per file
            // instead of once for the whole batch. Short enough that a single normal import still
            // feels instant; same debounce pattern already used for the Clock settings slider below.
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // `searchText` itself stays undebounced — the TextField binds directly to it, so typing
        // feels instant. `debouncedSearchText` (what `searchedWallpapers` actually filters on) only
        // updates 300ms after typing settles — confirmed live (2026-08-31) that without this, every
        // single keystroke re-filtered the whole library (`wallpapers.filter` over every field of
        // every wallpaper) and re-rendered the entire grid, visibly stuttering while typing.
        $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] text in self?.debouncedSearchText = text }
            .store(in: &cancellables)

        refresh()
    }

    @AppStorage("SortingBy") var sortingBy: WEWallpaperSortingMethod = .name
    @AppStorage("SortingSequence") var sortingSequence: WEWallpaperSortingSequence = .increase
    
    /// Tags currently checked in the Filter sidebar — populated dynamically from whatever tags
    /// exist across the installed library, not a fixed set. Empty means no filter (show everything).
    @Published var selectedTagFilters: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "SelectedTagFilters") ?? []) {
        didSet { UserDefaults.standard.set(Array(selectedTagFilters), forKey: "SelectedTagFilters") }
    }

    /// When true, only wallpapers with `project.hasAudio == true` show in the grid.
    @Published var audioOnlyFilter: Bool = UserDefaults.standard.bool(forKey: "AudioOnlyFilter") {
        didSet { UserDefaults.standard.set(audioOnlyFilter, forKey: "AudioOnlyFilter") }
    }

    /// When true, only wallpapers with `project.type == "image"` show in the grid — the static
    /// counterpart to `audioOnlyFilter`, same idea, opposite media kind.
    @Published var staticOnlyFilter: Bool = UserDefaults.standard.bool(forKey: "StaticOnlyFilter") {
        didSet { UserDefaults.standard.set(staticOnlyFilter, forKey: "StaticOnlyFilter") }
    }

    @Published var topTabBarSelection: Int = 0

    @AppStorage("FilterReveal") var isFilterReveal = false
    @AppStorage("SelectedIndex") var selectedIndex = 0
    
    @AppStorage("ExplorerIconSize") var explorerIconSize: Double = 200
    
    @Published var isDisplaySettingsReveal = false
    @Published var isClockSettingsReveal = false
    @Published var isPlaylistSettingsReveal = false
    /// Which wallpaper `EditWallpaperSheet` is showing — reuses `hoveredWallpaper` (already the
    /// "which item is this destructive/edit action about" slot used by the Remove confirmation
    /// below) rather than adding a second near-identical property.
    @Published var isEditWallpaperReveal = false
    @Published var isYouTubeImportReveal = false
    /// Set right before dismissing the YouTube sheet, consumed in `ContentView`'s `onDismiss` for
    /// that sheet — enqueuing straight after `isYouTubeImportReveal = false` (rather than waiting
    /// for the dismiss to actually finish) races SwiftUI's own sheet-dismiss animation on macOS:
    /// presenting the review sheet while the YouTube one is still animating out silently no-ops,
    /// so `pendingImports` ends up populated but nothing ever appears on screen to commit it.
    @Published var pendingYouTubeDownload: URL?
    @Published var isSteamWorkshopImportReveal = false
    /// Same hand-off pattern as `pendingYouTubeDownload` — set right before dismissing the Steam
    /// sheet, consumed in `ContentView`'s `onDismiss` for that sheet, to sidestep the same
    /// sequential-sheet-presentation race.
    @Published var pendingSteamWorkshopDownload: SteamWorkshopResult?
    @Published var isDirectURLImportReveal = false
    /// Same hand-off pattern as `pendingYouTubeDownload`.
    @Published var pendingDirectURLDownload: URL?
    @Published var importAlertPresented = false

    /// ⌘K quick-switcher — jump to any source/action or fuzzy-find a library wallpaper without
    /// leaving the keyboard. Pure UI over data already in memory (`wallpapers`, the fixed nav
    /// list), no I/O of its own.
    @Published var isCommandPaletteReveal = false

    /// A brief, optimistic "Applied" confirmation after picking a wallpaper — the grid's own accent
    /// ring already confirms this, but only if that card happens to still be on screen. Fires at
    /// the moment the user's pick is registered (not from inside the actual apply pipeline), so
    /// this stays pure UI feedback with zero risk to wallpaper-setting behavior itself.
    @Published var toastMessage: String?
    private var toastDismissTask: Task<Void, Never>?

    /// Animation is applied at the call site (`ContentView`), not baked in here — a view model has
    /// no `\.accessibilityReduceMotion` to check, and the call site already owns that decision for
    /// every other transition in this app.
    func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    @Published var imageScaleIndex: Int = -1
    
    /// Loaded from disk explicitly via `refresh()` — scanning the wallpapers directory and
    /// decoding every project.json is real I/O that shouldn't happen just because e.g. hover
    /// state changed. `refresh()` is called once at startup and again whenever
    /// `VideoImporter.wallpaperLibraryDidChangeNotification` fires (posted by every code path
    /// that actually adds/removes/edits a wallpaper on disk).
    @Published var wallpapers = [WEWallpaper]()
    
    
    @Published var hoveredWallpaper: WEWallpaper?
    
    @Published var isRemoveConfirming = false

    @Published var selectedWallpapers = Set<URL>()
    @Published var isBatchRemoveConfirming = false

    @Published var searchText = ""
    /// What `searchedWallpapers` actually filters on — see `init`'s debounce pipeline.
    @Published private var debouncedSearchText = ""

    /// The last text typed into any *browse source's* search bar (AlphaCoders, MoeWalls, etc — not
    /// the library search above) — carried over so switching from one source to another pre-fills
    /// its search bar with the same text instead of starting blank. Deliberately just the typed
    /// text, not a live/shared search: each source still only actually searches when its own
    /// `search()` runs, so switching tabs never fires a request on your behalf, it just saves you
    /// retyping the same query if you want to run it again on the new source.
    @Published var lastBrowseSearchText = ""

    @AppStorage("WallpapersPerPage") var wallpapersPerPage: Int = 50
    
    var importAlertError: WPImportError? = nil

    /// Owned here rather than as a `@StateObject` inside `MotionBgsView` — that view is
    /// conditionally removed from the hierarchy by the top-tab `switch`, so a `@StateObject`
    /// there gets torn down and recreated every time you leave and come back to the MotionBgs
    /// tab, orphaning any in-flight download's UI state (the download itself keeps running in
    /// the background, but the next attempt at the same item then collides with it on write).
    /// `ContentViewModel` lives for the whole app session, so this survives tab switches.
    let motionBgsViewModel = MotionBgsViewModel()

    /// Same reasoning as `motionBgsViewModel` above.
    let moeWallsViewModel = MoeWallsViewModel()

    /// Same reasoning as `motionBgsViewModel` above — owned here, not as local `@State` on the
    /// import sheet views, so dismissing the popup mid-download (now possible; see
    /// `isYouTubeImportReveal`/`isSteamWorkshopImportReveal`'s presentation in ContentView) doesn't
    /// destroy the in-flight progress. Reopening the popup just re-shows whatever's still running.
    let youTubeImportViewModel = YouTubeImportViewModel()
    let steamWorkshopImportViewModel = SteamWorkshopImportViewModel()
    let directURLImportViewModel = DirectURLImportViewModel()
    let wallperViewModel = WallperViewModel()
    let desktopHutViewModel = DesktopHutViewModel()
    let uhdPaperViewModel = UhdPaperViewModel()
    let alphaCodersViewModel = AlphaCodersViewModel()

    /// The `topTabBarSelection` tag of whichever source currently has an active download, if any —
    /// lets each Sources button jump straight back to it instead of re-showing its picker. `nil`
    /// when nothing is downloading anywhere. Checked in this fixed priority order purely so the
    /// result is deterministic if more than one source happens to be downloading at once.
    var activeDownloadSourceTag: Int? {
        if alphaCodersViewModel.downloadState.values.contains(where: Self.isActiveDownload) { return 6 }
        if uhdPaperViewModel.downloadState.values.contains(where: Self.isActiveDownload) { return 5 }
        if desktopHutViewModel.downloadState.values.contains(where: Self.isActiveDownload) { return 4 }
        if wallperViewModel.downloadState.values.contains(where: Self.isActiveDownload) { return 3 }
        if moeWallsViewModel.downloadState.values.contains(where: Self.isActiveDownload) { return 2 }
        if motionBgsViewModel.downloadState.values.contains(where: Self.isActiveDownload) { return 1 }
        return nil
    }

    private static func isActiveDownload(_ state: AlphaCodersViewModel.DownloadState) -> Bool {
        switch state {
        case .downloading, .importing: return true
        case .completed, .failed: return false
        }
    }

    private static func isActiveDownload(_ state: UhdPaperViewModel.DownloadState) -> Bool {
        switch state {
        case .downloading, .importing: return true
        case .completed, .failed: return false
        }
    }

    private static func isActiveDownload(_ state: DesktopHutViewModel.DownloadState) -> Bool {
        switch state {
        case .downloading, .importing: return true
        case .completed, .failed: return false
        }
    }

    private static func isActiveDownload(_ state: WallperViewModel.DownloadState) -> Bool {
        switch state {
        case .downloading, .importing: return true
        case .completed, .failed: return false
        }
    }

    private static func isActiveDownload(_ state: MoeWallsViewModel.DownloadState) -> Bool {
        switch state {
        case .downloading, .importing: return true
        case .completed, .failed: return false
        }
    }

    private static func isActiveDownload(_ state: MotionBgsViewModel.DownloadState) -> Bool {
        switch state {
        case .downloading, .importing: return true
        case .completed, .failed: return false
        }
    }

    /// Manual video imports (Open Wallpaper panel, drag-and-drop) awaiting review — the sheet
    /// shows `pendingImports.first`, letting the user fix the filename-derived title and add tags
    /// before anything is actually written into the wallpapers directory. Queued rather than
    /// imported one at a time so multi-file selections/drops still get reviewed individually.
    @Published var pendingImports: [PendingVideoImport] = []

    /// Set while `prepareImport` is converting a video that wasn't natively playable — lets the
    /// UI show real feedback instead of appearing to hang for however long that conversion takes.
    @Published var isImporting = false

    func enqueueImports(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        for url in urls {
            do {
                let pending = try await VideoImporter.prepareImport(at: url)
                pendingImports.append(pending)
            } catch {
                // Surfaced per-file rather than silently dropped — a silently-dropped import
                // (thumbnail generation failing on an incompatible codec with no error shown)
                // was exactly the bug behind the earlier YouTube-import "nothing happens" issue.
                alertImportModal(which: WPImportError(
                    errorDescription: "Couldn't Import \(url.lastPathComponent)",
                    failureReason: error.localizedDescription,
                    helpAnchor: "",
                    recoverySuggestion: ""
                ))
            }
        }
    }

    /// `VideoTranscoder`/`DirectURLImporter` write their output into a per-import scratch
    /// directory under `NSTemporaryDirectory()` — neither `commitImport` (which only *reads* that
    /// file to copy it into the wallpapers directory) nor the skip path ever cleaned it up
    /// afterward, so every transcoded/downloaded import left its scratch copy sitting in `/tmp`
    /// indefinitely (confirmed live: a natively-compatible import's `sourceURL` just points at the
    /// user's own original file, which this must NOT touch — hence the temp-directory prefix
    /// check, not an unconditional delete). Removes the whole per-import scratch folder, not just
    /// the one file, since each import gets its own uniquely-named directory.
    private func cleanupScratchSource(_ url: URL) {
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func commitCurrentImport(title: String, tags: [String]) {
        guard !pendingImports.isEmpty else { return }
        var pending = pendingImports.removeFirst()
        pending.title = title
        pending.tags = tags
        // Commit reads `pending.sourceURL` (to copy it into the wallpapers directory) — clean up
        // only after that read is done, whether it succeeded or not, never before.
        let committed = VideoImporter.commitImport(pending)
        cleanupScratchSource(pending.sourceURL)
        if !committed {
            alertImportModal(which: .unkown)
        }
    }

    /// Steam Workshop downloads (and any other pre-formed package import) awaiting review — mirrors
    /// `pendingImports` but for `PendingPackageImport`, since those commit via `PackageImporter`
    /// (a folder copy + project.json rewrite) rather than `VideoImporter`'s bare-file wrap.
    @Published var pendingPackageImports: [PendingPackageImport] = []

    func enqueuePackageImport(directory: URL, project: WEProject, sourceId: String?) {
        do {
            let pending = try PackageImporter.preparePending(project: project, directory: directory, sourceId: sourceId)
            pendingPackageImports.append(pending)
        } catch {
            alertImportModal(which: WPImportError(
                errorDescription: "Couldn't Import \(project.title)",
                failureReason: error.localizedDescription,
                helpAnchor: "",
                recoverySuggestion: ""
            ))
        }
    }

    func commitCurrentPackageImport(title: String, tags: [String]) {
        guard !pendingPackageImports.isEmpty else { return }
        var pending = pendingPackageImports.removeFirst()
        pending.title = title
        pending.tags = tags
        if !PackageImporter.commitImport(pending, sourceProvider: "steamworkshop") {
            alertImportModal(which: .unkown)
        }
    }

    func skipCurrentPackageImport() {
        guard !pendingPackageImports.isEmpty else { return }
        let pending = pendingPackageImports.removeFirst()
        // Unlike `commitImport` (which deliberately leaves Steam's own Workshop cache alone, in
        // case the user re-imports the same item later), skipping means the user explicitly
        // declined this one — there's no reason left to keep its full download around. Confirmed
        // live: this was previously the single largest storage leak in the app, since every
        // Workshop item is a full video wallpaper (commonly 50-500MB+) and this path did nothing.
        try? FileManager.default.removeItem(at: pending.sourceDirectory)
    }

    func skipCurrentImport() {
        guard !pendingImports.isEmpty else { return }
        cleanupScratchSource(pendingImports.removeFirst().sourceURL)
    }

    /// Manual image imports (Open Wallpaper panel, drag-and-drop) awaiting review — mirrors
    /// `pendingImports`/`enqueueImports`/`commitCurrentImport`/`skipCurrentImport` exactly, just
    /// backed by `ImageImporter`/`PendingImageImport` instead of `VideoImporter`.
    @Published var pendingImageImports: [PendingImageImport] = []

    func enqueueImageImports(_ urls: [URL]) async {
        for url in urls {
            do {
                // Off the main actor — `prepareImport`'s decode is already efficient (see
                // ThumbnailDownsampler's own doc comment, confirmed via `vmmap`: decode-at-size,
                // never a full-resolution bitmap), but it's still real synchronous CPU work, and
                // this function runs on `@MainActor` with no `await` before this call — so
                // whatever time it does take blocks the main thread regardless of how memory-
                // efficient the decode itself is. Same fix as `RetryingAsyncImage`'s remote
                // thumbnail decode elsewhere this session.
                let pending = try await Task.detached(priority: .userInitiated) {
                    try ImageImporter.prepareImport(at: url)
                }.value
                pendingImageImports.append(pending)
            } catch {
                alertImportModal(which: WPImportError(
                    errorDescription: "Couldn't Import \(url.lastPathComponent)",
                    failureReason: error.localizedDescription,
                    helpAnchor: "",
                    recoverySuggestion: ""
                ))
            }
        }
    }

    func commitCurrentImageImport(title: String, tags: [String]) {
        guard !pendingImageImports.isEmpty else { return }
        var pending = pendingImageImports.removeFirst()
        pending.title = title
        pending.tags = tags
        let committed = ImageImporter.commitImport(pending)
        cleanupScratchSource(pending.sourceURL)
        if !committed {
            alertImportModal(which: .unkown)
        }
    }

    func skipCurrentImageImport() {
        guard !pendingImageImports.isEmpty else { return }
        cleanupScratchSource(pendingImageImports.removeFirst().sourceURL)
    }

    /// current page index number is starting from '1' — clamped against `maxPage` inside
    /// `autoRefreshWallpapers`, not here (that needs the filtered/sorted count, which isn't
    /// available yet this early in the file).
    @Published public var currentPage: Int = 1


    private var urls: [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.wallpapersDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return contents
    }
    
    private var searchedWallpapers: [WEWallpaper] {
        wallpapers.filter { wallpaper in
            let project = wallpaper.project
            let searchText = debouncedSearchText.lowercased()

            guard !searchText.isEmpty else { return true }
            
            guard !project.title.lowercased().contains(searchText) else { return true }
            
            guard !project.type.lowercased().contains(searchText) else { return true }
            
            if let description = project.description?.lowercased() {
                guard !description.contains(searchText) else { return true }
            }
            
            if let tags = project.tags {
                guard !tags.allSatisfy({ $0.lowercased().contains(searchText) })
                else { return true }
            }
            
            if let workshopid = project.workshopid {
                guard !workshopid.rawValue.contains(searchText) else { return true }
            }
            
            guard !wallpaper.wallpaperDirectory.lastPathComponent
                .lowercased()
                .contains(searchText) else { return true }
            
            return false
        }
    }
    
    /// Every unique tag currently used by an installed wallpaper, sorted for stable display order.
    var availableTags: [String] {
        Set(wallpapers.compactMap(\.project.tags).flatMap { $0 }).sorted()
    }

    private var filteredWallpapers: [WEWallpaper] {
        searchedWallpapers.filter { wallpaper in
            if audioOnlyFilter, wallpaper.project.hasAudio != true { return false }
            if staticOnlyFilter, wallpaper.project.type.lowercased() != "image" { return false }
            guard !selectedTagFilters.isEmpty else { return true }
            guard let tags = wallpaper.project.tags else { return false }
            return !Set(tags).isDisjoint(with: selectedTagFilters)
        }
    }
    
    /// Sorting by file size or estimated impact used to call `wallpaperSize`/
    /// `WallpaperImpactEstimator.estimate` fresh from inside the `sorted(by:)` comparator itself —
    /// meaning every one of a sort's O(n log n) comparisons recomputed both sides from scratch, up
    /// to several hundred calls for a modest-sized library. `wallpaperSize` falls back to a live
    /// recursive directory walk for any wallpaper imported before `packageSizeBytes` existed (see
    /// `refresh()`'s backfill below) — confirmed live (2026-08-04) this is exactly what made
    /// switching back to the Installed tab (which re-evaluates this computed property from
    /// scratch every time, since the tab switch tears down and recreates the whole view) take
    /// 3-5 seconds with "Estimated Impact" as the active sort. Precomputing each wallpaper's
    /// expensive value exactly once before sorting — the standard decorate/sort/undecorate
    /// pattern — turns that into O(n) calls regardless of comparator cost.
    private var sortedWallpapers: [WEWallpaper] {
        let items = filteredWallpapers
        switch sortingBy {
        case .name:
            return items.sorted {
                if $0.project.title <= $1.project.title, sortingSequence == .increase { return false }
                if $0.project.title >= $1.project.title, sortingSequence == .decrease { return false }
                return true
            }
        case .fileSize:
            let sizes = Dictionary(uniqueKeysWithValues: items.map { ($0.wallpaperDirectory, $0.wallpaperSize) })
            return items.sorted {
                let lhs = sizes[$0.wallpaperDirectory] ?? 0
                let rhs = sizes[$1.wallpaperDirectory] ?? 0
                if lhs <= rhs, sortingSequence == .increase { return false }
                if lhs >= rhs, sortingSequence == .decrease { return false }
                return true
            }
        case .estimatedImpact:
            let impacts = Dictionary(uniqueKeysWithValues: items.map {
                ($0.wallpaperDirectory, WallpaperImpactEstimator.estimate(for: $0).rawValue)
            })
            return items.sorted {
                let lhs = impacts[$0.wallpaperDirectory] ?? 0
                let rhs = impacts[$1.wallpaperDirectory] ?? 0
                if lhs <= rhs, sortingSequence == .increase { return false }
                if lhs >= rhs, sortingSequence == .decrease { return false }
                return true
            }
        case .recentlyAdded:
            return items.sorted {
                let lhsDate = $0.dateAdded ?? .distantPast
                let rhsDate = $1.dateAdded ?? .distantPast
                if lhsDate <= rhsDate, sortingSequence == .increase { return false }
                if lhsDate >= rhsDate, sortingSequence == .decrease { return false }
                return true
            }
        }
    }
    
    /// Provide wallpapers information for UI, being filtered by FilterResults and divided in pages
    public var autoRefreshWallpapers: [WEWallpaper] {
        let filtered = sortedWallpapers
        guard wallpapersPerPage > 0 else { return filtered }
        let pageCount = max(1, (filtered.count + wallpapersPerPage - 1) / wallpapersPerPage)
        let page = min(max(currentPage, 1), pageCount)
        // Snaps back onto a real page (e.g. after a search/filter shrinks the result set below
        // wherever the user had paged to) — deferred to the next runloop tick since mutating
        // @Published state directly inside a computed property SwiftUI's already evaluating for
        // this render would trigger a "modifying state during view update" warning.
        if page != currentPage {
            DispatchQueue.main.async { self.currentPage = page }
        }
        let startIndex = (page - 1) * wallpapersPerPage
        let endIndex = min(startIndex + wallpapersPerPage, filtered.count)
        guard startIndex < endIndex else { return [] }
        return Array(filtered[startIndex..<endIndex])
    }

    /// Caculates the maximium possible page index for all wallpapers in your application wallpaper directory.
    /// Ceiling division — was integer division before, which silently hid the last page whenever
    /// the count wasn't an exact multiple of `wallpapersPerPage` (e.g. 55 items showed as 1 page,
    /// stranding the last 5 with no page 2 to reach them).
    var maxPage: Int {
        guard wallpapersPerPage > 0 else { return 1 }
        return max(1, (filteredWallpapers.count + wallpapersPerPage - 1) / wallpapersPerPage)
    }

    /// Total wallpapers matching the current search/filters — independent of pagination, so it
    /// doesn't flicker between page sizes while the underlying matched set stays the same.
    var visibleWallpaperCount: Int { filteredWallpapers.count }
    
    func toggleSelection(for wallpaper: WEWallpaper) {
        let url = wallpaper.wallpaperDirectory
        if selectedWallpapers.contains(url) {
            selectedWallpapers.remove(url)
        } else {
            selectedWallpapers.insert(url)
        }
    }

    func clearSelection() {
        selectedWallpapers.removeAll()
    }

    func isSelected(_ wallpaper: WEWallpaper) -> Bool {
        selectedWallpapers.contains(wallpaper.wallpaperDirectory)
    }

    func selectedWallpaperItems() -> [WEWallpaper] {
        autoRefreshWallpapers.filter { selectedWallpapers.contains($0.wallpaperDirectory) }
    }

    func alertImportModal(which error: WPImportError) {
        self.importAlertError = error
        self.importAlertPresented = true
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposal = DropProposal(operation: .copy)
        return proposal
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let itemProvider = info.itemProviders(for: [UTType.fileURL]).first
        else {
            alertImportModal(which: .unkown)
            return false
        }
        itemProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil)
            else {
                self?.alertImportModal(which: .unkown)
                return
            }
            // Do something with the file url
            // remember to dispatch on main in case of a @State change
            guard let wallpaper = try? FileWrapper(url: url)
            else{
                self?.alertImportModal(which: .unkown)
                return
            }
            
            if wallpaper.isDirectory {
                guard wallpaper.fileWrappers?["project.json"] != nil
                else{
                    self?.alertImportModal(which: .doesNotContainWallpaper)
                    return
                }
                DispatchQueue.main.async {
                    try? FileManager.default.copyItem(
                        at: url,
                        to: FileManager.default.wallpapersDirectory
                            .appending(path: url.lastPathComponent)
                    )
                    self?.refresh()
                }
            } else if wallpaper.isRegularFile, url.pathExtension.lowercased() == "zip" {
                // Off-main — `ZipImporter.importZip` shells out to `ditto` and blocks on
                // `waitUntilExit()`, which can take a long time for a large archive. Running that
                // on the main thread froze the whole app (unresponsive window, no way to cancel)
                // for as long as extraction took. `notifyLibraryChanged()` inside `importZip` is
                // safe to post from here — `ContentViewModel`'s own subscriber already hops to
                // main via `.receive(on: DispatchQueue.main)`.
                DispatchQueue.global(qos: .userInitiated).async {
                    let count = ZipImporter.importZip(at: url)
                    DispatchQueue.main.async {
                        if count == 0 {
                            self?.alertImportModal(which: .doesNotContainWallpaper)
                        }
                    }
                }
            } else if wallpaper.isRegularFile, VideoImporter.importableExtensions.contains(url.pathExtension.lowercased()) {
                Task { @MainActor in
                    await self?.enqueueImports([url])
                }
            } else if wallpaper.isRegularFile, ImageImporter.importableExtensions.contains(url.pathExtension.lowercased()) {
                Task { @MainActor in
                    await self?.enqueueImageImports([url])
                }
            }
        }
        return true
    }
    
    /// Re-scans the wallpapers directory and re-decodes every project.json — the one place that
    /// actually touches disk. Call this (or let `VideoImporter.wallpaperLibraryDidChangeNotification`
    /// trigger it) after anything that adds/removes/edits a wallpaper; everything else
    /// (search/filter/sort) reads the cached `wallpapers` array and stays cheap.
    ///
    /// The actual scan/decode runs off-main — confirmed live (2026-08-31) this was blocking the
    /// main thread on every delete/trash/edit (everyday library actions, not just app launch),
    /// since it re-reads and re-decodes `project.json` for the WHOLE library synchronously, plus a
    /// recursive directory-size walk and a disk write for any wallpaper still missing
    /// `packageSizeBytes`. Every call site already treats this as fire-and-forget (nothing reads
    /// `wallpapers` in the same call stack right after calling this), so hopping to a background
    /// queue and back is safe.
    /// Updates a single entry in `wallpapers` in place from an already-known-correct in-memory
    /// value — used by title/tag edits (`WallpaperPreview`, `EditWallpaperSheet`) instead of a
    /// full `refresh()`. Those edits update `wallpaper.project` directly (no disk round-trip
    /// needed to know the new value), then separately dispatch the actual `project.json` write to
    /// a background queue for durability. Calling `refresh()` there raced that write: its
    /// background directory scan could reach this exact file before the edit's own write landed,
    /// reading back the pre-edit content and silently reverting the just-made edit — confirmed via
    /// code trace (2026-09-02), not yet hit live, but a real, reachable race, not hypothetical.
    /// This avoids the disk read entirely, so there's nothing left to race.
    public func updateWallpaperInPlace(_ wallpaper: WEWallpaper) {
        guard let index = wallpapers.firstIndex(where: { $0.wallpaperDirectory.isSameWallpaperDirectory(as: wallpaper.wallpaperDirectory) }) else { return }
        wallpapers[index] = wallpaper
    }

    public func refresh() {
        let urls = self.urls
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = urls.compactMap { url -> WEWallpaper? in
                guard let data = try? Data(contentsOf: url.appending(path: "project.json")),
                      var project = try? JSONDecoder().decode(WEProject.self, from: data)
                else {
                    return WEWallpaper(using: .invalid, where: url)
                }
                // Only video/image are supported for rendering — a folder of some other type that
                // ended up here some other way than the app's own import paths (all of which
                // already reject unsupported types) would otherwise show up in the grid with a
                // normal-looking thumbnail and then render blank the moment it's selected.
                // Excluding it here instead of importing it broken.
                guard project.isSupportedType else { return nil }
                // Wallpapers imported before `packageSizeBytes` existed fall back, every time
                // `wallpaperSize` is read, to a live recursive directory walk — cheap once, but
                // confirmed live (2026-08-04) that repeating it inside a sort comparator (fixed
                // separately in `sortedWallpapers`) made switching tabs take several seconds.
                // Backfilling it here, the one place this class already touches disk on every
                // library load, means it only ever needs to happen once per wallpaper, same
                // pattern as `VideoImporter.backfillMetadataIfNeeded`.
                if project.packageSizeBytes == nil,
                   let sizeBytes = try? url.directoryTotalAllocatedSize(includingSubfolders: true) {
                    project.packageSizeBytes = Int64(sizeBytes)
                    if let updatedData = try? JSONEncoder().encode(project) {
                        try? updatedData.write(to: url.appending(path: "project.json"), options: .atomic)
                    }
                }
                return WEWallpaper(using: project, where: url)
            }
            DispatchQueue.main.async {
                self?.wallpapers = scanned
            }
        }
    }
    
    /// Provide a filter reset to default function, usually being used to show all wallpapers without filtered
    public func reset() {
        self.selectedTagFilters = []
        self.audioOnlyFilter = false
        self.staticOnlyFilter = false
    }
}
