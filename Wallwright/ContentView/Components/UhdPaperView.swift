//
//  UhdPaperView.swift
//  Wallwright
//
//  Browse and import still wallpapers from uhdpaper.com.
//

import SwiftUI

struct UhdPaperView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var uhdPaperVM: UhdPaperViewModel
    @State private var loadMoreVisible = false

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self.uhdPaperVM = viewModel.uhdPaperViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !uhdPaperVM.isSearchActive {
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
            if uhdPaperVM.searchQuery.isEmpty && !viewModel.lastBrowseSearchText.isEmpty {
                uhdPaperVM.searchQuery = viewModel.lastBrowseSearchText
            }
            uhdPaperVM.loadInitialIfNeeded()
        }
    }

    private var searchBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search UHDPaper...", text: $uhdPaperVM.searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { uhdPaperVM.search() }
                        // Saves the typed text (not a live search) to ContentViewModel so
                        // switching to a different source pre-fills its search bar with the
                        // same query instead of starting blank.
                        .onChange(of: uhdPaperVM.searchQuery) { _, newValue in viewModel.lastBrowseSearchText = newValue }
                    if !uhdPaperVM.searchQuery.isEmpty {
                        Button {
                            uhdPaperVM.clearSearch()
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

                if !uhdPaperVM.hiddenItemIDs.isEmpty {
                    Button {
                        uhdPaperVM.unhideAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.slash")
                            Text("\(uhdPaperVM.hiddenItemIDs.count)")
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
                    ForEach(UhdPaperCategory.allCases) { category in
                        let isSelected = uhdPaperVM.category == category
                        Button(category.displayName) {
                            uhdPaperVM.loadCategory(category)
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
        if uhdPaperVM.isLoading && uhdPaperVM.items.isEmpty {
            Spacer()
            ProgressView(uhdPaperVM.isSearchActive ? "Searching UHDPaper..." : "Loading from UHDPaper...")
            Spacer()
        } else if let error = uhdPaperVM.errorMessage, uhdPaperVM.items.isEmpty {
            BrowseStateView(icon: "wifi.exclamationmark", message: error) {
                Task { await uhdPaperVM.load() }
            }
        } else if uhdPaperVM.visibleItems.isEmpty {
            BrowseStateView(
                icon: uhdPaperVM.isSearchActive ? "magnifyingglass" : "eye.slash",
                message: uhdPaperVM.isSearchActive ? "No results for \"\(uhdPaperVM.searchQuery)\"" : "Everything here is hidden"
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 18) {
                    ForEach(uhdPaperVM.visibleItems) { item in
                        UhdPaperItemCard(item: item, viewModel: uhdPaperVM, downloadState: uhdPaperVM.downloadState[item.id])
                            .modifier(LoadMoreTrigger(
                                isLast: item.id == uhdPaperVM.visibleItems.last?.id,
                                visible: $loadMoreVisible,
                                canLoad: !uhdPaperVM.isLoading,
                                load: uhdPaperVM.loadNextPage
                            ))
                    }
                }
                .padding()

                if !uhdPaperVM.items.isEmpty {
                    Button {
                        uhdPaperVM.loadNextPage()
                    } label: {
                        if uhdPaperVM.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load More")
                        }
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 20)
                    .disabled(uhdPaperVM.isLoading)
                }
            }
        }
    }
}

private struct UhdPaperItemCard: View {
    let item: UhdPaperItem
    // Not @ObservedObject — see MotionBgsItemCard's identical doc comment.
    let viewModel: UhdPaperViewModel
    let downloadState: UhdPaperViewModel.DownloadState?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // No hover-preview player here — unlike the video sources, this thumbnail already *is*
            // the wallpaper (a still image), nothing to preview-play.
            RetryingAsyncImage(url: item.thumbnailURL, httpHeaders: UhdPaperService.refererHeaders) { phase in
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
