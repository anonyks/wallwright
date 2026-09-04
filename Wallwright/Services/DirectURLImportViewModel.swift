//
//  DirectURLImportViewModel.swift
//  Wallwright
//
//  Holds the Direct URL import popup's state outside the view itself, owned persistently on
//  ContentViewModel (same reasoning as YouTubeImportViewModel/SteamWorkshopImportViewModel) so
//  dismissing the popup mid-download doesn't lose progress — reopening it just re-shows whatever's
//  actually happening.
//

import Foundation

@MainActor
final class DirectURLImportViewModel: ObservableObject {
    @Published var urlString = ""
    @Published var isDownloading = false
    /// nil while the server didn't report a content length — the sheet shows an indeterminate
    /// spinner instead of a percentage that would otherwise just sit at 0%.
    @Published var downloadProgress: Double?
    @Published var downloadedFileURL: URL?
    @Published var errorMessage: String?

    func reset() {
        urlString = ""
        isDownloading = false
        downloadProgress = nil
        downloadedFileURL = nil
        errorMessage = nil
    }

    func startDownload() async {
        // Same fix as `YouTubeImportViewModel.startDownload`'s identical guard — a fast double-
        // trigger can queue two `Task`s before either one's own `isDownloading = true` below has
        // run, both believing no download is in progress.
        guard !isDownloading else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            errorMessage = DirectURLImportError.invalidURL.errorDescription
            return
        }
        errorMessage = nil
        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }
        do {
            downloadedFileURL = try await DirectURLImporter.download(from: url) { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
