//
//  DirectURLImportSheet.swift
//  Wallwright
//
//  Downloads a video or image from a direct link, then hands the result to whichever import
//  pipeline (VideoImporter/ImportReviewSheet or ImageImporter/ImageImportReviewSheet) matches the
//  downloaded file's extension — same reasoning as YouTubeImportSheet, just type-dispatched.
//
//  State lives on `model` (DirectURLImportViewModel), not local `@State` — presented as a
//  click-outside-to-dismiss popup (see ContentView), not a modal `.sheet`, so you can dismiss it
//  while a download is running and come back to see where it's at.
//

import SwiftUI

struct DirectURLImportSheet: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var model: DirectURLImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PopupHeader(title: "Import from URL") {
                viewModel.isDirectURLImportReveal = false
            }

            if let downloadedFileURL = model.downloadedFileURL {
                completedSummary(downloadedFileURL)
            } else {
                Text("Paste a direct link to a video or image file — a URL that ends at the file itself, not a page that plays or embeds it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("https://example.com/video.mp4", text: $model.urlString)
                        .glassFieldStyle()
                        .disabled(model.isDownloading)
                        .onSubmit { Task { await model.startDownload() } }
                    Button("Download") { Task { await model.startDownload() } }
                        .buttonStyle(.glassProminent)
                        .disabled(model.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isDownloading)
                }

                if model.isDownloading {
                    if let progress = model.downloadProgress {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("Downloading…")
                            .frame(maxWidth: .infinity)
                    }
                    Text("Keeps downloading if you close this.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(model.downloadedFileURL != nil ? "Cancel" : "Close") {
                    viewModel.isDirectURLImportReveal = false
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 300)
    }

    private func completedSummary(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Download complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                summaryRow("File", url.lastPathComponent)
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                    summaryRow("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            Button("Continue to Title & Tags") {
                viewModel.pendingDirectURLDownload = url
                viewModel.isDirectURLImportReveal = false
                model.reset()
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.footnote)
    }
}
