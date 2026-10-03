//
//  WallperView.swift
//  Wallwright
//
//  Browse and import live wallpapers from wallper.app.
//

import SwiftUI

struct WallperView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var wallperVM: WallperViewModel
    @State private var loadMoreVisible = false

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self.wallperVM = viewModel.wallperViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            categoryPicker
            Divider()
            content
        }
        .onAppear {
            // Sync the (uncommitted) search box from whatever was last typed on another source,
            // as long as nothing has actually been submitted here yet. Used to only ever fill in
            // a blank box, so clearing the search on another tab never propagated here, a tab
            // that already had stale leftover text kept showing it forever.
            if wallperVM.committedSearchQuery.isEmpty, wallperVM.searchQuery != viewModel.lastBrowseSearchText {
                wallperVM.searchQuery = viewModel.lastBrowseSearchText
            }
            wallperVM.loadInitialIfNeeded()
        }
    }

    private var searchBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Wallper...", text: $wallperVM.searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { wallperVM.search() }
                        // Only saves the typed text for cross-tab pre-fill, does NOT call
                        // search() here, that used to filter the grid on every keystroke instead
                        // of waiting for Enter like every other browse source.
                        .onChange(of: wallperVM.searchQuery) { _, newValue in viewModel.lastBrowseSearchText = newValue }
                    if !wallperVM.searchQuery.isEmpty {
                        Button {
                            wallperVM.clearSearch()
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

                if !wallperVM.hiddenItemIDs.isEmpty {
                    Button {
                        wallperVM.unhideAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.slash")
                            Text("\(wallperVM.hiddenItemIDs.count)")
                        }
                    }
                    .buttonStyle(.glass)
                    .help("Unhide all previously hidden items")
                }
            }
            .controlSize(.regular)
        }
        .padding(10)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(WallperCategory.allCases) { category in
                        let isSelected = wallperVM.category == category
                        Button(category.displayName) {
                            wallperVM.setCategory(category)
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        // No `.tint(.accentColor)` — reads as a flat gray-white pill on the
                        // Graphite system accent instead of a translucent lens (same fix as the
                        // main window's other glass controls).
                        .glassEffect(isSelected ? .regular : .identity, in: Capsule())
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var content: some View {
        if wallperVM.isLoadingIndex && wallperVM.allItems.isEmpty {
            Spacer()
            ProgressView("Loading Wallper's catalog...")
            Spacer()
        } else if let error = wallperVM.errorMessage, wallperVM.allItems.isEmpty {
            BrowseStateView(icon: "wifi.exclamationmark", message: error) {
                Task { await wallperVM.loadIndex() }
            }
        } else if wallperVM.visibleItems.isEmpty {
            // "Everything here is hidden" implies the user did that themselves, only true when
            // this category genuinely has items and the hide list is what's filtering them all
            // out. A category with nothing in it at all (or a search with no matches) needs a
            // different message instead of blaming the hide feature for either of those.
            let categoryHasContent = wallperVM.allItems.contains {
                wallperVM.category == .all || $0.category == wallperVM.category.rawValue
            }
            BrowseStateView(
                icon: !wallperVM.committedSearchQuery.isEmpty ? "magnifyingglass" : (categoryHasContent ? "eye.slash" : "square.grid.2x2"),
                message: !wallperVM.committedSearchQuery.isEmpty
                    ? "No results for \"\(wallperVM.committedSearchQuery)\""
                    : (categoryHasContent ? "Everything here is hidden" : "No wallpapers found")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 18) {
                    ForEach(wallperVM.visibleItems) { item in
                        WallperItemCard(item: item, viewModel: wallperVM, downloadState: wallperVM.downloadState[item.id])
                            .modifier(LoadMoreTrigger(
                                isLast: item.id == wallperVM.visibleItems.last?.id,
                                visible: $loadMoreVisible,
                                canLoad: wallperVM.hasMore,
                                load: wallperVM.loadMore
                            ))
                    }
                }
                .padding()

                if wallperVM.hasMore {
                    Button("Load More") {
                        wallperVM.loadMore()
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

private struct WallperItemCard: View {
    let item: WallperItem
    // Not @ObservedObject — see MotionBgsItemCard's identical doc comment.
    let viewModel: WallperViewModel
    let downloadState: WallperViewModel.DownloadState?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RetryingAsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(16.0 / 9.0, contentMode: .fill)
                    case .failure:
                        Rectangle().fill(.quaternary).overlay {
                            Image(systemName: "photo").foregroundStyle(.tertiary)
                        }
                    default:
                        Rectangle().fill(.quaternary)
                    }
                }

            }
            .frame(height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            .overlay(alignment: .topTrailing) {
                Button {
                    viewModel.hide(item)
                } label: {
                    Image(systemName: "eye.slash.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(6)
                .opacity(isHovered ? 1 : 0)
                .help("Hide this wallpaper")
            }
            .onHover { hovering in
                isHovered = hovering
            }

            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .top)

            downloadControl
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.open(item.pageURL)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.pageURL.absoluteString, forType: .string)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch downloadState {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 3) {
                if let progress {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .importing:
            Label("Importing…", systemImage: "square.and.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .completed:
            Label("Added", systemImage: "checkmark.circle.fill")
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
                    viewModel.download(item: item)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
                .help("Retry download")
            }
        case nil:
            Button {
                viewModel.download(item: item)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
    }
}
