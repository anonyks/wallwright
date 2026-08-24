//
//  DesktopHutView.swift
//  Wallwright
//
//  Browse and import live wallpapers from desktophut.com.
//

import SwiftUI

struct DesktopHutView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var desktopHutVM: DesktopHutViewModel

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self.desktopHutVM = viewModel.desktopHutViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !desktopHutVM.isSearchActive {
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
            if desktopHutVM.searchQuery.isEmpty && !viewModel.lastBrowseSearchText.isEmpty {
                desktopHutVM.searchQuery = viewModel.lastBrowseSearchText
            }
            desktopHutVM.loadInitialIfNeeded()
        }
    }

    private var searchBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search DesktopHut...", text: $desktopHutVM.searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { desktopHutVM.search() }
                        // Saves the typed text (not a live search) to ContentViewModel so
                        // switching to a different source pre-fills its search bar with the
                        // same query instead of starting blank.
                        .onChange(of: desktopHutVM.searchQuery) { _, newValue in viewModel.lastBrowseSearchText = newValue }
                    if !desktopHutVM.searchQuery.isEmpty {
                        Button {
                            desktopHutVM.clearSearch()
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

                if !desktopHutVM.hiddenItemIDs.isEmpty {
                    Button {
                        desktopHutVM.unhideAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.slash")
                            Text("\(desktopHutVM.hiddenItemIDs.count)")
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
                    ForEach(DesktopHutCategory.allCases) { category in
                        let isSelected = desktopHutVM.category == category
                        Button(category.displayName) {
                            desktopHutVM.loadCategory(category)
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
        if desktopHutVM.isLoading && desktopHutVM.items.isEmpty {
            Spacer()
            ProgressView(desktopHutVM.isSearchActive ? "Searching DesktopHut..." : "Loading from DesktopHut...")
            Spacer()
        } else if let error = desktopHutVM.errorMessage, desktopHutVM.items.isEmpty {
            BrowseStateView(icon: "wifi.exclamationmark", message: error) {
                Task { await desktopHutVM.load() }
            }
        } else if desktopHutVM.visibleItems.isEmpty {
            BrowseStateView(
                icon: desktopHutVM.isSearchActive ? "magnifyingglass" : "eye.slash",
                message: desktopHutVM.isSearchActive ? "No results for \"\(desktopHutVM.searchQuery)\"" : "Everything here is hidden"
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 18) {
                    ForEach(desktopHutVM.visibleItems) { item in
                        DesktopHutItemCard(item: item, viewModel: desktopHutVM)
                    }
                }
                .padding()

                if !desktopHutVM.items.isEmpty {
                    Button {
                        desktopHutVM.loadNextPage()
                    } label: {
                        if desktopHutVM.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load More")
                        }
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 20)
                    .disabled(desktopHutVM.isLoading)
                }
            }
        }
    }
}

private struct DesktopHutItemCard: View {
    let item: DesktopHutItem
    @ObservedObject var viewModel: DesktopHutViewModel

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
        switch viewModel.downloadState[item.id] {
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
