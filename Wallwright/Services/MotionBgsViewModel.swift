//
//  MotionBgsViewModel.swift
//  Wallwright
//

import Foundation

@MainActor
final class MotionBgsViewModel: ObservableObject {
    enum DownloadState: Equatable {
        case downloading(Double?)
        case importing
        case completed
        case failed(String)
    }

    @Published var category: MotionBgsCategory = .trending
    @Published var items: [MotionBgsItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var downloadState: [Int: DownloadState] = [:]

    @Published var searchQuery = ""
    @Published private(set) var isSearchActive = false
    @Published private(set) var hiddenItemIDs: Set<Int>

    /// "hd" (1920x1080, ~2MB) or "4k" (3840x2160, ~17MB) — both confirmed real, separate
    /// downloads on motionbgs.com. Defaults to 4K since that's the actual wallpaper resolution
    /// most people want; HD exists as the faster/smaller option.
    @Published var downloadQuality = "4k"

    /// `items` with anything the user hid filtered out — what the grid should actually display.
    var visibleItems: [MotionBgsItem] { items.filter { !hiddenItemIDs.contains($0.id) } }

    private var currentPage = 1
    /// Guards against a stale response overwriting a newer one — bumped at the start of every
    /// `load()`/`loadNextPage()` call, captured locally, and checked before applying that call's
    /// result. Without this, clicking category A then quickly clicking category B before A's
    /// response returns could let A's (now-stale) result land after B's and silently show A's
    /// items under B's selected tab — a real race confirmed via code trace (2026-09-02), triggered
    /// by ordinary fast clicking, not a contrived worst case.
    private var loadGeneration = 0
    private let service = MotionBgsService()
    private static let hiddenIDsKey = "MotionBgsHiddenItemIDs"

    init() {
        let saved = UserDefaults.standard.array(forKey: Self.hiddenIDsKey) as? [Int] ?? []
        hiddenItemIDs = Set(saved)
    }

    func loadCategory(_ category: MotionBgsCategory) {
        guard category != self.category || items.isEmpty || isSearchActive else { return }
        self.category = category
        isSearchActive = false
        searchQuery = ""
        currentPage = 1
        items = []
        Task { await load() }
    }

    func loadInitialIfNeeded() {
        guard items.isEmpty, !isLoading else { return }
        Task { await load() }
    }

    /// Runs a search — confirmed live against motionbgs.com's own `/search?q=` endpoint, same
    /// result markup as category pages. Deliberately triggered on submit, not per-keystroke, so
    /// browsing doesn't hammer the site with a request per character typed.
    func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // Submitting an empty query used to silently no-op, leaving stale search results on
        // screen with no way back to normal browsing short of clicking the X button. Erasing the
        // text and pressing Enter should behave the same as clearing it.
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        isSearchActive = true
        currentPage = 1
        items = []
        Task { await load() }
    }

    func clearSearch() {
        guard isSearchActive else { return }
        isSearchActive = false
        searchQuery = ""
        currentPage = 1
        items = []
        Task { await load() }
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await fetchCurrentPage()
            // Superseded by a newer load/loadNextPage while this one was in flight — its result
            // is stale, so leave `items`/`isLoading` alone entirely and let the newer call own them.
            guard generation == loadGeneration else { return }
            items = fetched
            markAlreadyDownloaded()
            isLoading = false
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func loadNextPage() {
        guard !isLoading else { return }
        currentPage += 1
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            isLoading = true
            do {
                let nextItems = try await fetchCurrentPage()
                guard generation == loadGeneration else { return }
                // motionbgs.com's search endpoint doesn't paginate once results run out — it just
                // returns the same first-page results again instead of an empty set (confirmed
                // live: /search?q=...&page=2 == page=1 for a query with fewer than a page of
                // results). Category pages don't do this, but de-duping defensively either way
                // avoids feeding SwiftUI's per-id ForEach duplicate identifiers.
                let existingIDs = Set(items.map(\.id))
                let newItems = nextItems.filter { !existingIDs.contains($0.id) }
                if newItems.isEmpty {
                    currentPage -= 1
                } else {
                    items.append(contentsOf: newItems)
                }
                markAlreadyDownloaded()
                isLoading = false
            } catch {
                guard generation == loadGeneration else { return }
                // Silently stop paginating on failure (e.g. past the last page) rather than
                // surfacing an error for what's often just "no more pages".
                currentPage -= 1
                isLoading = false
            }
        }
    }

    private func fetchCurrentPage() async throws -> [MotionBgsItem] {
        if isSearchActive {
            return try await service.searchItems(query: searchQuery, page: currentPage)
        }
        return try await service.fetchItems(category: category, page: currentPage)
    }

    /// Marks items already present in the library as `.completed` so the grid shows "Added"
    /// instead of "Download" for them, and `download(item:)` is never invoked for a duplicate.
    /// Matches by source ID when available, falling back to title for wallpapers downloaded
    /// before source-ID tracking existed.
    private func markAlreadyDownloaded() {
        // `existingLibraryIndex()` used to re-scan `wallpapersDirectory` and re-decode every
        // wallpaper's `project.json` from disk, synchronously on the main thread, after every
        // single page load, category switch, and search (`load()`/`loadNextPage()` above both call
        // this), scaling with library size on every one of those. It now reads the same data out of
        // `ContentViewModel.wallpapers` — already decoded, already in RAM — so this is cheap enough
        // to run inline on the main actor with no dispatch at all.
        let index = MotionBgsService.existingLibraryIndex(wallpapers: AppDelegate.shared.contentViewModel.wallpapers)
        for item in items where index.sourceIds.contains(item.id) || index.titles.contains(item.title.lowercased()) {
            downloadState[item.id] = .completed
        }
    }

    /// Hides an item from the grid going forward (e.g. "not interested in this") — persisted
    /// locally, purely a display filter, doesn't affect the site or anyone else's results.
    func hide(_ item: MotionBgsItem) {
        hiddenItemIDs.insert(item.id)
        UserDefaults.standard.set(Array(hiddenItemIDs), forKey: Self.hiddenIDsKey)
    }

    func unhideAll() {
        hiddenItemIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.hiddenIDsKey)
    }

    func download(item: MotionBgsItem, quality: String) {
        guard downloadState[item.id] != .completed else { return }
        downloadState[item.id] = .downloading(nil)
        Task {
            do {
                // motionbgs.com doesn't expose per-item quality availability in the listing, and
                // not every item has a 4K encode — requesting "4k" for one of those 500s. Fall
                // back to "hd" once rather than surfacing a dead-end error for something the user
                // didn't do wrong.
                let onProgress: (Double?) -> Void = { [weak self] progress in
                    Task { @MainActor in self?.downloadState[item.id] = .downloading(progress) }
                }
                let localURL: URL
                let tags: [String]?
                do {
                    async let videoDownload = service.downloadVideo(id: item.id, quality: quality, onProgress: onProgress)
                    async let tagsFetch: [String]? = try? service.fetchTags(slug: item.slug)
                    localURL = try await videoDownload
                    tags = await tagsFetch
                } catch let error as MotionBgsError {
                    if case .httpError = error, quality != "hd" {
                        async let videoDownload = service.downloadVideo(id: item.id, quality: "hd", onProgress: onProgress)
                        async let tagsFetch: [String]? = try? service.fetchTags(slug: item.slug)
                        localURL = try await videoDownload
                        tags = await tagsFetch
                    } else {
                        throw error
                    }
                }
                downloadState[item.id] = .importing
                let success = await withCheckedContinuation { continuation in
                    VideoImporter.importVideoFile(
                        at: localURL,
                        title: item.title,
                        tags: tags,
                        sourceProvider: "motionbgs",
                        sourceId: String(item.id)
                    ) { success in
                        continuation.resume(returning: success)
                    }
                }
                try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
                downloadState[item.id] = success ? .completed : .failed("Import failed")
            } catch {
                downloadState[item.id] = .failed(error.localizedDescription)
            }
        }
    }
}
