//
//  WallperViewModel.swift
//  Wallwright
//
//  Unlike MotionBgs/MoeWalls (which fetch one listing page at a time from the server), Wallper's
//  whole catalog comes from one sitemap fetch — see WallperService's header comment. So this loads
//  the full index once, then category/search/pagination are all just cheap in-memory filtering
//  over `allItems`, no repeat network calls.
//

import Foundation

@MainActor
final class WallperViewModel: ObservableObject {
    enum DownloadState: Equatable {
        case downloading(Double?)
        case importing
        case completed
        case failed(String)
    }

    @Published var allItems: [WallperItem] = []
    @Published var isLoadingIndex = false
    @Published var errorMessage: String?
    @Published var downloadState: [String: DownloadState] = [:]

    @Published var category: WallperCategory = .all
    @Published var searchQuery = ""
    @Published private(set) var hiddenItemIDs: Set<String>

    /// How many of the filtered results are currently revealed — "Load More" just raises this,
    /// no network call needed since `allItems` already has everything.
    @Published private var visibleCount = 60
    private static let pageSize = 60

    private let service = WallperService()
    private static let hiddenIDsKey = "WallperHiddenItemIDs"

    init() {
        let saved = UserDefaults.standard.array(forKey: Self.hiddenIDsKey) as? [String] ?? []
        hiddenItemIDs = Set(saved)
    }

    private var matchingItems: [WallperItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allItems.filter { item in
            guard hiddenItemIDs.contains(item.id) == false else { return false }
            guard category == .all || item.category == category.rawValue else { return false }
            guard !query.isEmpty else { return true }
            return item.title.lowercased().contains(query)
        }
    }

    var visibleItems: [WallperItem] { Array(matchingItems.prefix(visibleCount)) }
    var hasMore: Bool { matchingItems.count > visibleCount }

    func loadInitialIfNeeded() {
        guard allItems.isEmpty, !isLoadingIndex else { return }
        Task { await loadIndex() }
    }

    func loadIndex() async {
        isLoadingIndex = true
        errorMessage = nil
        do {
            allItems = try await service.fetchIndex()
            markAlreadyDownloaded()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingIndex = false
    }

    func setCategory(_ category: WallperCategory) {
        guard category != self.category else { return }
        self.category = category
        visibleCount = Self.pageSize
    }

    func search() {
        visibleCount = Self.pageSize
    }

    func clearSearch() {
        guard !searchQuery.isEmpty else { return }
        searchQuery = ""
        visibleCount = Self.pageSize
    }

    func loadMore() {
        visibleCount += Self.pageSize
    }

    private func markAlreadyDownloaded() {
        // Full library scan+decode moved off the main thread — see MotionBgsViewModel's identical
        // fix and its doc comment for why (this ran synchronously on main after every page load,
        // category switch, and search).
        let currentItems = allItems
        DispatchQueue.global(qos: .utility).async {
            let index = WallperService.existingLibraryIndex()
            let matchedIds = currentItems
                .filter { index.sourceIds.contains($0.id) || index.titles.contains($0.title.lowercased()) }
                .map(\.id)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for id in matchedIds { self.downloadState[id] = .completed }
            }
        }
    }

    func hide(_ item: WallperItem) {
        hiddenItemIDs.insert(item.id)
        UserDefaults.standard.set(Array(hiddenItemIDs), forKey: Self.hiddenIDsKey)
    }

    func unhideAll() {
        hiddenItemIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.hiddenIDsKey)
    }

    func download(item: WallperItem) {
        guard downloadState[item.id] != .completed else { return }
        downloadState[item.id] = .downloading(nil)
        Task {
            do {
                let localURL = try await service.downloadVideo(for: item) { [weak self] progress in
                    Task { @MainActor in self?.downloadState[item.id] = .downloading(progress) }
                }
                downloadState[item.id] = .importing
                let success = await withCheckedContinuation { continuation in
                    VideoImporter.importVideoFile(
                        at: localURL,
                        title: item.title,
                        tags: [item.category],
                        sourceProvider: "wallper",
                        sourceId: item.id
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
