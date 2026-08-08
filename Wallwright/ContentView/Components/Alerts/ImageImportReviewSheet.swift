//
//  ImageImportReviewSheet.swift
//  Wallwright
//
//  Shown after a manual image import (Open Wallpaper panel or drag-and-drop) is picked, before
//  it's actually copied into the wallpapers directory — same review-before-commit shape as
//  ImportReviewSheet.swift (video's equivalent), minus the "converted from" notice, which never
//  applies to a static image.
//

import SwiftUI

struct ImageImportReviewSheet: View {
    @ObservedObject var viewModel: ContentViewModel

    var body: some View {
        Group {
            if let pending = viewModel.pendingImageImports.first {
                ImageImportReviewContent(pending: pending, remaining: viewModel.pendingImageImports.count, viewModel: viewModel)
                    .id(pending.id)
            }
        }
        .frame(width: 420, height: 520)
    }
}

private struct ImageImportReviewContent: View {
    let pending: PendingImageImport
    let remaining: Int
    @ObservedObject var viewModel: ContentViewModel

    @State private var title: String
    @State private var tags: [String]
    @State private var newTag = ""

    init(pending: PendingImageImport, remaining: Int, viewModel: ContentViewModel) {
        self.pending = pending
        self.remaining = remaining
        self.viewModel = viewModel
        self._title = State(initialValue: pending.title)
        self._tags = State(initialValue: pending.tags)
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
                    Image(nsImage: pending.thumbnail)
                        .resizable()
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title").font(.footnote).foregroundStyle(.secondary)
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
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
                                .textFieldStyle(.roundedBorder)
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
                    viewModel.skipCurrentImageImport()
                }
                Spacer()
                Button("Import") {
                    // Flush whatever's still sitting in the "Add a tag" field but was never
                    // explicitly submitted — same fix as ImportReviewSheet's video equivalent.
                    addTag()
                    viewModel.commitCurrentImageImport(title: trimmedTitle, tags: tags)
                }
                .buttonStyle(.glassProminent)
                .disabled(trimmedTitle.isEmpty)
            }
            .padding()
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        newTag = ""
    }
}
