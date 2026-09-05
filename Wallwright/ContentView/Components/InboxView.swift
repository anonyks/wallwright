//
//  InboxView.swift
//  Wallwright
//
//  Links shared in from a phone (see InboxTransport/NtfyInboxTransport), waiting to be imported.
//  Action row deliberately uses the same GlassEffectContainer/glass-button pattern every other tab
//  in this app already builds its own top bar from (ExplorerTopBar, MotionBgsView's searchBar,
//  ...) rather than a real NSToolbar-backed `.toolbar` — this app has no native window toolbar
//  anywhere else, so introducing one here would be the one screen that looks inconsistent with
//  the rest of it. Every other native idiom (Menu, .confirmationDialog, .contextMenu,
//  .swipeActions) is used as-is, matching Finder/Mail/Photos conventions directly.
//

import SwiftUI

struct InboxView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var store = AppDelegate.shared.inboxLinksStore
    @ObservedObject private var globalSettingsViewModel = AppDelegate.shared.globalSettingsViewModel

    @State private var isClearAllConfirming = false
    @State private var topicDraft = ""

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    private var directLinks: [InboxLink] { store.links.filter { $0.kind == .direct } }
    /// Indirect and not-yet-classified links together — an unclassified link is still, functionally,
    /// "needs something before it can just be downloaded," same as a genuinely indirect one; its
    /// row just shows "Classifying…" instead of the Import button until that resolves (normally
    /// well under a second).
    private var needsResolvingLinks: [InboxLink] { store.links.filter { $0.kind != .direct } }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            if globalSettingsViewModel.settings.inboxNtfyTopic.trimmingCharacters(in: .whitespaces).isEmpty {
                topicSetupPrompt
            } else if store.links.isEmpty {
                BrowseStateView(icon: "tray", message: "No links yet — share one from your phone to see it here")
            } else {
                list
            }
        }
        .onAppear {
            topicDraft = globalSettingsViewModel.settings.inboxNtfyTopic
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    viewModel.isDirectURLImportReveal = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .help("Add a link manually")
                .accessibilityLabel("Add a link manually")

                Menu {
                    Button {
                        store.importAllDirect()
                    } label: {
                        Label("Import All Direct", systemImage: "arrow.down.circle")
                    }
                    .disabled(!directLinks.contains { $0.status == .pending || $0.status == .resolved })

                    Button {
                        store.removeCompletedAndFailed()
                    } label: {
                        Label("Clear Completed & Failed", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .help("More Actions")
                .accessibilityLabel("More Actions")

                Spacer(minLength: 10)

                topicField

                if !store.links.isEmpty {
                    Button(role: .destructive) {
                        isClearAllConfirming = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .help("Clear All")
                    .accessibilityLabel("Clear All")
                }
            }
            .controlSize(.regular)
        }
        .padding(10)
        .confirmationDialog(
            "Clear all links from the Inbox?", isPresented: $isClearAllConfirming, titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { store.removeAll() }
        }
    }

    private var topicField: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
            TextField("ntfy topic", text: $topicDraft)
                .textFieldStyle(.plain)
                .frame(width: 140)
                .onSubmit(saveTopic)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9))
        .help("The ntfy.sh topic your phone's ntfy app shares links to")
    }

    private func saveTopic() {
        let trimmed = topicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != globalSettingsViewModel.settings.inboxNtfyTopic else { return }
        globalSettingsViewModel.settings.inboxNtfyTopic = trimmed
        // Reconnects with the new topic immediately rather than waiting for the next lifecycle
        // event (unlock/wake/becomeActive) — changing the topic while already looking at this tab
        // should take effect right away, not silently wait for one of those.
        ActiveInboxTransport.shared.stop()
        ActiveInboxTransport.shared.start()
    }

    // MARK: - Empty / setup states

    private var topicSetupPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Set up your Inbox")
                .font(.headline)
            Text("Pick a private topic name, subscribe to it in the ntfy app on your phone, then share a link to it from anywhere — it'll show up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 6) {
                TextField("your-private-topic-name", text: $topicDraft)
                    .textFieldStyle(.plain)
                    .frame(width: 200)
                    .onSubmit(saveTopic)
                Button("Save", action: saveTopic)
                    .buttonStyle(.glass)
                    // Untinted, matching the Pause/Open Wallpaper fix — `.glassProminent` reads as
                    // a flat gray fill on the Graphite system accent; plain `.glass` keeps the
                    // translucent lens look consistent with the rest of the main window's chrome.
                    .disabled(topicDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var list: some View {
        List {
            if !directLinks.isEmpty {
                Section("Direct") {
                    ForEach(directLinks) { link in
                        InboxLinkRow(link: link, store: store)
                    }
                }
            }
            if !needsResolvingLinks.isEmpty {
                Section("Needs Resolving") {
                    ForEach(needsResolvingLinks) { link in
                        InboxLinkRow(link: link, store: store)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

private struct InboxLinkRow: View {
    let link: InboxLink
    @ObservedObject var store: InboxLinksStore

    // Swipe-to-delete and the context menu's Delete/Open in Browser both already work, but neither
    // is obvious without already knowing the gesture — these hover-reveal buttons are the same
    // pattern MotionBgsItemCard already uses for its own per-item "hide" button, so fast, visible
    // access to both is available here too without needing permanently-visible icons competing
    // with the row's other content.
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(link.resolvedTitle ?? link.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(link.url.host ?? link.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isHovered {
                Button {
                    NSWorkspace.shared.open(link.url)
                } label: {
                    Image(systemName: "safari")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in Browser")

                Button {
                    store.remove(link)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            statusControl
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.remove(link)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.open(link.url)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            if case .failed = link.status {
                Button {
                    store.retry(link)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                store.remove(link)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            if let thumbnailURL = link.resolvedThumbnailURL {
                RetryingAsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(width: 44, height: 44)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var placeholderIcon: some View {
        Image(systemName: isLikelyImage ? "photo" : "video")
            .foregroundStyle(.tertiary)
    }

    private var isLikelyImage: Bool {
        ["jpg", "jpeg", "png", "heic", "webp"].contains(link.url.pathExtension.lowercased())
    }

    @ViewBuilder
    private var statusControl: some View {
        switch link.status {
        case .pending:
            // `.unknown` no longer means "still classifying" — classification is instant now (see
            // `InboxLinksStore.classify`), and an `.unknown` kind just means neither free check
            // could place it, resolved lazily on the tap itself via `resolveUnknownLink`.
            importButton
        case .resolving:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Resolving…").font(.caption).foregroundStyle(.secondary)
            }
        case .resolved:
            importButton
        case .downloading:
            if store.isConverting.contains(link.id) {
                // yt-dlp/YouTube can serve AV1/VP9, which needs re-encoding to H.264 before
                // AVFoundation can play it — that step has no percentage to report, so this is
                // shown instead of a progress bar frozen at 100% for however long it takes, which
                // otherwise reads as stuck rather than working (confirmed live, 2026-08-21).
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Converting…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let progress = store.downloadProgress[link.id] {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress).frame(width: 60)
                    Text("\(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        case .importing:
            Label("Importing…", systemImage: "square.and.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .completed:
            Label("Added", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let reason):
            Button {
                store.retry(link)
            } label: {
                Label("Failed", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(reason)
        }
    }

    private var importButton: some View {
        Button {
            store.importLink(link)
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help("Import")
    }
}
