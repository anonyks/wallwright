//
//  MotionBgsView.swift
//  Wallwright
//
//  Browse and import live wallpapers from motionbgs.com.
//

import SwiftUI

struct MotionBgsView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var motionBgsVM: MotionBgsViewModel
    @State private var loadMoreVisible = false

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self.motionBgsVM = viewModel.motionBgsViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !motionBgsVM.isSearchActive {
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
            if motionBgsVM.searchQuery.isEmpty && !viewModel.lastBrowseSearchText.isEmpty {
                motionBgsVM.searchQuery = viewModel.lastBrowseSearchText
            }
            motionBgsVM.loadInitialIfNeeded()
        }
    }

    private var searchBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search MotionBgs...", text: $motionBgsVM.searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { motionBgsVM.search() }
                        // Saves the typed text (not a live search) to ContentViewModel so
                        // switching to a different source pre-fills its search bar with the
                        // same query instead of starting blank.
                        .onChange(of: motionBgsVM.searchQuery) { _, newValue in viewModel.lastBrowseSearchText = newValue }
                    if !motionBgsVM.searchQuery.isEmpty {
                        Button {
                            motionBgsVM.clearSearch()
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

                // Custom two-way glass toggle rather than the native .segmented picker style —
                // that rendered as a flat system control that clashed against the glass search
                // field and glass buttons on either side of it.
                HStack(spacing: 2) {
                    qualityButton(title: "HD", value: "hd")
                    qualityButton(title: "4K", value: "4k")
                }
                .help("Download quality — HD is 1920×1080 (~2MB), 4K is 3840×2160 (~17MB)")

                if !motionBgsVM.hiddenItemIDs.isEmpty {
                    Button {
                        motionBgsVM.unhideAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.slash")
                            Text("\(motionBgsVM.hiddenItemIDs.count)")
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

    private func qualityButton(title: String, value: String) -> some View {
        let isSelected = motionBgsVM.downloadQuality == value
        return Button {
            motionBgsVM.downloadQuality = value
        } label: {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .frame(width: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .padding(.vertical, 6)
        // 9, not 7 — matches the search field it sits beside in the same GlassEffectContainer, and
        // every other button/card corner radius across the app's other source-browser views.
        .glassEffect(isSelected ? .regular : .identity, in: RoundedRectangle(cornerRadius: 9)) // no accentColor tint — reads gray on Graphite
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(MotionBgsCategory.allCases) { category in
                        let isSelected = motionBgsVM.category == category
                        Button(category.displayName) {
                            motionBgsVM.loadCategory(category)
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(isSelected ? .regular : .identity, in: Capsule()) // no accentColor tint — reads gray on Graphite
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var content: some View {
        if motionBgsVM.isLoading && motionBgsVM.items.isEmpty {
            Spacer()
            ProgressView(motionBgsVM.isSearchActive ? "Searching MotionBgs..." : "Loading from MotionBgs...")
            Spacer()
        } else if let error = motionBgsVM.errorMessage, motionBgsVM.items.isEmpty {
            BrowseStateView(icon: "wifi.exclamationmark", message: error) {
                Task { await motionBgsVM.load() }
            }
        } else if motionBgsVM.visibleItems.isEmpty {
            BrowseStateView(
                icon: motionBgsVM.isSearchActive ? "magnifyingglass" : "eye.slash",
                message: motionBgsVM.isSearchActive ? "No results for \"\(motionBgsVM.searchQuery)\"" : "Everything here is hidden"
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 18) {
                    ForEach(motionBgsVM.visibleItems) { item in
                        MotionBgsItemCard(item: item, viewModel: motionBgsVM, downloadState: motionBgsVM.downloadState[item.id])
                            .modifier(LoadMoreTrigger(
                                isLast: item.id == motionBgsVM.visibleItems.last?.id,
                                visible: $loadMoreVisible,
                                canLoad: !motionBgsVM.isLoading,
                                load: motionBgsVM.loadNextPage
                            ))
                    }
                }
                .padding()

                if !motionBgsVM.items.isEmpty {
                    Button {
                        motionBgsVM.loadNextPage()
                    } label: {
                        if motionBgsVM.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load More")
                        }
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 20)
                    .disabled(motionBgsVM.isLoading)
                }
            }
        }
    }
}

private struct MotionBgsItemCard: View {
    let item: MotionBgsItem
    // Not @ObservedObject — subscribing here would re-render every visible card on any change to
    // `viewModel` at all (any item's download progress, search text, category, etc.), since
    // @ObservedObject forces its whole view to re-render on ANY publish from the object,
    // regardless of which properties that view's body actually reads. `downloadState` below is
    // the one piece of `viewModel` this card's body needs, read by the parent (which does observe
    // the VM) and passed down as a plain value, so SwiftUI's own diffing can skip this card
    // whenever ITS item's state hasn't changed. Still fine to call methods (hide/download) on a
    // plain reference — those don't need a subscription, just a live object to call into.
    let viewModel: MotionBgsViewModel
    let downloadState: MotionBgsViewModel.DownloadState?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RetryingAsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(16.0/9.0, contentMode: .fill)
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
                    viewModel.download(item: item, quality: viewModel.downloadQuality)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
                .help("Retry download")
            }
        case nil:
            Button {
                viewModel.download(item: item, quality: viewModel.downloadQuality)
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
