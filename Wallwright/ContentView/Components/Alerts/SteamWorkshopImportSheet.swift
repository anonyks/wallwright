//
//  SteamWorkshopImportSheet.swift
//  Wallwright
//
//  Downloads a Wallpaper Engine Workshop item via steamcmd, then hands the result to the same
//  pendingPackageImports/PackageImportReviewSheet pipeline manual folder imports use — matching
//  YouTubeImportSheet's own "download here, review title/tags there" split.
//
//  steamcmd needs its own one-time login (outside this app, in Terminal) before anything here can
//  work — that's unavoidable: Workshop content for a paid app is locked to accounts that own it,
//  and this app will never handle a Steam password itself. Once that's done and the account's
//  username is saved below, every later download is just "paste a URL."
//
//  State lives on `model` (SteamWorkshopImportViewModel), not local `@State` — this is presented
//  as a click-outside-to-dismiss popup (see ContentView), not a modal `.sheet`, specifically so you
//  can dismiss it while steamcmd is running and come back to see where it's at.
//

import SwiftUI

struct SteamWorkshopImportSheet: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var model: SteamWorkshopImportViewModel
    @ObservedObject var globalSettingsViewModel = AppDelegate.shared.globalSettingsViewModel

    private var savedUsername: String? {
        let trimmed = globalSettingsViewModel.settings.steamUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Steam Workshop")
                .font(.title2.weight(.semibold))

            if !SteamWorkshopService.isAvailable {
                notInstalledSetup
            } else if savedUsername == nil {
                oneTimeLoginSetup
            } else if let downloadResult = model.downloadResult {
                completedSummary(downloadResult)
            } else {
                downloadForm
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                if savedUsername != nil, model.downloadResult == nil, SteamWorkshopService.isAvailable {
                    Button("Change Account") {
                        globalSettingsViewModel.settings.steamUsername = nil
                    }
                    .disabled(model.isDownloading)
                    .font(.caption)
                }
                Spacer()
                Button(model.downloadResult != nil ? "Cancel" : "Close") {
                    viewModel.isSteamWorkshopImportReveal = false
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 540)
    }

    private var notInstalledSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("steamcmd isn't installed.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Install it with Homebrew, then reopen this:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("brew install steamcmd")
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// steamcmd needs a real, interactive login (password + Steam Guard code on first use) before
    /// this app can reuse it — that has to happen in Terminal, once, since this app never touches
    /// a Steam password. This just captures which cached account to tell steamcmd to reuse after.
    private var oneTimeLoginSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("One-time setup needed.", systemImage: "person.badge.key.fill")
                .foregroundStyle(.orange)
            Text("In Terminal, log steamcmd into the Steam account that owns Wallpaper Engine — this caches the login locally (handles any Steam Guard code interactively) so this app never needs your password:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("steamcmd +login YOUR_STEAM_USERNAME +quit")
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Text("Once that succeeds, enter that same username here — every later import is then just pasting a Workshop URL:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Steam username", text: $model.usernameField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let trimmed = model.usernameField.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    globalSettingsViewModel.settings.steamUsername = trimmed
                }
                .disabled(model.usernameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var downloadForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signed in as \(savedUsername ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Workshop URL or item ID", text: $model.urlString)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isFetchingPreview || model.isDownloading)
                    .onSubmit { Task { await model.fetchPreview() } }
                    .onChange(of: model.urlString) { _, _ in model.preview = nil }
                Button("Fetch") { Task { await model.fetchPreview() } }
                    .disabled(SteamWorkshopService.extractItemId(from: model.urlString) == nil || model.isFetchingPreview || model.isDownloading)
            }

            if model.isFetchingPreview {
                ProgressView("Fetching item info…")
                    .frame(maxWidth: .infinity)
            } else if let preview = model.preview {
                VStack(alignment: .leading, spacing: 10) {
                    if let imageURL = preview.previewImageURL {
                        RetryingAsyncImage(url: imageURL) { phase in
                            if let image = phase.image {
                                // No fixed ratio — lets each item's own preview image dictate its
                                // height instead of letterboxing/cropping it into a fixed shape.
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                // Actual ratio isn't known until the image loads, so the
                                // placeholder just needs *a* reasonable guess for that instant.
                                Rectangle().fill(.quaternary).aspectRatio(4.0 / 3.0, contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Text(preview.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let fileSizeText = preview.fileSizeText {
                        Text(fileSizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if model.isDownloading {
                        ProgressView(model.downloadStatusLine.isEmpty ? "Starting steamcmd…" : model.downloadStatusLine)
                            .frame(maxWidth: .infinity)
                        Text("Keeps downloading if you close this.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Button("Download") {
                            guard let username = savedUsername else { return }
                            Task { await model.startDownload(username: username) }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }

    private func completedSummary(_ result: SteamWorkshopResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Download complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                summaryRow("Title", result.project.title)
                summaryRow("Type", result.project.type.capitalized)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            Button("Continue to Title & Tags") {
                viewModel.pendingSteamWorkshopDownload = result
                viewModel.isSteamWorkshopImportReveal = false
                model.reset()
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}
