//
//  MoeWallsView.swift
//  Wallwright
//
//  Browse and import live wallpapers from moewalls.com.
//

import SwiftUI

struct MoeWallsView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var moeWallsVM: MoeWallsViewModel
    @State private var loadMoreVisible = false

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self.moeWallsVM = viewModel.moeWallsViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !moeWallsVM.isSearchActive {
                Divider()
                categoryPicker
            }
            Divider()
            content
        }
        .onAppear {
            // Pre-fill from whatever was last typed on another source's search bar, but
            // only if this source's own query is still blank — never clobber an
            // in-progress search already running on this tab.
            if moeWallsVM.searchQuery.isEmpty && !viewModel.lastBrowseSearchText.isEmpty {
                moeWallsVM.searchQuery = viewModel.lastBrowseSearchText
            }
            moeWallsVM.loadInitialIfNeeded()
        }
    }

    private var searchBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search MoeWalls...", text: $moeWallsVM.searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { moeWallsVM.search() }
                        // Saves the typed text (not a live search) to ContentViewModel so
                        // switching to a different source pre-fills its search bar with the
                        // same query instead of starting blank.
                        .onChange(of: moeWallsVM.searchQuery) { _, newValue in viewModel.lastBrowseSearchText = newValue }
                    if !moeWallsVM.searchQuery.isEmpty {
                        Button {
                            moeWallsVM.clearSearch()
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

                if !moeWallsVM.hiddenItemIDs.isEmpty {
                    Button {
                        moeWallsVM.unhideAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.slash")
                            Text("\(moeWallsVM.hiddenItemIDs.count)")
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
                    ForEach(MoeWallsCategory.allCases) { category in
                        let isSelected = moeWallsVM.category == category
                        Button(category.displayName) {
                            moeWallsVM.loadCategory(category)
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(isSelected ? .regular.tint(.accentColor) : .identity, in: Capsule())
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var content: some View {
        if moeWallsVM.isLoading && moeWallsVM.items.isEmpty {
            Spacer()
            ProgressView(moeWallsVM.isSearchActive ? "Searching MoeWalls..." : "Loading from MoeWalls...")
            Spacer()
        } else if let error = moeWallsVM.errorMessage, moeWallsVM.items.isEmpty {
            BrowseStateView(icon: "wifi.exclamationmark", message: error) {
                Task { await moeWallsVM.load() }
            }
        } else if moeWallsVM.visibleItems.isEmpty {
            BrowseStateView(
                icon: moeWallsVM.isSearchActive ? "magnifyingglass" : "eye.slash",
                message: moeWallsVM.isSearchActive ? "No results for \"\(moeWallsVM.searchQuery)\"" : "Everything here is hidden"
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 18) {
                    ForEach(moeWallsVM.visibleItems) { item in
                        MoeWallsItemCard(item: item, viewModel: moeWallsVM, downloadState: moeWallsVM.downloadState[item.id])
                            .modifier(LoadMoreTrigger(
                                isLast: item.id == moeWallsVM.visibleItems.last?.id,
                                visible: $loadMoreVisible,
                                canLoad: !moeWallsVM.isLoading,
                                load: moeWallsVM.loadNextPage
                            ))
                    }
                }
                .padding()

                if !moeWallsVM.items.isEmpty {
                    Button {
                        moeWallsVM.loadNextPage()
                    } label: {
                        if moeWallsVM.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load More")
                        }
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 20)
                    .disabled(moeWallsVM.isLoading)
                }
            }
        }
    }
}

private struct MoeWallsItemCard: View {
    let item: MoeWallsItem
    // Not @ObservedObject — see MotionBgsItemCard's identical doc comment: subscribing here would
    // re-render every visible card on any change to `viewModel` at all, not just this item's own
    // download state.
    let viewModel: MoeWallsViewModel
    let downloadState: MoeWallsViewModel.DownloadState?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                NSWorkspace.shared.open(item.detailURL)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.detailURL.absoluteString, forType: .string)
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
