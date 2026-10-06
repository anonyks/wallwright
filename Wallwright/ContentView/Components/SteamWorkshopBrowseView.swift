//
//  SteamWorkshopBrowseView.swift
//  Wallwright
//
//  The full-tab browsable-grid counterpart to SteamWorkshopImportSheet's own small Link/Search
//  popup — same search bar / tag chips / card grid / load-more shape every other source here
//  (MotionBgsView, MoeWallsView, ...) already uses, reached from a "WEVideo" row in the Video
//  Sources popover or a "WEScene" row in Image Sources, rather than its own permanent toolbar
//  icon — split the same way every other source already is, by what the result becomes once
//  downloaded (a Scene commits as a static image via SceneFallback, same as it always has).
//  `fixedType` is a hard lock, not a default — this tab shows only "Video" or only "Scene" results,
//  full stop, with no in-tab control to change it (confirmed live 2026-10-05: offering a visible,
//  changeable Type picker here was the wrong call — the whole point of two separate tabs is that
//  each one is strictly its own type, the same way MotionBgs's tab never shows AlphaCoders results).
//
//  Shares `ContentViewModel.steamWorkshopImportViewModel` with the popup rather than owning a
//  separate instance, so logging in once covers both; the tradeoff is that switching between the
//  WEVideo and WEScene tabs re-queries instead of caching each tab's own last results separately —
//  deliberately simple over fully independent per-tab state, given how cheap a re-search is here.
//

import SwiftUI

struct SteamWorkshopBrowseView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var steamVM: SteamWorkshopImportViewModel
    @ObservedObject private var globalSettingsViewModel = AppDelegate.shared.globalSettingsViewModel
    let fixedType: String
    @State private var loadMoreVisible = false

    init(contentViewModel viewModel: ContentViewModel, fixedType: String) {
        self.viewModel = viewModel
        self.steamVM = viewModel.steamWorkshopImportViewModel
        self.fixedType = fixedType
    }

    private var savedUsername: String? {
        let trimmed = globalSettingsViewModel.settings.steamUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if !SteamWorkshopService.isAvailable {
                BrowseStateView(icon: "exclamationmark.triangle.fill", message: "steamcmd isn't installed. Install it with Homebrew (brew install steamcmd), then reopen this tab.")
            } else if savedUsername == nil {
                loginSetupBanner
            } else {
                searchBar
                Divider()
                tagPicker
                Divider()
                content
            }
        }
        .onAppear {
            // Locked, not a default — WEVideo shows Video only, WEScene shows Scene only, full
            // stop, with no in-tab control to change it (confirmed live 2026-10-05: a visible,
            // changeable Type picker here was genuinely the wrong call, not just a rough edge —
            // the whole point of two separate tabs is that each one is strictly its own type).
            // Reset on every (re-)visit, not just the first, so a stale value from the *other* WE
            // tab (they share this one view model) or the small popup never leaks in here.
            let typeChanged = steamVM.typeFilter != fixedType
            steamVM.typeFilter = fixedType
            if steamVM.searchQuery.isEmpty, steamVM.searchQuery != viewModel.lastBrowseSearchText {
                steamVM.searchQuery = viewModel.lastBrowseSearchText
            }
            if typeChanged || steamVM.searchResults.isEmpty {
                Task { await steamVM.search() }
            }
        }
        // Without this, flipping Safe Mode in Settings and coming straight back to an
        // already-populated tab left stale results on screen — `.onAppear` above only re-searches
        // on a type change or empty results, neither of which a Safe Mode flip causes by itself.
        .onChange(of: globalSettingsViewModel.settings.steamWorkshopSafeMode) { _, _ in
            Task { await steamVM.search() }
        }
    }

    private var loginSetupBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("One-time setup needed.", systemImage: "person.badge.key.fill")
                .foregroundStyle(.orange)
            Text("In Terminal, log steamcmd into the Steam account that owns Wallpaper Engine — this caches the login locally (handles any Steam Guard code interactively) so this app never needs your password:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("steamcmd +login YOUR_STEAM_USERNAME +quit")
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Text("Once that succeeds, enter that same username here:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Steam username", text: $steamVM.usernameField)
                    .glassFieldStyle()
                Button("Save") {
                    let trimmed = steamVM.usernameField.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    globalSettingsViewModel.settings.steamUsername = trimmed
                }
                .disabled(steamVM.usernameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Workshop (\(fixedType))...", text: $steamVM.searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await steamVM.search() } }
                        .onChange(of: steamVM.searchQuery) { _, newValue in viewModel.lastBrowseSearchText = newValue }
                    if !steamVM.searchQuery.isEmpty {
                        Button {
                            steamVM.searchQuery = ""
                            Task { await steamVM.search() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear Search")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9))
            }
            .controlSize(.regular)
        }
        .padding(10)
    }

    /// Genre and Miscellaneous, Steam's own two facet names — tap cycles + (must have) → - (must
    /// not have) → neutral, the same three states Steam's own chips cycle through. Age Rating and
    /// Category aren't offered as chips here — they're governed by Settings > General > Steam
    /// Workshop > Safe Mode instead (see `WorkshopTag.requiredCategoryTag`/`.requiredAgeRatingTag`'s
    /// own doc comments), not a per-search choice.
    /// One combined scrollable row, not two stacked ones — Genre and Miscellaneous are still two
    /// separate underlying filters (separate include/exclude sets, separate `requiredtags[]`
    /// values), just not worth two full lines of vertical space to show as chips.
    private var tagPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(WorkshopTag.genreTags, id: \.self) { tag in
                        tagChip(tag, isIncluded: steamVM.includedGenreTags.contains(tag), isExcluded: steamVM.excludedGenreTags.contains(tag)) {
                            steamVM.cycleGenreTag(tag)
                            Task { await steamVM.search() }
                        }
                    }
                    ForEach(WorkshopTag.miscellaneousTags, id: \.self) { tag in
                        tagChip(tag, isIncluded: steamVM.includedMiscTags.contains(tag), isExcluded: steamVM.excludedMiscTags.contains(tag)) {
                            steamVM.cycleMiscTag(tag)
                            Task { await steamVM.search() }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    /// One filter chip (Genre or Miscellaneous), three visual states matching
    /// `SteamWorkshopImportViewModel`'s own three cycle states: a plain secondary-gray neutral
    /// chip, a green "+ tag" once included, an orange "- tag" once excluded — same colors Steam's
    /// own filter chips use.
    private func tagChip(_ tag: String, isIncluded: Bool, isExcluded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if isIncluded {
                    Image(systemName: "plus")
                } else if isExcluded {
                    Image(systemName: "minus")
                }
                Text(tag)
            }
            .font(.callout.weight(isIncluded || isExcluded ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isIncluded ? .green : (isExcluded ? .orange : .secondary))
        .glassEffect(isIncluded || isExcluded ? .regular : .identity, in: Capsule()) // no accentColor tint — reads gray on Graphite
    }

    @ViewBuilder
    private var content: some View {
        if steamVM.isSearching, steamVM.searchResults.isEmpty {
            Spacer()
            ProgressView("Searching Steam Workshop...")
            Spacer()
        } else if let error = steamVM.searchErrorMessage, steamVM.searchResults.isEmpty {
            BrowseStateView(icon: "wifi.exclamationmark", message: error) {
                Task { await steamVM.search() }
            }
        } else if steamVM.searchResults.isEmpty {
            BrowseStateView(
                icon: steamVM.searchQuery.isEmpty ? "square.grid.2x2" : "magnifyingglass",
                message: steamVM.searchQuery.isEmpty ? "No wallpapers found" : "No results for \"\(steamVM.searchQuery)\""
            )
        } else {
            ScrollView {
                // Fixed 3-across, not an adaptive column count — matches Steam's own Workshop
                // browse grid, and its thumbnails (square, confirmed live 2026-10-05) over the
                // 16:9 crop this used before, which let a vertical-biased thumbnail's subject get
                // cut off.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                    ForEach(steamVM.searchResults) { result in
                        SteamWorkshopResultCard(
                            result: result,
                            viewModel: steamVM,
                            downloadState: steamVM.cardDownloadState[result.id],
                            username: savedUsername
                        )
                        .modifier(LoadMoreTrigger(
                            isLast: result.id == steamVM.searchResults.last?.id,
                            visible: $loadMoreVisible,
                            canLoad: !steamVM.isSearching,
                            load: { Task { await steamVM.loadMoreSearchResults() } }
                        ))
                    }
                }
                .padding()

                if !steamVM.searchResults.isEmpty, steamVM.hasMoreSearchResults {
                    Button {
                        Task { await steamVM.loadMoreSearchResults() }
                    } label: {
                        if steamVM.isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load More")
                        }
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 20)
                    .disabled(steamVM.isSearching)
                }
            }
        }
    }
}

private struct SteamWorkshopResultCard: View {
    let result: SteamWorkshopSearchResult
    // Not @ObservedObject — same reasoning as MotionBgsItemCard: subscribing here would re-render
    // every visible card on any change to the view model at all. `downloadState` is the one piece
    // this card's body needs, read by the parent (which does observe) and passed down as a plain
    // value.
    let viewModel: SteamWorkshopImportViewModel
    let downloadState: SteamWorkshopImportViewModel.CardDownloadState?
    let username: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Square, not a fixed height — matches Steam's own Workshop thumbnails (confirmed live
            // 2026-10-05), and sizing off the card's own actual width (not a hardcoded height)
            // keeps it a true square at whatever width the 3-across grid gives each column at the
            // window's current size, rather than a fixed height mismatching a variable width.
            RetryingAsyncImage(url: result.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(1, contentMode: .fill)
                case .failure:
                    Rectangle().fill(.quaternary).overlay {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    }
                default:
                    Rectangle().fill(.quaternary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)

            Text(result.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .top)

            downloadControl
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(result.id)")!)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://steamcommunity.com/sharedfiles/filedetails/?id=\(result.id)", forType: .string)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch downloadState {
        case .downloading(let line):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView().controlSize(.small)
                if !line.isEmpty {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        case .importing:
            Label("Importing…", systemImage: "square.and.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .queuedForReview:
            Label("Ready to Review", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            HStack(spacing: 6) {
                Label(message, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    guard let username else { return }
                    Task { await viewModel.downloadForReview(result, username: username) }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
                .help("Retry download")
            }
        case nil:
            Button {
                guard let username else { return }
                Task { await viewModel.downloadForReview(result, username: username) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(username == nil)
        }
    }
}
