//
//  YtDlpService.swift
//  Wallwright
//
//  Downloads a video from YouTube (or anything else yt-dlp supports) via a system-installed
//  yt-dlp binary — shelled out to, not bundled, since it's a large, frequently-updated Python
//  tool that users installing it via Homebrew already keep current on their own.
//

import Foundation

struct YtDlpVideoInfo {
    let title: String
    /// Seconds; 0 if yt-dlp couldn't report one (e.g. a livestream).
    let duration: Double
    /// The resolution/codec yt-dlp's default format selection (matching `download`'s `-f`) would
    /// actually pick — shown to the user before they commit to downloading anything.
    let width: Int
    let height: Int
    let vcodec: String?
    let approxFileSizeBytes: Int64?
}

struct YtDlpDownloadResult {
    let fileURL: URL
    let fileSizeBytes: Int64
    /// The codec/resolution actually written to disk after any compatibility transcode.
    let finalInfo: VideoFileInfo
    /// Set when the source wasn't H.264/HEVC and had to be re-encoded; nil means the original
    /// download was already compatible and used as-is.
    let transcodedFrom: VideoFileInfo?
}

enum YtDlpError: LocalizedError {
    case notInstalled
    case ffmpegMissing
    case invalidURL
    case fetchFailed(String)
    case downloadFailed(String)
    case resultNotFound

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "yt-dlp isn't installed. Install it with: brew install yt-dlp ffmpeg"
        case .ffmpegMissing:
            return "ffmpeg is required (yt-dlp uses it to merge video/audio and trim). Install it with: brew install ffmpeg"
        case .invalidURL:
            return "That doesn't look like a valid URL"
        case .fetchFailed(let message):
            return "Couldn't fetch video info: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .resultNotFound:
            return "yt-dlp finished but the downloaded file couldn't be found"
        }
    }
}

enum YtDlpService {
    /// Checked in order before falling back to a PATH lookup — a GUI-launched app's process
    /// environment often doesn't include Homebrew's bin directory on PATH the way an interactive
    /// Terminal session does, so the common install locations are tried directly first.
    private static func resolveBinary(named name: String) -> String? {
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        guard which.terminationStatus == 0,
              let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }

    static var ytDlpPath: String? { resolveBinary(named: "yt-dlp") }
    static var isAvailable: Bool { ytDlpPath != nil }

    /// Fetches title/duration/expected quality without downloading any video data.
    static func fetchInfo(url: String) async throws -> YtDlpVideoInfo {
        guard let ytDlp = ytDlpPath else { throw YtDlpError.notInstalled }
        let (data, errData, status) = try await run(ytDlp, arguments: ["--dump-json", "--no-playlist", "--no-warnings", url])
        guard status == 0, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw YtDlpError.fetchFailed(message?.isEmpty == false ? message! : "unknown error")
        }
        let title = (json["title"] as? String) ?? "Untitled"
        let duration = (json["duration"] as? Double) ?? (json["duration"] as? Int).map(Double.init) ?? 0
        let width = (json["width"] as? Int) ?? 0
        let height = (json["height"] as? Int) ?? 0
        let vcodec = json["vcodec"] as? String
        let approxSize = (json["filesize"] as? Int) ?? (json["filesize_approx"] as? Int)
        return YtDlpVideoInfo(
            title: title, duration: duration, width: width, height: height,
            vcodec: vcodec, approxFileSizeBytes: approxSize.map(Int64.init)
        )
    }

    /// Downloads at the best available quality, merged to mp4. When `start`/`end` are given,
    /// trims directly during download via `--download-sections` — yt-dlp/ffmpeg only fetch and
    /// keep that range, rather than downloading the whole thing and cutting it afterward.
    static func download(
        url: String,
        includeAudio: Bool,
        start: Double?,
        end: Double?,
        onProgress: @escaping (Double) -> Void,
        onTranscodingStart: @escaping () -> Void = {}
    ) async throws -> YtDlpDownloadResult {
        guard let ytDlp = ytDlpPath else { throw YtDlpError.notInstalled }
        guard VideoTranscoder.isAvailable else { throw YtDlpError.ffmpegMissing }

        let workDir = FileManager.default.temporaryDirectory.appending(path: "ytdlp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        var arguments = [
            "-f", includeAudio ? "bv*+ba/b" : "bv*",
            "--merge-output-format", "mp4",
            "--no-playlist",
            "--no-warnings",
            "--newline",
            "-o", workDir.appending(path: "%(title)s.%(ext)s").path,
        ]
        if let start, let end, end > start {
            arguments += ["--download-sections", "*\(Self.formatTimestamp(start))-\(Self.formatTimestamp(end))", "--force-keyframes-at-cuts"]
        }
        arguments.append(url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                if let percent = Self.parseProgress(String(line)) {
                    DispatchQueue.main.async { onProgress(percent) }
                }
            }
        }
        // Must also be drained continuously (not just read after exit) — yt-dlp's own stderr
        // warnings can exceed the pipe buffer during a long download and deadlock the process
        // otherwise, same as the stdout JSON blob in fetchInfo's run().
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrData.append(chunk)
        }

        // Everything from here on can throw before ever producing a result the caller will take
        // ownership of (and thus clean up itself, via `ContentViewModel.cleanupScratchSource` once
        // the file reaches the review-sheet flow) — any such failure has to clean up `workDir`
        // itself here, or a failed/cancelled download just leaves its full video download sitting
        // in `/tmp` forever. Confirmed live: this was previously unhandled on every error path.
        do {
            try process.run()
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            guard process.terminationStatus == 0 else {
                let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw YtDlpError.downloadFailed(message?.isEmpty == false ? message! : "yt-dlp exited with status \(process.terminationStatus)")
            }

            // Scan rather than parse yt-dlp's own path-printing output — simpler and doesn't depend
            // on stdout buffering having flushed the last line before the process actually exits.
            //
            // Checks against `importableExtensions`, not just `nativeExtensions` — `--merge-output-
            // format mp4` only takes effect when yt-dlp actually runs its merge step (separate video +
            // audio streams muxed together), which only happens when audio is requested. With audio
            // off, "-f bv*" downloads a single video-only stream and skips merging entirely, so the
            // file keeps whatever container that stream naturally came in — for YouTube's higher-
            // quality renditions that's usually VP9/AV1 in a `.webm` container, not mp4. Restricting
            // the scan to native extensions meant a perfectly successful download with audio unchecked
            // was reported as "file couldn't be found" (confirmed live 2026-07-29). `ensureCompatible`
            // right below already transcodes any of these into a playable H.264 mp4 regardless.
            guard let downloaded = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                .first(where: { VideoImporter.importableExtensions.contains($0.pathExtension.lowercased()) })
            else {
                throw YtDlpError.resultNotFound
            }

            // "bv*" picks the best available video stream regardless of codec, and YouTube now
            // serves its highest-bitrate/4K+ renditions as AV1 (or VP9) rather than H.264 — but
            // AVFoundation (AVAssetImageGenerator for the thumbnail, AVPlayer for actual playback)
            // can't reliably decode those on most Macs. `ensureCompatible` re-encodes to H.264 when
            // needed (matching the manual `ffmpeg -c:v h264_videotoolbox` workaround), keeping the
            // "max quality" source download intact while guaranteeing the output is always playable.
            do {
                let (finalURL, transcodedFrom) = try await VideoTranscoder.ensureCompatible(downloaded) { _ in onTranscodingStart() }
                guard let finalInfo = VideoTranscoder.probeVideoInfo(at: finalURL) else { throw YtDlpError.resultNotFound }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? nil
                return YtDlpDownloadResult(
                    fileURL: finalURL,
                    fileSizeBytes: fileSize ?? 0,
                    finalInfo: finalInfo,
                    transcodedFrom: transcodedFrom
                )
            } catch let error as VideoTranscoderError {
                throw YtDlpError.downloadFailed(error.errorDescription ?? "conversion failed")
            }
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            throw error
        }
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func parseProgress(_ line: String) -> Double? {
        // With --newline, yt-dlp prints one line per update like "[download]  42.5% of ...".
        guard line.contains("[download]"),
              let range = line.range(of: #"[\d.]+%"#, options: .regularExpression)
        else { return nil }
        return Double(line[range].dropLast()).map { $0 / 100 }
    }

    /// Drains both pipes continuously via `readabilityHandler` rather than reading after the
    /// process exits — `--dump-json` alone writes several hundred KB to stdout (full format
    /// list, thumbnails, subtitle tracks), which overflows the ~64KB OS pipe buffer. Once that
    /// buffer fills, yt-dlp blocks on write() waiting for a reader that only shows up after
    /// termination, and termination never comes: a classic Process/Pipe deadlock that manifested
    /// as "Fetching video info…" hanging forever.
    private static func run(_ executable: String, arguments: [String]) async throws -> (Data, Data, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutData.append(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrData.append(chunk)
        }

        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        return (stdoutData, stderrData, process.terminationStatus)
    }
}
