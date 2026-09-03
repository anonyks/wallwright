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
            // Pre-fill from whatever was last typed on another source's search bar, but only if
            // this source's own query is still blank — never clobber a query already set here.
            if wallperVM.searchQuery.isEmpty && !viewModel.lastBrowseSearchText.isEmpty {
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
                        .onChange(of: wallperVM.searchQuery) { _, newValue in
                            wallperVM.search()
                            // Saves the typed text (not a live search on other sources) so
                            // switching source pre-fills its search bar with the same query.
                            viewModel.lastBrowseSearchText = newValue
                        }
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
                        .glassEffect(isSelected ? .regular.tint(.accentColor) : .identity, in: Capsule())
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
            BrowseStateView(
                icon: wallperVM.searchQuery.isEmpty ? "eye.slash" : "magnifyingglass",
                message: wallperVM.searchQuery.isEmpty ? "Everything here is hidden" : "No results for \"\(wallperVM.searchQuery)\""
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
