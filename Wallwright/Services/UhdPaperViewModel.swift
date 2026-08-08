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
        guard !query.isEmpty else { return }
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
        currentStartIndex += Self.pageSize
        Task {
            isLoading = true
            do {
                let nextItems = try await fetchCurrentPage()
                let existingIDs = Set(items.map(\.id))
                let newItems = nextItems.filter { !existingIDs.contains($0.id) }
                if newItems.isEmpty {
                    currentStartIndex -= Self.pageSize
                } else {
                    items.append(contentsOf: newItems)
                }
                markAlreadyDownloaded()
            } catch {
                // Silently stop paginating on failure (e.g. past the last page) rather than
                // surfacing an error for what's often just "no more pages".
                currentStartIndex -= Self.pageSize
            }
            isLoading = false
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
        let index = UhdPaperService.existingLibraryIndex()
        for item in items {
            if index.sourceIds.contains(item.id) || index.titles.contains(item.title.lowercased()) {
                downloadState[item.id] = .completed
            }
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
        guard downloadState[item.id] != .completed else { return }
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
