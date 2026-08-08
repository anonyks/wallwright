//
//  YouTubeImportSheet.swift
//  Wallwright
//
//  Downloads a video via yt-dlp (max quality, optional audio, optional trim), then hands the
//  result to the same enqueueImports/ImportReviewSheet pipeline manual folder imports use — so
//  title/tag review happens exactly once, in one place, rather than duplicating that UI here.
//
//  State lives on `model` (YouTubeImportViewModel), not local `@State` — this is presented as a
//  click-outside-to-dismiss popup (see ContentView), not a modal `.sheet`, specifically so you can
//  dismiss it while a download is running and come back to see where it's at, instead of the
//  progress vanishing the moment the view disappears.
//

import SwiftUI

struct YouTubeImportSheet: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var model: YouTubeImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from YouTube")
                .font(.title2.weight(.semibold))

            if !YtDlpService.isAvailable {
                Label("yt-dlp isn't installed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Install it (and ffmpeg, used for merging/trimming) with Homebrew, then reopen this:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("brew install yt-dlp ffmpeg")
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            } else if let downloadResult = model.downloadResult {
                completedSummary(downloadResult)
            } else {
                HStack {
                    TextField("YouTube URL", text: $model.urlString)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isFetchingInfo || model.isDownloading)
                        .onSubmit { Task { await model.fetchInfo() } }
                    Button("Fetch") { Task { await model.fetchInfo() } }
                        .disabled(model.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isFetchingInfo || model.isDownloading)
                }

                if model.isFetchingInfo {
                    ProgressView("Fetching video info…")
                        .frame(maxWidth: .infinity)
                } else if let videoInfo = model.videoInfo {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(videoInfo.title)
                            .font(.headline)
                            .lineLimit(2)

                        if videoInfo.width > 0 {
                            qualityEstimate(videoInfo)
                        }

                        Toggle("Include Audio", isOn: $model.includeAudio)
                            .disabled(model.isDownloading)

                        if videoInfo.duration > 0 {
                            Toggle("Trim", isOn: $model.trimEnabled)
                                .disabled(model.isDownloading)

                            if model.trimEnabled {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Start").frame(width: 40, alignment: .leading)
                                        Slider(value: $model.trimStart, in: 0...max(videoInfo.duration - 1, 0))
                                            .disabled(model.isDownloading)
                                            .onChange(of: model.trimStart) { _, newValue in
                                                if model.trimEnd <= newValue { model.trimEnd = min(newValue + 1, videoInfo.duration) }
                                            }
                                        Text(Self.formatTime(model.trimStart)).monospacedDigit().frame(width: 56)
                                    }
                                    HStack {
                                        Text("End").frame(width: 40, alignment: .leading)
                                        Slider(value: $model.trimEnd, in: 0...videoInfo.duration)
                                            .disabled(model.isDownloading)
                                            .onChange(of: model.trimEnd) { _, newValue in
                                                if model.trimStart >= newValue { model.trimStart = max(newValue - 1, 0) }
                                            }
                                        Text(Self.formatTime(model.trimEnd)).monospacedDigit().frame(width: 56)
                                    }
                                }
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        if model.isTranscoding {
                            ProgressView("Converting for compatibility…")
                                .frame(maxWidth: .infinity)
                        } else if model.isDownloading {
                            ProgressView(value: model.downloadProgress)
                            Text("\(Int(model.downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Keeps downloading if you close this.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Button("Download") { Task { await model.startDownload() } }
                                .buttonStyle(.glassProminent)
                        }
                    }
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
                Button(model.downloadResult != nil ? "Cancel" : "Close") {
                    viewModel.isYouTubeImportReveal = false
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 460)
    }

    private func qualityEstimate(_ info: YtDlpVideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Best available: \(info.width)×\(info.height)" + (info.vcodec.map { " · \(Self.codecLabel($0))" } ?? ""))
                if let size = info.approxFileSizeBytes {
                    Text("· ~\(Self.formatBytes(size))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let vcodec = info.vcodec, !Self.isNativelyCompatible(vcodec) {
                Text("Will be converted to H.264 after downloading.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func completedSummary(_ result: YtDlpDownloadResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Download complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                summaryRow("Resolution", "\(result.finalInfo.width)×\(result.finalInfo.height)")
                summaryRow("Codec", Self.codecLabel(result.finalInfo.codec))
                summaryRow("File Size", Self.formatBytes(result.fileSizeBytes))
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            if let original = result.transcodedFrom {
                Text("Converted from \(Self.codecLabel(original.codec)) \(original.width)×\(original.height) to \(Self.codecLabel(result.finalInfo.codec)) \(result.finalInfo.width)×\(result.finalInfo.height) for compatibility. The original file has been deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Continue to Title & Tags") {
                viewModel.pendingYouTubeDownload = result.fileURL
                viewModel.isYouTubeImportReveal = false
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

    private static func isNativelyCompatible(_ vcodec: String) -> Bool {
        let lowered = vcodec.lowercased()
        return lowered.hasPrefix("avc1") || lowered.hasPrefix("h264") || lowered.hasPrefix("hev1") || lowered.hasPrefix("hvc1")
    }

    private static func codecLabel(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("avc1") || lowered == "h264" { return "H.264" }
        if lowered.hasPrefix("hev1") || lowered.hasPrefix("hvc1") || lowered == "hevc" { return "HEVC" }
        if lowered.hasPrefix("av01") || lowered == "av1" { return "AV1" }
        if lowered.hasPrefix("vp9") { return "VP9" }
        if lowered.hasPrefix("vp09") { return "VP9" }
        return raw
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
