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
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await desktopHutVM.load() }
                }
                .buttonStyle(.glass)
            }
            .frame(maxWidth: 320)
            Spacer()
        } else if desktopHutVM.visibleItems.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: desktopHutVM.isSearchActive ? "magnifyingglass" : "eye.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(desktopHutVM.isSearchActive ? "No results for \"\(desktopHutVM.searchQuery)\"" : "Everything here is hidden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)
            Spacer()
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
    @State private var isPreviewReady = false

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

                // Swapped in on hover — a real muted, looping preview clip parsed off the listing
                // page (see `DesktopHutItem.previewVideoURL`), not just a static thumbnail. Stays
                // transparent (thumbnail still showing through) until the first frame is actually
                // ready, instead of flashing solid black while it loads.
                if isHovered, let previewURL = item.previewVideoURL {
                    HoverPreviewPlayer(url: previewURL) { isPreviewReady = true }
                        .opacity(isPreviewReady ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: isPreviewReady)
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
                if !hovering { isPreviewReady = false }
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
