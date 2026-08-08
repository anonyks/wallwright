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

    init(pending: PendingPackageImport, remaining: Int, viewModel: ContentViewModel) {
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
                        // No fixed ratio — Steam Workshop preview images vary (square, 16:9,
                        // 4:3, ...), so this just fits the specific image's own dimensions.
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                    Label("Steam Workshop · \(pending.type.capitalized) wallpaper", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                    viewModel.skipCurrentPackageImport()
                }
                Spacer()
                Button("Import") {
                    // Same fix as ImportReviewSheet — flush an unsubmitted "Add a tag" field
                    // before committing, rather than silently dropping it.
                    addTag()
                    viewModel.commitCurrentPackageImport(title: trimmedTitle, tags: tags)
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
