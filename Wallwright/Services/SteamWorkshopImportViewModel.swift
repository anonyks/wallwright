//
//  SteamWorkshopImportViewModel.swift
//  Wallwright
//
//  Same reasoning as YouTubeImportViewModel — moves the Steam Workshop import sheet's state off
//  the view (where closing the popup destroyed it) and onto a persistently-owned object, so the
//  steamcmd download keeps its visible progress across a dismiss/reopen.
//

import Foundation

@MainActor
final class SteamWorkshopImportViewModel: ObservableObject {
    enum Mode { case link, search }

    @Published var usernameField = ""
    @Published var mode: Mode = .link
    @Published var urlString = ""
    @Published var isFetchingPreview = false
    @Published var preview: SteamWorkshopPreview?
    @Published var isDownloading = false
    @Published var downloadStatusLine = ""
    @Published var downloadResult: SteamWorkshopResult?
    @Published var errorMessage: String?

    @Published var searchQuery = ""
    /// `nil` = no type filter ("All"). A non-nil value is the Steam tag ("Video"/"Scene") sent as
    /// `requiredtags[]` — the search-side equivalent of picking Video Sources vs Image Sources
    /// elsewhere in this app, since a "Scene" result commits as a static image the same way those
    /// sources' results do.
    @Published var typeFilter: String?
    /// Three-state per genre: in neither set (not filtered), in `includedGenreTags` (+, must
    /// have), or in `excludedGenreTags` (-, must not have) — mirrors Steam's own Genre filter
    /// chips, which cycle the same three states. A genre is never in both sets at once; toggling
    /// one side always clears the other first (see `cycleGenreTag`).
    @Published var includedGenreTags: Set<String> = []
    @Published var excludedGenreTags: Set<String> = []
    /// Same three-state shape as the Genre pair above, for `WorkshopTag.miscellaneousTags` — kept
    /// as its own pair of sets (not merged into the Genre ones) since Steam presents these as two
    /// visually separate filter sections, and this app's UI mirrors that.
    @Published var includedMiscTags: Set<String> = []
    @Published var excludedMiscTags: Set<String> = []
    @Published var searchResults: [SteamWorkshopSearchResult] = []
    @Published var isSearching = false
    @Published var searchErrorMessage: String?
    private var searchPage = 1
    /// Goes false once a page comes back empty — Steam's browse page has no total-count field to
    /// check against up front, so "the last page came back with nothing" is the only signal that
    /// there's nothing left to load.
    @Published var hasMoreSearchResults = true

    func reset() {
        usernameField = ""
        mode = .link
        urlString = ""
        isFetchingPreview = false
        preview = nil
        isDownloading = false
        downloadStatusLine = ""
        downloadResult = nil
        errorMessage = nil
        searchQuery = ""
        typeFilter = nil
        includedGenreTags = []
        excludedGenreTags = []
        includedMiscTags = []
        excludedMiscTags = []
        searchResults = []
        isSearching = false
        searchErrorMessage = nil
        searchPage = 1
        hasMoreSearchResults = true
    }

    /// `WorkshopTag.requiredCategoryTag`/`.requiredAgeRatingTag` are always included here, not
    /// user-togglable — see their own doc comments for why (excludes Preset/Asset results and
    /// anything outside "Everyone", unconditionally, on every search this view model ever runs).
    private var activeRequiredTags: [String] {
        let safeModeTags = AppDelegate.shared.globalSettingsViewModel.settings.steamWorkshopSafeMode
            ? [WorkshopTag.requiredCategoryTag, WorkshopTag.requiredAgeRatingTag] : []
        return (typeFilter.map { [$0] } ?? []) + safeModeTags + Array(includedGenreTags) + Array(includedMiscTags)
    }

    private var activeExcludedTags: [String] { Array(excludedGenreTags) + Array(excludedMiscTags) }

    private func cycleTag(_ tag: String, included: inout Set<String>, excluded: inout Set<String>) {
        if included.contains(tag) {
            included.remove(tag)
            excluded.insert(tag)
        } else if excluded.contains(tag) {
            excluded.remove(tag)
        } else {
            included.insert(tag)
        }
    }

    /// Cycles a Genre chip through Steam's own three states, same order its own +/- chips do:
    /// neutral → include (+) → exclude (-) → neutral. Shared by the small popup and the full-tab
    /// browse views' own genre chip rows so both stay in sync with the same underlying state.
    func cycleGenreTag(_ tag: String) { cycleTag(tag, included: &includedGenreTags, excluded: &excludedGenreTags) }

    /// Same cycling as `cycleGenreTag`, for the separate Miscellaneous chip set.
    func cycleMiscTag(_ tag: String) { cycleTag(tag, included: &includedMiscTags, excluded: &excludedMiscTags) }

    func fetchPreview() async {
        guard let itemId = SteamWorkshopService.extractItemId(from: urlString) else { return }
        errorMessage = nil
        preview = nil
        isFetchingPreview = true
        defer { isFetchingPreview = false }
        do {
            preview = try await SteamWorkshopService.fetchPreview(itemId: itemId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Guards against a stale response overwriting a newer one — bumped at the start of every
    /// `search()`/`loadMoreSearchResults()` call, captured locally, and checked before applying
    /// that call's result. Same shape as `MotionBgsViewModel.loadGeneration` (see its own comment
    /// for the exact race this prevents): tapping Genre/Misc chips quickly fires a `search()` per
    /// tap, and with no ordering guarantee between two in-flight HTTP requests, a later tap's
    /// response can arrive before an earlier tap's — without this, whichever lands last would win
    /// regardless of which tap it was actually answering.
    private var searchGeneration = 0

    /// Fresh search — replaces any existing results and resets paging, unlike `loadMoreSearchResults`.
    /// An empty query is valid here (falls back to Steam's own "Trending" sort — see
    /// `SteamWorkshopService.searchItems`'s own doc comment) so the full-tab browse views can call
    /// this on first appear and show something immediately, the same way every other browse source
    /// defaults to its own trending/newest listing before the user has typed anything.
    func search() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        searchErrorMessage = nil
        isSearching = true
        searchPage = 1
        hasMoreSearchResults = true
        // Only this call's own generation clears the spinner — an older, now-superseded call
        // finishing after a newer one has already started must not stop `isSearching` out from
        // under the newer call still genuinely in flight (confirmed live 2026-10-06: without this
        // guard, rapid chip-tapping could flash "No results" mid-search, and briefly let
        // `loadMoreSearchResults`'s own `!isSearching` check pass while a fresh search was still
        // running).
        defer { if generation == searchGeneration { isSearching = false } }
        do {
            let results = try await SteamWorkshopService.searchItems(query: trimmed, page: searchPage, requiredTags: activeRequiredTags, excludedTags: activeExcludedTags)
            guard generation == searchGeneration else { return }
            searchResults = results
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            searchErrorMessage = error.localizedDescription
        }
    }

    /// Appends the next page onto the existing results — used by the results list's own
    /// scroll-to-bottom trigger, same "load more by paging" shape `YtDlpService`/browse-tab sources
    /// already use elsewhere in this app, just without their continuous-auto-load debouncing (a
    /// Workshop search result set is small enough that a user-driven "load more" read is fine).
    func loadMoreSearchResults() async {
        guard !isSearching, hasMoreSearchResults else { return }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = searchGeneration
        isSearching = true
        // Same reasoning as `search()`'s own identical guard — only this call's own generation
        // clears the spinner.
        defer { if generation == searchGeneration { isSearching = false } }
        do {
            let next = try await SteamWorkshopService.searchItems(query: trimmed, page: searchPage + 1, requiredTags: activeRequiredTags, excludedTags: activeExcludedTags)
            // A fresh `search()` superseding this one already bumped the generation — its own
            // fresh page-1 results own `searchResults`/`searchPage` now, so appending this stale
            // page-2 response on top would corrupt state the new search already reset.
            guard generation == searchGeneration else { return }
            if next.isEmpty {
                hasMoreSearchResults = false
            } else {
                searchPage += 1
                searchResults.append(contentsOf: next)
            }
        } catch {
            guard generation == searchGeneration else { return }
            searchErrorMessage = error.localizedDescription
        }
    }

    /// Picking a search result drops straight into the exact same paste-a-link flow — sets
    /// `urlString` to the item's id (`extractItemId` already accepts a bare numeric id) and fetches
    /// its preview, so type validation/file size/everything downstream is unchanged.
    func selectSearchResult(_ result: SteamWorkshopSearchResult) async {
        mode = .link
        urlString = result.id
        await fetchPreview()
    }

    enum CardDownloadState: Equatable {
        case downloading(String)
        case importing
        /// Handed off to `ContentViewModel.pendingPackageImports` — the review sheet (title/tags,
        /// and a scene-art picker when there's more than one candidate) takes over from here, the
        /// same already-built flow the Link/Search popup's own "Continue to Title & Tags" step
        /// uses. Not the same thing as "added to the library" the way MotionBgs's `.completed`
        /// is — Steam's own project.json needs that review step first, same as it always has.
        case queuedForReview
        case failed(String)
    }
    /// Keyed by Workshop item id, for the full-tab browse views' own grid cards — separate from
    /// `isDownloading`/`downloadResult` above, which track the small Link/Search popup's single
    /// in-flight item instead of a whole grid of independently-downloadable cards.
    @Published var cardDownloadState: [String: CardDownloadState] = [:]

    /// One-click "download, then hand to the review queue" for a browse-view grid card — the full-
    /// tab equivalent of the popup's fetchPreview-then-Download two-step, collapsed into one
    /// action since the grid card already shows a thumbnail/title, same as every other source's
    /// card here already does before you click Download.
    func downloadForReview(_ result: SteamWorkshopSearchResult, username: String) async {
        switch cardDownloadState[result.id] {
        case .downloading, .importing: return
        default: break
        }
        cardDownloadState[result.id] = .downloading("")
        do {
            let downloaded = try await SteamWorkshopService.download(itemId: result.id, username: username) { [weak self] line in
                self?.cardDownloadState[result.id] = .downloading(line)
            }
            cardDownloadState[result.id] = .importing
            let pending = try await PackageImporter.preparePending(
                project: downloaded.project,
                directory: downloaded.contentDirectory,
                // `result.id` as a fallback — some real Workshop items' own project.json omits
                // `workshopid` entirely, which would otherwise silently drop this wallpaper's
                // source-ID tracking even though the real ID was known the whole time (it's
                // literally what was just downloaded).
                sourceId: downloaded.project.workshopid?.rawValue ?? result.id,
                sourceProvider: "steamworkshop"
            )
            AppDelegate.shared.contentViewModel.pendingPackageImports.append(pending)
            cardDownloadState[result.id] = .queuedForReview
        } catch {
            cardDownloadState[result.id] = .failed(error.localizedDescription)
        }
    }

    func startDownload(username: String) async {
        // Same fix as `YouTubeImportViewModel.startDownload`'s identical guard — a fast double-
        // trigger can queue two `Task`s before either one's own `isDownloading = true` below has
        // run, both believing no download is in progress.
        guard !isDownloading else { return }
        guard let itemId = SteamWorkshopService.extractItemId(from: urlString) else { return }
        errorMessage = nil
        downloadStatusLine = ""
        isDownloading = true
        defer { isDownloading = false }
        do {
            downloadResult = try await SteamWorkshopService.download(itemId: itemId, username: username) { [weak self] line in
                self?.downloadStatusLine = line
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
