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
        .glassEffect(isSelected ? .regular.tint(.accentColor) : .identity, in: RoundedRectangle(cornerRadius: 9))
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
                        .glassEffect(isSelected ? .regular.tint(.accentColor) : .identity, in: Capsule())
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
                    Task { await motionBgsVM.load() }
                }
                .buttonStyle(.glass)
            }
            .frame(maxWidth: 320)
            Spacer()
        } else if motionBgsVM.visibleItems.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: motionBgsVM.isSearchActive ? "magnifyingglass" : "eye.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(motionBgsVM.isSearchActive ? "No results for \"\(motionBgsVM.searchQuery)\"" : "Everything here is hidden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 18) {
                    ForEach(motionBgsVM.visibleItems) { item in
                        MotionBgsItemCard(item: item, viewModel: motionBgsVM)
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
    @ObservedObject var viewModel: MotionBgsViewModel

    @State private var isHovered = false
    @State private var isPreviewReady = false

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

                // Swapped in on hover — a real muted, looping preview clip, not just a static
                // thumbnail. Only created while actually hovered so we're not running dozens of
                // background video decoders for a grid the user is just scrolling past. Stays
                // transparent (thumbnail still showing through) until the first frame is actually
                // ready, instead of flashing solid black while it loads.
                if isHovered {
                    HoverPreviewPlayer(url: item.previewVideoURL) { isPreviewReady = true }
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
