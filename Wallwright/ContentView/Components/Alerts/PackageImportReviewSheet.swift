//
//  PackageImportReviewSheet.swift
//  Wallwright
//
//  Shown after a Steam Workshop download (or any other pre-formed package import) finishes, before
//  it's copied into the wallpapers directory — lets the user fix the title and tags Workshop items
//  arrive with, same idea as ImportReviewSheet but for PendingPackageImport instead of a raw video.
//

import SwiftUI

struct PackageImportReviewSheet: View {
    @ObservedObject var viewModel: ContentViewModel

    var body: some View {
        Group {
            if let pending = viewModel.pendingPackageImports.first {
                PackageImportReviewContent(pending: pending, remaining: viewModel.pendingPackageImports.count, viewModel: viewModel)
                    .id(pending.id)
            }
        }
        .frame(width: 420, height: 520)
    }
}

private struct PackageImportReviewContent: View {
    let pending: PendingPackageImport
    let remaining: Int
    @ObservedObject var viewModel: ContentViewModel

    @State private var title: String
    @State private var tags: [String]
    @State private var newTag = ""
    @State private var selectedSceneArtIndex: Int
    @State private var mainPreviewImage: NSImage
    /// Decoded once in `init` at thumbnail size via `ThumbnailDownsampler`'s decode-at-size path,
    /// not a full decode of `pending.sceneArtCandidates`' own full-resolution JPEG `Data` (often
    /// 3840x2160+) shrunk down after the fact — up to 8 of those held fully decoded at once (for a
    /// strip of buttons never shown larger than 64pt) measured ~264MB of transient RAM. This way
    /// each thumbnail decodes straight at the ~64pt-strip's own target size.
    private let candidateThumbnails: [NSImage]

    init(pending: PendingPackageImport, remaining: Int, viewModel: ContentViewModel) {
        self.pending = pending
        self.remaining = remaining
        self.viewModel = viewModel
        self._title = State(initialValue: pending.title)
        self._tags = State(initialValue: pending.tags)
        self._selectedSceneArtIndex = State(initialValue: pending.selectedSceneArtIndex)
        self.candidateThumbnails = pending.sceneArtCandidates.map {
            ThumbnailDownsampler.downsampledImage(from: $0.extracted.jpegData, maxDimension: 128) ?? NSImage()
        }
        let initialFull = pending.sceneArtCandidates.indices.contains(pending.selectedSceneArtIndex)
            ? pending.sceneArtCandidates[pending.selectedSceneArtIndex].extracted.jpegData : nil
        self._mainPreviewImage = State(initialValue: initialFull.flatMap { ThumbnailDownsampler.downsampledImage(from: $0, maxDimension: 900) } ?? NSImage())
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review Import")
                    .font(.title2.weight(.semibold))
                Spacer()
                if remaining > 1 {
                    Text("\(remaining) remaining")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    if pending.sceneArtCandidates.count > 1 {
                        sceneArtPicker
                    } else {
                        Image(nsImage: pending.thumbnail)
                            .resizable()
                            // No fixed ratio — Steam Workshop preview images vary (square, 16:9,
                            // 4:3, ...), so this just fits the specific image's own dimensions.
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }

                    Label("Steam Workshop · \(pending.type.capitalized) wallpaper", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title").font(.footnote).foregroundStyle(.secondary)
                        TextField("Title", text: $title)
                            .glassFieldStyle()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags").font(.footnote).foregroundStyle(.secondary)

                        if !tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(tags, id: \.self) { tag in
                                        HStack(spacing: 4) {
                                            Text(tag)
                                            Button {
                                                tags.removeAll { $0 == tag }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Remove tag")
                                            .help("Remove tag")
                                        }
                                        .font(.footnote)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .glassEffect(.regular, in: Capsule())
                                    }
                                }
                            }
                        }

                        HStack {
                            TextField("Add a tag", text: $newTag)
                                .glassFieldStyle()
                                .onSubmit(addTag)
                            Button("Add", action: addTag)
                                .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Button("Skip") {
                    viewModel.skipCurrentPackageImport()
                }
                Spacer()
                Button("Import") {
                    // Same fix as ImportReviewSheet — flush an unsubmitted "Add a tag" field
                    // before committing, rather than silently dropping it.
                    addTag()
                    Task { await viewModel.commitCurrentPackageImport(title: trimmedTitle, tags: tags, selectedSceneArtIndex: selectedSceneArtIndex) }
                }
                .buttonStyle(.glassProminent)
                .disabled(trimmedTitle.isEmpty)
            }
            .padding()
        }
    }

    /// Shown instead of the plain `pending.thumbnail` when SceneArtExtractor found more than one
    /// plausible background texture in the scene's own package — a real scene often bundles
    /// several image layers (background, foreground elements, UI chrome), and silently committing
    /// to whichever one happened to resolve first produced the wrong picture often enough to be
    /// worth asking instead of guessing.
    private var sceneArtPicker: some View {
        VStack(spacing: 10) {
            Image(nsImage: mainPreviewImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .id(selectedSceneArtIndex)  // crossfade-free swap reads as an intentional pick, not a glitch

            Text("This scene has \(candidateThumbnails.count) image layers — choose which one becomes the wallpaper.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(candidateThumbnails.indices, id: \.self) { index in
                        Button {
                            selectedSceneArtIndex = index
                            // The main preview is the one candidate decoded at a larger size — only
                            // re-decode it when the selection actually changes, not one full decode
                            // per candidate up front (see `candidateThumbnails`'s own doc comment).
                            mainPreviewImage = ThumbnailDownsampler.downsampledImage(from: pending.sceneArtCandidates[index].extracted.jpegData, maxDimension: 900) ?? NSImage()
                        } label: {
                            Image(nsImage: candidateThumbnails[index])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(index == selectedSceneArtIndex ? Color.accentColor : .clear, lineWidth: 3)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use image layer \(index + 1) as the wallpaper")
                    }
                }
            }
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        newTag = ""
    }
}
