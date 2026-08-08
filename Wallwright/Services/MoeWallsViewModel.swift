//
//  MoeWallsViewModel.swift
//  Wallwright
//

import Foundation

@MainActor
final class MoeWallsViewModel: ObservableObject {
    enum DownloadState: Equatable {
        case downloading(Double?)
        case importing
        case completed
        case failed(String)
    }

    @Published var category: MoeWallsCategory = .trending
    @Published var items: [MoeWallsItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var downloadState: [Int: DownloadState] = [:]

    @Published var searchQuery = ""
    @Published private(set) var isSearchActive = false
    @Published private(set) var hiddenItemIDs: Set<Int>

    /// `items` with anything the user hid filtered out — what the grid should actually display.
    var visibleItems: [MoeWallsItem] { items.filter { !hiddenItemIDs.contains($0.id) } }

    private var currentPage = 1
    private let service = MoeWallsService()
    private static let hiddenIDsKey = "MoeWallsHiddenItemIDs"

    init() {
        let saved = UserDefaults.standard.array(forKey: Self.hiddenIDsKey) as? [Int] ?? []
        hiddenItemIDs = Set(saved)
    }

    func loadCategory(_ category: MoeWallsCategory) {
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

    /// Runs a search — triggered on submit, not per-keystroke, so browsing doesn't hammer the site
    /// with a request per character typed.
    func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
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
        isLoading = true
        errorMessage = nil
        do {
            items = try await fetchCurrentPage()
            markAlreadyDownloaded()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadNextPage() {
        guard !isLoading else { return }
        currentPage += 1
        Task {
            isLoading = true
            do {
                let nextItems = try await fetchCurrentPage()
                let existingIDs = Set(items.map(\.id))
                let newItems = nextItems.filter { !existingIDs.contains($0.id) }
                if newItems.isEmpty {
                    currentPage -= 1
                } else {
                    items.append(contentsOf: newItems)
                }
                markAlreadyDownloaded()
            } catch {
                // Silently stop paginating on failure (e.g. past the last page) rather than
                // surfacing an error for what's often just "no more pages".
                currentPage -= 1
            }
            isLoading = false
        }
    }

    private func fetchCurrentPage() async throws -> [MoeWallsItem] {
        if isSearchActive {
            return try await service.searchItems(query: searchQuery, page: currentPage)
        }
        return try await service.fetchItems(category: category, page: currentPage)
    }

    /// Marks items already present in the library as `.completed` so the grid shows "Added"
    /// instead of "Download" for them, and `download(item:)` is never invoked for a duplicate.
    private func markAlreadyDownloaded() {
        let index = MoeWallsService.existingLibraryIndex()
        for item in items {
            if index.sourceIds.contains(item.id) || index.titles.contains(item.title.lowercased()) {
                downloadState[item.id] = .completed
            }
        }
    }

    /// Hides an item from the grid going forward — persisted locally, purely a display filter.
    func hide(_ item: MoeWallsItem) {
        hiddenItemIDs.insert(item.id)
        UserDefaults.standard.set(Array(hiddenItemIDs), forKey: Self.hiddenIDsKey)
    }

    func unhideAll() {
        hiddenItemIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.hiddenIDsKey)
    }

    func download(item: MoeWallsItem) {
        guard downloadState[item.id] != .completed else { return }
        downloadState[item.id] = .downloading(nil)
        Task {
            do {
                let (localURL, tags) = try await service.downloadVideo(for: item) { [weak self] progress in
                    Task { @MainActor in self?.downloadState[item.id] = .downloading(progress) }
                }
                downloadState[item.id] = .importing
                let success = await withCheckedContinuation { continuation in
                    VideoImporter.importVideoFile(
                        at: localURL,
                        title: item.title,
                        tags: tags,
                        sourceProvider: "moewalls",
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
