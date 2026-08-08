//
//  VideoTranscoder.swift
//  Wallwright
//
//  Ensures a video file is something AVFoundation can actually decode (H.264/HEVC inside an
//  mp4/mov/m4v container) — shared by YtDlpService (YouTube downloads can come back as AV1/VP9)
//  and VideoImporter (manual imports can be any container ffmpeg understands, e.g. .mkv/.avi/
//  .webm), so the "make this playable" logic lives in exactly one place.
//

import Foundation

struct VideoFileInfo {
    let codec: String
    let width: Int
    let height: Int
}

enum VideoTranscoderError: LocalizedError {
    case ffmpegMissing
    case probeFailed
    case transcodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "ffmpeg is required to convert this video. Install it with: brew install ffmpeg"
        case .probeFailed:
            return "Couldn't read this video's format — it may be corrupt or an unsupported file"
        case .transcodeFailed(let message):
            return "Conversion failed: \(message)"
        }
    }
}

enum VideoTranscoder {
    /// No consumer display is 8K, and Apple's hardware H.264 encoder can't create a compression
    /// session above roughly 4K anyway — confirmed live: `Cannot create compression session:
    /// -12903` on a real 7680×4320 source, even with VideoToolbox's software fallback
    /// (`-allow_sw 1`). Capping here keeps every case on the fast hardware encode path instead of
    /// falling back to slow pure-software encoding.
    private static let maxWidth = 3840
    private static let maxHeight = 2160

    private static let compatibleCodecs: Set<String> = ["h264", "hevc"]
    /// Containers AVFoundation opens natively — anything else needs at least a remux even when
    /// the codec inside is already compatible (e.g. an already-H.264 .mkv).
    private static let nativeContainerExtensions: Set<String> = ["mp4", "mov", "m4v"]

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

    static var ffmpegPath: String? { resolveBinary(named: "ffmpeg") }
    static var ffprobePath: String? { resolveBinary(named: "ffprobe") }
    static var isAvailable: Bool { ffmpegPath != nil }

    static func probeVideoInfo(at url: URL) -> VideoFileInfo? {
        guard let ffprobe = ffprobePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,width,height",
            "-of", "csv=p=0", url.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // ffprobe's csv output order follows the -show_entries list: codec_name,width,height.
        let parts = line.split(separator: ",")
        guard parts.count >= 3, let width = Int(parts[1]), let height = Int(parts[2]) else { return nil }
        return VideoFileInfo(codec: String(parts[0]), width: width, height: height)
    }

    /// Returns a file guaranteed playable by AVFoundation — either `source` itself, untouched, if
    /// it's already a compatible codec in a native container, or a converted copy otherwise.
    /// `transcodedFrom` is nil in the first case, and set to the original file's info in the
    /// second so callers can show what happened.
    ///
    /// - Parameters:
    ///   - outputDirectory: Where the converted copy is written. Defaults to `source`'s own
    ///     directory (fine for YtDlpService's own temp downloads), but callers converting a file
    ///     the *user* owns (e.g. VideoImporter's manual imports) should pass a scratch directory
    ///     instead — writing a new file into a folder like ~/Downloads without being asked is its
    ///     own kind of surprise.
    ///   - deleteSourceOnSuccess: Whether to remove `source` once the converted copy exists.
    ///     Correct for ephemeral temp downloads; must be `false` for a user's own file — silently
    ///     deleting something the user didn't ask to delete is not this app's call to make.
    static func ensureCompatible(
        _ source: URL,
        outputDirectory: URL? = nil,
        deleteSourceOnSuccess: Bool = true,
        onConversionStart: @escaping (_ isReencode: Bool) -> Void = { _ in }
    ) async throws -> (url: URL, transcodedFrom: VideoFileInfo?) {
        guard let sourceInfo = probeVideoInfo(at: source) else { throw VideoTranscoderError.probeFailed }

        let isNativeContainer = nativeContainerExtensions.contains(source.pathExtension.lowercased())
        let isCompatibleCodec = compatibleCodecs.contains(sourceInfo.codec.lowercased())
        guard !(isNativeContainer && isCompatibleCodec) else { return (source, nil) }

        DispatchQueue.main.async { onConversionStart(!isCompatibleCodec) }

        let output: URL
        if isCompatibleCodec {
            do {
                // Already H.264/HEVC, just wrong container — a stream copy just repackages it
                // into mp4 (near-instant, lossless) instead of a full re-encode.
                output = try await convert(source, reencode: false, outputDirectory: outputDirectory, deleteSourceOnSuccess: deleteSourceOnSuccess)
            } catch {
                // Stream copy can fail on a container holding a codec mp4 simply can't hold (e.g.
                // DTS/FLAC audio in some .mkv rips) even though the video stream itself is fine —
                // fall back to a full re-encode, which is guaranteed compatible either way.
                output = try await convert(source, reencode: true, outputDirectory: outputDirectory, deleteSourceOnSuccess: deleteSourceOnSuccess)
            }
        } else {
            output = try await convert(source, reencode: true, outputDirectory: outputDirectory, deleteSourceOnSuccess: deleteSourceOnSuccess)
        }

        guard probeVideoInfo(at: output) != nil else { throw VideoTranscoderError.probeFailed }
        return (output, sourceInfo)
    }

    /// `reencode: false` does a stream copy (near-instant, lossless — just repackaging an
    /// already-compatible codec into an mp4 container). `reencode: true` actually re-encodes an
    /// incompatible codec (AV1/VP9/etc.) to H.264, scaled down to `maxWidth`×`maxHeight` if needed.
    private static func convert(_ source: URL, reencode: Bool, outputDirectory: URL?, deleteSourceOnSuccess: Bool) async throws -> URL {
        guard let ffmpeg = ffmpegPath else { throw VideoTranscoderError.ffmpegMissing }
        let destinationDir = outputDirectory ?? source.deletingLastPathComponent()
        let destination = destinationDir.appending(path: source.deletingPathExtension().lastPathComponent + "-h264.mp4")

        var arguments = ["-y", "-i", source.path]
        if reencode {
            arguments += [
                "-vf", "scale='min(\(maxWidth),iw)':'min(\(maxHeight),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2",
                "-c:v", "h264_videotoolbox", "-q:v", "65",
                "-c:a", "aac", "-b:a", "192k",
            ]
        } else {
            arguments += ["-c", "copy", "-movflags", "+faststart"]
        }
        arguments.append(destination.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrData.append(chunk)
        }

        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            // ffmpeg always prints its full version/build banner to stderr before any real error,
            // so surfacing the whole blob is nearly useless — pull out the actual failure lines
            // (anything ffmpeg itself flags with "Error"/"Invalid"/"failed") instead.
            let fullMessage = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let relevantLines = fullMessage?
                .split(separator: "\n")
                .filter { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("invalid") || $0.localizedCaseInsensitiveContains("failed") }
                .joined(separator: " ")
            let message = (relevantLines?.isEmpty == false ? relevantLines : fullMessage) ?? "unknown error"
            throw VideoTranscoderError.transcodeFailed(message)
        }
        if deleteSourceOnSuccess {
            try? FileManager.default.removeItem(at: source)
        }
        return destination
    }
}
