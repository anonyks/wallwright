//
//  SteamWorkshopImportViewModel.swift
//  Wallwright
//
//  Same reasoning as YouTubeImportViewModel — moves the Steam Workshop import sheet's state off
//  the view (where closing the popup destroyed it) and onto a persistently-owned object, so the
//  steamcmd download keeps its visible progress across a dismiss/reopen.
//

import Foundation

@MainActor
final class SteamWorkshopImportViewModel: ObservableObject {
    @Published var usernameField = ""
    @Published var urlString = ""
    @Published var isFetchingPreview = false
    @Published var preview: SteamWorkshopPreview?
    @Published var isDownloading = false
    @Published var downloadStatusLine = ""
    @Published var downloadResult: SteamWorkshopResult?
    @Published var errorMessage: String?

    func reset() {
        usernameField = ""
        urlString = ""
        isFetchingPreview = false
        preview = nil
        isDownloading = false
        downloadStatusLine = ""
        downloadResult = nil
        errorMessage = nil
    }

    func fetchPreview() async {
        guard let itemId = SteamWorkshopService.extractItemId(from: urlString) else { return }
        errorMessage = nil
        preview = nil
        isFetchingPreview = true
        defer { isFetchingPreview = false }
        do {
            preview = try await SteamWorkshopService.fetchPreview(itemId: itemId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startDownload(username: String) async {
        guard let itemId = SteamWorkshopService.extractItemId(from: urlString) else { return }
        errorMessage = nil
        downloadStatusLine = ""
        isDownloading = true
        defer { isDownloading = false }
        do {
            downloadResult = try await SteamWorkshopService.download(itemId: itemId, username: username) { [weak self] line in
                self?.downloadStatusLine = line
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
