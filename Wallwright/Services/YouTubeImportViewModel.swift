//
//  YouTubeImportViewModel.swift
//  Wallwright
//
//  Holds the YouTube import sheet's state outside the view itself — it used to live as `@State`
//  directly on YouTubeImportSheet, which meant closing the sheet destroyed it, and the underlying
//  download (a plain `Task`, not a `.task`-bound one) kept running invisibly with no way to see
//  progress again. Owned persistently on ContentViewModel (like motionBgsViewModel) so dismissing
//  the popup and reopening it just re-shows whatever's actually happening.
//

import Foundation

@MainActor
final class YouTubeImportViewModel: ObservableObject {
    @Published var urlString = ""
    @Published var isFetchingInfo = false
    @Published var videoInfo: YtDlpVideoInfo?
    @Published var includeAudio = true
    @Published var trimEnabled = false
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var isTranscoding = false
    @Published var downloadResult: YtDlpDownloadResult?
    @Published var errorMessage: String?

    func reset() {
        urlString = ""
        isFetchingInfo = false
        videoInfo = nil
        includeAudio = true
        trimEnabled = false
        trimStart = 0
        trimEnd = 0
        isDownloading = false
        downloadProgress = 0
        isTranscoding = false
        downloadResult = nil
        errorMessage = nil
    }

    func fetchInfo() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        videoInfo = nil
        isFetchingInfo = true
        defer { isFetchingInfo = false }
        do {
            let info = try await YtDlpService.fetchInfo(url: trimmed)
            videoInfo = info
            trimStart = 0
            trimEnd = info.duration
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startDownload() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isDownloading = true
        downloadProgress = 0
        isTranscoding = false
        defer {
            isDownloading = false
            isTranscoding = false
        }
        do {
            let result = try await YtDlpService.download(
                url: trimmed,
                includeAudio: includeAudio,
                start: trimEnabled ? trimStart : nil,
                end: trimEnabled ? trimEnd : nil,
                onProgress: { [weak self] in self?.downloadProgress = $0 },
                onTranscodingStart: { [weak self] in self?.isTranscoding = true }
            )
            downloadResult = result
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
