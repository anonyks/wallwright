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
    /// The "Most Popular" sort's time window — see `WorkshopTimeFrame`'s own doc comment for the
    /// confirmed-live `days` values and why "All Time" isn't offered. Unlike the "Approved" default
    /// (which deliberately reverts on every tab revisit — see `syncApprovedDefault`'s own doc
    /// comment), this is a plain preference, not reasserted on revisit, so it stays wherever the
    /// user leaves it for the rest of the session, same as `typeFilter`/`searchQuery` already do.
    @Published var timeFrame: WorkshopTimeFrame = .sixMonths
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
        timeFrame = .sixMonths
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
        syncApprovedDefault()
    }

    /// Seeds `WorkshopTag.requiredApprovedTag` ("Approved") into `includedMiscTags` by default —
    /// unconditional, not gated by Safe Mode (confirmed live 2026-10-13: the user wants curated
    /// results by default "whether safe mode or not"), but a real, ordinary, visible Misc chip the
    /// user is free to cycle to neutral or excluded for one visit, same spirit as the old Genre
    /// defaults this replaced. Also strips it out of `excludedMiscTags` so it's never seeded into
    /// both sets at once. Deliberately unconditional, called every time a browse surface appears,
    /// not just once per session — same reasoning as this file used to document on
    /// `syncGenreDefaultsToSafeMode` (removed 2026-10-13 along with the Tier-2 Genre defaults it
    /// synced): a manual override should only last for the current visit, not quietly become the
    /// new standing default. Call from every browse surface's own `.onAppear`, and from `reset()`
    /// for the small popup.
    func syncApprovedDefault() {
        includedMiscTags.insert(WorkshopTag.requiredApprovedTag)
        excludedMiscTags.remove(WorkshopTag.requiredApprovedTag)
    }

    /// `.requiredCategoryTag`/`.requiredAgeRatingTag` only while Safe Mode is on, not user-togglable
    /// either way — see their own doc comments for why (excludes Preset/Asset results and anything
    /// outside "Everyone", unconditionally, whenever Safe Mode is on). `includedGenreTags` is
    /// filtered against `WorkshopTag.safeModeExcludedGenres` while Safe Mode is on, same reasoning
    /// as `activeExcludedTags`'s own doc comment — the chip to include Girls/Guys isn't shown under
    /// Safe Mode, so the only way this set could contain either is a stale value from before Safe
    /// Mode was turned on, which must not reach Steam as a `requiredtags[]` directly contradicting
    /// `activeExcludedTags`'s own unconditional exclusion of the same genre. "Approved" flows in
    /// through `includedMiscTags` like any other Misc tag now — see `syncApprovedDefault`'s own
    /// doc comment for how it ends up there by default.
    private var activeRequiredTags: [String] {
        let safeModeOn = AppDelegate.shared.globalSettingsViewModel.settings.steamWorkshopSafeMode
        let safeModeTags = safeModeOn ? [WorkshopTag.requiredCategoryTag, WorkshopTag.requiredAgeRatingTag] : []
        let genreTags = safeModeOn ? includedGenreTags.subtracting(WorkshopTag.safeModeExcludedGenres) : includedGenreTags
        return (typeFilter.map { [$0] } ?? []) + safeModeTags + Array(genreTags) + Array(includedMiscTags)
    }

    /// A single, combined, reordered chip list for the views — "Approved" and "Unspecified" pinned
    /// first (confirmed live 2026-10-13), then every other Genre tag Safe Mode allows showing (see
    /// `visibleGenreTags`), then every other Misc tag, each in their own original order. Letting the
    /// views render one `ForEach` over this instead of two separate Genre/Misc loops is what makes
    /// pinning tags from two different underlying lists to the front of one visual row possible;
    /// `isGenreTag`/`isTagIncluded`/`isTagExcluded`/`cycleTag(_:)` below dispatch each entry to the
    /// right underlying set without the view needing to know which list a given tag came from.
    var orderedTagChips: [String] {
        let pinned = [WorkshopTag.requiredApprovedTag, "Unspecified"]
        let restGenres = visibleGenreTags.filter { !pinned.contains($0) }
        let restMisc = WorkshopTag.miscellaneousTags.filter { !pinned.contains($0) }
        return pinned.filter { visibleGenreTags.contains($0) || WorkshopTag.miscellaneousTags.contains($0) } + restGenres + restMisc
    }

    /// Whether `tag` belongs to the Genre facet (vs. Miscellaneous) — lets `orderedTagChips`'s
    /// consumers dispatch a single merged list back to the correct underlying include/exclude pair.
    func isGenreTag(_ tag: String) -> Bool { WorkshopTag.genreTags.contains(tag) }

    func isTagIncluded(_ tag: String) -> Bool {
        isGenreTag(tag) ? includedGenreTags.contains(tag) : includedMiscTags.contains(tag)
    }

    func isTagExcluded(_ tag: String) -> Bool {
        isGenreTag(tag) ? excludedGenreTags.contains(tag) : excludedMiscTags.contains(tag)
    }

    /// Dispatches to `cycleGenreTag`/`cycleMiscTag` based on which facet `tag` belongs to — the
    /// single entry point `orderedTagChips`'s merged rendering needs.
    func cycleTag(_ tag: String) {
        if isGenreTag(tag) { cycleGenreTag(tag) } else { cycleMiscTag(tag) }
    }

    /// `WorkshopTag.genreTags` with `WorkshopTag.safeModeExcludedGenres` removed whenever Safe Mode
    /// is on — Girls/Guys don't just default to excluded, they're not offered as a choice at all
    /// under Safe Mode, the same way Age Rating/Category never get their own chips either (see
    /// `tagPicker`'s own doc comment). Confirmed live 2026-10-10: showing them as a toggleable
    /// "- Girls" / "- Guys" chip the user could tap back to neutral or "+" undercut what Safe Mode
    /// is supposed to mean. Turning Safe Mode off brings both back as plain, neutral genre chips,
    /// same as any other.
    var visibleGenreTags: [String] {
        AppDelegate.shared.globalSettingsViewModel.settings.steamWorkshopSafeMode
            ? WorkshopTag.genreTags.filter { !WorkshopTag.safeModeExcludedGenres.contains($0) }
            : WorkshopTag.genreTags
    }

    /// `excludedGenreTags` plus `WorkshopTag.safeModeExcludedGenres` whenever Safe Mode is on — the
    /// actual search request still has to exclude Girls/Guys itself; `visibleGenreTags` only
    /// controls whether the chip is shown, not whether Steam is actually asked to exclude them.
    /// Unconditional (not `.subtracting(includedGenreTags)` the way an earlier version of this did)
    /// — with the chip hidden under Safe Mode, there's no live way to have explicitly included
    /// either genre in the first place, so the only way `includedGenreTags` could contain one is a
    /// stale value from before Safe Mode was turned on, which shouldn't silently keep it included
    /// now that the chip explaining why is gone.
    private var activeExcludedTags: [String] {
        let safeModeExclusions = AppDelegate.shared.globalSettingsViewModel.settings.steamWorkshopSafeMode
            ? WorkshopTag.safeModeExcludedGenres : []
        return Array(excludedGenreTags.union(safeModeExclusions)) + Array(excludedMiscTags)
    }

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
            let results = try await SteamWorkshopService.searchItems(query: trimmed, page: searchPage, days: timeFrame.rawValue, requiredTags: activeRequiredTags, excludedTags: activeExcludedTags)
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
            let next = try await SteamWorkshopService.searchItems(query: trimmed, page: searchPage + 1, days: timeFrame.rawValue, requiredTags: activeRequiredTags, excludedTags: activeExcludedTags)
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
