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
                    Task { await uhdPaperVM.load() }
                }
                .buttonStyle(.glass)
            }
            .frame(maxWidth: 320)
            Spacer()
        } else if uhdPaperVM.visibleItems.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: uhdPaperVM.isSearchActive ? "magnifyingglass" : "eye.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(uhdPaperVM.isSearchActive ? "No results for \"\(uhdPaperVM.searchQuery)\"" : "Everything here is hidden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 18) {
                    ForEach(uhdPaperVM.visibleItems) { item in
                        UhdPaperItemCard(item: item, viewModel: uhdPaperVM)
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
    @ObservedObject var viewModel: UhdPaperViewModel

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
