//
//  UhdPaperViewModel.swift
//  Wallwright
//

import Foundation

@MainActor
final class UhdPaperViewModel: ObservableObject {
    enum DownloadState: Equatable {
        case downloading(Double?)
        case importing
        case completed
        case failed(String)
    }

    @Published var category: UhdPaperCategory = .latest
    @Published var items: [UhdPaperItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var downloadState: [String: DownloadState] = [:]

    @Published var searchQuery = ""
    @Published private(set) var isSearchActive = false
    @Published private(set) var hiddenItemIDs: Set<String>

    /// `items` with anything the user hid filtered out — what the grid should actually display.
    var visibleItems: [UhdPaperItem] { items.filter { !hiddenItemIDs.contains($0.id) } }

    /// Blogger feed pagination is offset-based (`start-index`), not page-numbered — starts at 1
    /// (Blogger's own convention, not 0-based) and advances by `pageSize` each "load more".
    private var currentStartIndex = 1
    private static let pageSize = 20
    /// Guards against a stale response overwriting a newer one — see MotionBgsViewModel's
    /// identical property doc comment for the exact mechanism and trigger.
    private var loadGeneration = 0
    private let service = UhdPaperService()
    private static let hiddenIDsKey = "UhdPaperHiddenItemIDs"

    init() {
        let saved = UserDefaults.standard.array(forKey: Self.hiddenIDsKey) as? [String] ?? []
        hiddenItemIDs = Set(saved)
    }

    func loadCategory(_ category: UhdPaperCategory) {
        guard category != self.category || items.isEmpty || isSearchActive else { return }
        self.category = category
        isSearchActive = false
        searchQuery = ""
        currentStartIndex = 1
        items = []
        Task { await load() }
    }

    func loadInitialIfNeeded() {
        guard items.isEmpty, !isLoading else { return }
        Task { await load() }
    }

    /// Runs a search — triggered on submit, not per-keystroke, so browsing doesn't hammer the site
    /// with a request per character typed.
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
        currentStartIndex = 1
        items = []
        Task { await load() }
    }

    func clearSearch() {
        guard isSearchActive else { return }
        isSearchActive = false
        searchQuery = ""
        currentStartIndex = 1
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
        currentStartIndex += Self.pageSize
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            isLoading = true
            do {
                let nextItems = try await fetchCurrentPage()
                guard generation == loadGeneration else { return }
                let existingIDs = Set(items.map(\.id))
                let newItems = nextItems.filter { !existingIDs.contains($0.id) }
                if newItems.isEmpty {
                    currentStartIndex -= Self.pageSize
                } else {
                    items.append(contentsOf: newItems)
                }
                markAlreadyDownloaded()
                isLoading = false
            } catch {
                guard generation == loadGeneration else { return }
                // Silently stop paginating on failure (e.g. past the last page) rather than
                // surfacing an error for what's often just "no more pages".
                currentStartIndex -= Self.pageSize
                isLoading = false
            }
        }
    }

    private func fetchCurrentPage() async throws -> [UhdPaperItem] {
        if isSearchActive {
            return try await service.searchItems(query: searchQuery, startIndex: currentStartIndex)
        }
        return try await service.fetchItems(category: category, startIndex: currentStartIndex)
    }

    /// Marks items already present in the library as `.completed` so the grid shows "Added"
    /// instead of "Download" for them, and `download(item:)` is never invoked for a duplicate.
    private func markAlreadyDownloaded() {
        // Reads the already-in-memory library instead of re-scanning disk — see
        // `MotionBgsViewModel.markAlreadyDownloaded()`'s identical fix and doc comment.
        let index = UhdPaperService.existingLibraryIndex(wallpapers: AppDelegate.shared.contentViewModel.wallpapers)
        for item in items where index.sourceIds.contains(item.id) || index.titles.contains(item.title.lowercased()) {
            downloadState[item.id] = .completed
        }
    }

    /// Hides an item from the grid going forward — persisted locally, purely a display filter.
    func hide(_ item: UhdPaperItem) {
        hiddenItemIDs.insert(item.id)
        UserDefaults.standard.set(Array(hiddenItemIDs), forKey: Self.hiddenIDsKey)
    }

    func unhideAll() {
        hiddenItemIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.hiddenIDsKey)
    }

    func download(item: UhdPaperItem) {
        // Only checking `!= .completed` let a double-click (or a second click before the button's
        // own state has visibly updated) pass straight through while a download/import was already
        // in flight for the same item — two concurrent `Task`s downloading and importing the same
        // source into two separate destinations, racing each other's progress reporting.
        switch downloadState[item.id] {
        case .downloading, .importing: return
        default: break
        }
        downloadState[item.id] = .downloading(nil)
        Task {
            do {
                let localURL = try await service.downloadImage(for: item) { [weak self] progress in
                    Task { @MainActor in self?.downloadState[item.id] = .downloading(progress) }
                }
                downloadState[item.id] = .importing
                let success = ImageImporter.importImageFile(
                    at: localURL,
                    title: item.title,
                    tags: item.tags,
                    sourceProvider: "uhdpaper",
                    sourceId: item.id
                )
                try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
                downloadState[item.id] = success ? .completed : .failed("Import failed")
            } catch {
                downloadState[item.id] = .failed(error.localizedDescription)
            }
        }
    }
}
