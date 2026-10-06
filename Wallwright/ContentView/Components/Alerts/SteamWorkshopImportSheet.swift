//
//  SteamWorkshopImportSheet.swift
//  Wallwright
//
//  Downloads a Wallpaper Engine Workshop item via steamcmd, then hands the result to the same
//  pendingPackageImports/PackageImportReviewSheet pipeline manual folder imports use — matching
//  YouTubeImportSheet's own "download here, review title/tags there" split.
//
//  steamcmd needs its own one-time login (outside this app, in Terminal) before anything here can
//  work — that's unavoidable: Workshop content for a paid app is locked to accounts that own it,
//  and this app will never handle a Steam password itself. Once that's done and the account's
//  username is saved below, every later download is just "paste a URL."
//
//  State lives on `model` (SteamWorkshopImportViewModel), not local `@State` — this is presented
//  as a click-outside-to-dismiss popup (see ContentView), not a modal `.sheet`, specifically so you
//  can dismiss it while steamcmd is running and come back to see where it's at.
//

import SwiftUI

struct SteamWorkshopImportSheet: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var model: SteamWorkshopImportViewModel
    @ObservedObject var globalSettingsViewModel = AppDelegate.shared.globalSettingsViewModel

    private var savedUsername: String? {
        let trimmed = globalSettingsViewModel.settings.steamUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PopupHeader(title: "Import from Steam Workshop") {
                viewModel.isSteamWorkshopImportReveal = false
            }

            if !SteamWorkshopService.isAvailable {
                notInstalledSetup
            } else if savedUsername == nil {
                oneTimeLoginSetup
            } else if let downloadResult = model.downloadResult {
                completedSummary(downloadResult)
            } else {
                downloadForm
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                if savedUsername != nil, model.downloadResult == nil, SteamWorkshopService.isAvailable {
                    Button("Change Account") {
                        globalSettingsViewModel.settings.steamUsername = nil
                    }
                    .disabled(model.isDownloading)
                    .font(.caption)
                }
                Spacer()
                Button(model.downloadResult != nil ? "Cancel" : "Close") {
                    // Same "declined, no reason to keep the download" reasoning as
                    // `ContentViewModel.skipCurrentPackageImport()` — deliberately unconditional,
                    // unlike `cleanupScratchSource`'s temp-directory guard, since this is Steam's
                    // own Workshop download rather than a throwaway scratch copy.
                    if let downloadResult = model.downloadResult {
                        try? FileManager.default.removeItem(at: downloadResult.contentDirectory)
                    }
                    viewModel.isSteamWorkshopImportReveal = false
                    model.reset()
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 540)
    }

    private var notInstalledSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("steamcmd isn't installed.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Install it with Homebrew, then reopen this:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("brew install steamcmd")
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// steamcmd needs a real, interactive login (password + Steam Guard code on first use) before
    /// this app can reuse it — that has to happen in Terminal, once, since this app never touches
    /// a Steam password. This just captures which cached account to tell steamcmd to reuse after.
    private var oneTimeLoginSetup: some View {
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
            Text("Once that succeeds, enter that same username here — every later import is then just pasting a Workshop URL:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Steam username", text: $model.usernameField)
                    .glassFieldStyle()
                Button("Save") {
                    let trimmed = model.usernameField.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    globalSettingsViewModel.settings.steamUsername = trimmed
                }
                .disabled(model.usernameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var downloadForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signed in as \(savedUsername ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Hidden once a link's already been fetched or a download is running — switching tabs
            // mid-flow would orphan whichever request is in progress for no benefit.
            if model.preview == nil, !model.isDownloading {
                Picker("", selection: $model.mode) {
                    Text("Link").tag(SteamWorkshopImportViewModel.Mode.link)
                    Text("Search").tag(SteamWorkshopImportViewModel.Mode.search)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if model.mode == .search, model.preview == nil, !model.isDownloading {
                searchForm
            } else {
                linkForm
            }
        }
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Workshop URL or item ID", text: $model.urlString)
                    .glassFieldStyle()
                    .disabled(model.isFetchingPreview || model.isDownloading)
                    .onSubmit { Task { await model.fetchPreview() } }
                    .onChange(of: model.urlString) { _, _ in model.preview = nil }
                Button("Fetch") { Task { await model.fetchPreview() } }
                    .disabled(SteamWorkshopService.extractItemId(from: model.urlString) == nil || model.isFetchingPreview || model.isDownloading)
            }

            if model.isFetchingPreview {
                ProgressView("Fetching item info…")
                    .frame(maxWidth: .infinity)
            } else if let preview = model.preview {
                VStack(alignment: .leading, spacing: 10) {
                    if let imageURL = preview.previewImageURL {
                        RetryingAsyncImage(url: imageURL) { phase in
                            if let image = phase.image {
                                // No fixed ratio — lets each item's own preview image dictate its
                                // height instead of letterboxing/cropping it into a fixed shape.
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                // Actual ratio isn't known until the image loads, so the
                                // placeholder just needs *a* reasonable guess for that instant.
                                Rectangle().fill(.quaternary).aspectRatio(4.0 / 3.0, contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Text(preview.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let fileSizeText = preview.fileSizeText {
                        Text(fileSizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if preview.isScene, let workshopType = preview.workshopType {
                        Label("This is a \"\(workshopType)\" wallpaper. Wallwright doesn't render live scenes, so it will be imported as a static wallpaper (Scene Preview).", systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if preview.isUnsupportedType, let workshopType = preview.workshopType {
                        Label("This is a \"\(workshopType)\" wallpaper. Wallwright only supports Video and Scene wallpapers, so downloading it will still use the full file size before failing to import.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if model.isDownloading {
                        ProgressView(model.downloadStatusLine.isEmpty ? "Starting steamcmd…" : model.downloadStatusLine)
                            .frame(maxWidth: .infinity)
                        Text("Keeps downloading if you close this.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Button("Download") {
                            guard let username = savedUsername else { return }
                            Task { await model.startDownload(username: username) }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }

    private var searchForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search Workshop (e.g. \"cat\", \"cyberpunk\")", text: $model.searchQuery)
                    .glassFieldStyle()
                    .disabled(model.isSearching)
                    .onSubmit { Task { await model.search() } }
                Button("Search") { Task { await model.search() } }
                    .disabled(model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSearching)
            }

            // Type, not a free-form tag: mirrors this app's own Video Sources/Image Sources split
            // (a "Scene" result commits as a static image, same as every Image Sources result).
            Picker("Type", selection: $model.typeFilter) {
                Text("All").tag(String?.none)
                Text("Video").tag(String?.some("Video"))
                Text("Scene").tag(String?.some("Scene"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Genre and Miscellaneous, Steam's own two facet names, as one combined scrollable row
            // rather than two stacked ones — still two separate underlying filters (separate
            // include/exclude sets, separate `requiredtags[]` values), just not worth two full
            // lines of vertical space in this already-small popup. Tap cycles + (must have) →
            // - (must not have) → neutral, the same three states Steam's own chips cycle through.
            // Age Rating and Category aren't offered as chips here — they're governed by
            // Settings > General > Steam Workshop > Safe Mode instead (see WorkshopTag's own doc
            // comments), not a per-search choice.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(WorkshopTag.genreTags, id: \.self) { tag in
                        genreChip(tag, isIncluded: model.includedGenreTags.contains(tag), isExcluded: model.excludedGenreTags.contains(tag)) {
                            model.cycleGenreTag(tag)
                        }
                    }
                    ForEach(WorkshopTag.miscellaneousTags, id: \.self) { tag in
                        genreChip(tag, isIncluded: model.includedMiscTags.contains(tag), isExcluded: model.excludedMiscTags.contains(tag)) {
                            model.cycleMiscTag(tag)
                        }
                    }
                }
            }
            // Re-runs the current search with the new filters applied — only once a search has
            // actually been performed; toggling filters before that would just be inert state.
            .onChange(of: model.typeFilter) { _, _ in if !model.searchResults.isEmpty || model.searchErrorMessage != nil { Task { await model.search() } } }
            .onChange(of: model.includedGenreTags) { _, _ in if !model.searchResults.isEmpty || model.searchErrorMessage != nil { Task { await model.search() } } }
            .onChange(of: model.excludedGenreTags) { _, _ in if !model.searchResults.isEmpty || model.searchErrorMessage != nil { Task { await model.search() } } }
            .onChange(of: model.includedMiscTags) { _, _ in if !model.searchResults.isEmpty || model.searchErrorMessage != nil { Task { await model.search() } } }
            .onChange(of: model.excludedMiscTags) { _, _ in if !model.searchResults.isEmpty || model.searchErrorMessage != nil { Task { await model.search() } } }
            // Same reactivity as the full-tab browse views — flipping Safe Mode in Settings while
            // this popup already has results showing shouldn't leave them stale.
            .onChange(of: globalSettingsViewModel.settings.steamWorkshopSafeMode) { _, _ in if !model.searchResults.isEmpty || model.searchErrorMessage != nil { Task { await model.search() } } }

            if let searchErrorMessage = model.searchErrorMessage {
                Text(searchErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if model.isSearching, model.searchResults.isEmpty {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            } else if model.searchResults.isEmpty, !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.searchErrorMessage == nil {
                Text("No results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            } else if !model.searchResults.isEmpty {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        ForEach(model.searchResults) { result in
                            Button {
                                Task { await model.selectSearchResult(result) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    RetryingAsyncImage(url: result.thumbnailURL) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        } else {
                                            Rectangle().fill(.quaternary)
                                        }
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Text(result.title)
                                        .font(.caption2)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if model.hasMoreSearchResults {
                        Button {
                            Task { await model.loadMoreSearchResults() }
                        } label: {
                            if model.isSearching {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Load More").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(model.isSearching)
                        .padding(.top, 10)
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    /// One filter chip (Genre or Miscellaneous), three visual states matching `model.cycleGenreTag`
    /// /`cycleMiscTag`'s three states: a plain secondary-gray neutral chip, a green "+ tag" once
    /// included, an orange "- tag" once excluded — same colors Steam's own filter chips use.
    private func genreChip(_ tag: String, isIncluded: Bool, isExcluded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if isIncluded {
                    Image(systemName: "plus")
                } else if isExcluded {
                    Image(systemName: "minus")
                }
                Text(tag)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isIncluded ? .green : (isExcluded ? .orange : .secondary))
        .glassEffect((isIncluded || isExcluded) ? .regular : .identity, in: Capsule()) // no accentColor tint — reads gray on Graphite
    }

    private func completedSummary(_ result: SteamWorkshopResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Download complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                summaryRow("Title", result.project.title)
                summaryRow("Type", result.project.type.capitalized)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            Button("Continue to Title & Tags") {
                viewModel.pendingSteamWorkshopDownload = result
                viewModel.isSteamWorkshopImportReveal = false
                model.reset()
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}
