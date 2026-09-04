//
//  VideoCropDetector.swift
//  Wallwright
//
//  Detects black bars baked into a video's own pixel content — some source material (old footage
//  upscaled into a wider "remaster," a downloaded clip with its own letterbox) has real black
//  borders that are part of the pixels themselves, not a container/gravity mismatch. No display-
//  time crop/fill setting can remove those without either showing them or cropping into the actual
//  content, since the display layer has no way to know where the "real" frame is. Confirmed live
//  (2026-08-21) on a real "4K Remaster" whose 3840x2160 frame pillarboxed genuinely-4:3 footage.
//
//  Uses ffmpeg's own `cropdetect` filter — the same well-established technique any video editor
//  uses for this — via the same subprocess conventions VideoTranscoder already uses.
//

import Foundation

struct VideoCropRect {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

enum VideoCropDetector {
    /// Samples 200 frames spread through the file and returns the crop rectangle ffmpeg agreed on
    /// most often. `nil` means either no real, consistent bar was found (the video already fills
    /// its own frame) or detection didn't produce a clear consensus — in both cases, nothing should
    /// be cropped.
    static func detectBlackBars(at url: URL, nativeWidth: Int, nativeHeight: Int) async -> VideoCropRect? {
        guard let ffmpeg = VideoTranscoder.ffmpegPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-hwaccel", "videotoolbox",
            "-i", url.path,
            "-vf", "cropdetect=24:16:0",
            "-frames:v", "200",
            "-f", "null", "-",
        ]
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // `syncQueue` serializes access to `stderrData` between this handler (fires on its own
        // background queue) and the read below — same fix as the identical pattern in
        // YtDlpService/SteamWorkshopService/VideoTranscoder.
        let syncQueue = DispatchQueue(label: "VideoCropDetector.detectBlackBars-sync")
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            syncQueue.sync { stderrData.append(chunk) }
        }
        guard (try? process.run()) != nil else { return nil }
        // Same class of bug as `YtDlpService.fetchInfo`'s missing timeout (see its doc comment) —
        // this is local ffmpeg work on a fixed 200-frame sample, normally seconds, but a corrupt or
        // pathological input could still make ffmpeg itself hang, and there was nothing here to
        // stop that from leaving "Checking for black bars…" spinning forever. If it does trip, the
        // partial cropdetect output already captured is still used below — a degraded consensus
        // from fewer samples, not a hard failure.
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, process.isRunning else { return }
            process.terminate()
        }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        timeoutTask.cancel()
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard let output = syncQueue.sync(execute: { String(data: stderrData, encoding: .utf8) }) else { return nil }
        return Self.consensusCrop(fromCropdetectOutput: output, nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Pure parsing/consensus step split out of `detectBlackBars` above so it's testable without a
    /// real ffmpeg subprocess — `output` is exactly that call's captured stderr text.
    static func consensusCrop(fromCropdetectOutput output: String, nativeWidth: Int, nativeHeight: Int) -> VideoCropRect? {
        guard let regex = try? NSRegularExpression(pattern: #"crop=\d+:\d+:\d+:\d+"#) else { return nil }

        // cropdetect prints one "crop=W:H:X:Y" line per analyzed frame — tallying and taking the
        // most common exact string is a simple, effective consensus across the sample (a single
        // stray reading from an unusually bright/dark frame doesn't skew the result).
        var counts: [String: Int] = [:]
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        regex.enumerateMatches(in: output, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: output) else { return }
            counts[String(output[matchRange]), default: 0] += 1
        }
        guard let winner = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let numbers = winner.dropFirst("crop=".count).split(separator: ":").compactMap { Int($0) }
        guard numbers.count == 4 else { return nil }
        let (width, height, x, y) = (numbers[0], numbers[1], numbers[2], numbers[3])

        // Only worth acting on for a real, meaningful border — a handful of pixels of encoding
        // noise rounds to a "crop" too, and re-encoding the whole file for that would cost real
        // time/quality for no visible benefit.
        guard nativeWidth > 0, nativeHeight > 0 else { return nil }
        let widthReduction = Double(nativeWidth - width) / Double(nativeWidth)
        let heightReduction = Double(nativeHeight - height) / Double(nativeHeight)
        guard widthReduction > 0.02 || heightReduction > 0.02 else { return nil }

        return VideoCropRect(x: x, y: y, width: width, height: height)
    }

    /// Crops `source` to `crop` via a fresh H.264 encode — same VideoToolbox settings
    /// `VideoTranscoder.convert` already uses for its own re-encodes, for consistent output
    /// quality/behavior — written to `destination`. Audio is re-encoded to AAC, same as
    /// `VideoTranscoder.convert` — not stream-copied: `VideoTranscoder.ensureCompatible`'s
    /// "already compatible" fast path only checks the VIDEO codec/container, never audio, so a
    /// native-container, compatible-video file with non-AAC audio (AC3, Opus, Vorbis — anything
    /// not valid in an MP4 container) can reach this already in the library, untouched. `-c:a copy`
    /// into this function's always-.mp4 `destination` would fail outright on exactly that audio.
    @discardableResult
    static func crop(_ source: URL, to crop: VideoCropRect, destination: URL) async throws -> (width: Int, height: Int) {
        guard let ffmpeg = VideoTranscoder.ffmpegPath else { throw VideoTranscoderError.ffmpegMissing }
        // `h264_videotoolbox` requires even width/height for 4:2:0 chroma subsampling (error
        // -12908 otherwise) — `VideoTranscoder.convert`'s own scale filter already guards against
        // this via `force_divisible_by=2`, but that's a `scale`-filter-specific parameter with no
        // equivalent on `crop`, so an odd crop rectangle (a real, reachable case: both
        // `detectBlackBars` and `EditWallpaperSheet`'s manual crop round normalized coordinates to
        // integers) reached ffmpeg here unguarded and failed the whole crop.
        let evenWidth = (crop.width / 2) * 2
        let evenHeight = (crop.height / 2) * 2
        // `x`/`y` need the same even-rounding as width/height above — ffmpeg's `yuv420p` chroma
        // subsampling requires the crop rectangle's offset, not just its size, to land on an even
        // pixel boundary. Rounding down (never up) is what keeps this safe: it can only shrink `x`/
        // `y`, so the `x + width <= in_w` bound `applyCrop`'s clamping already establishes still
        // holds — rounding up could push the rectangle back out of bounds.
        let evenX = (crop.x / 2) * 2
        let evenY = (crop.y / 2) * 2
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-i", source.path,
            "-vf", "crop=\(evenWidth):\(evenHeight):\(evenX):\(evenY)",
            "-c:v", "h264_videotoolbox", "-q:v", "65",
            "-c:a", "aac", "-b:a", "192k",
            destination.path,
        ]
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // `syncQueue` serializes access to `stderrData` — see `detectBlackBars`'s identical fix
        // above for why.
        let syncQueue = DispatchQueue(label: "VideoCropDetector.crop-sync")
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            syncQueue.sync { stderrData.append(chunk) }
        }
        try process.run()
        // A generous 5-minute ceiling, not a tight one — unlike `detectBlackBars`'s fixed 200-frame
        // sample, this re-encodes the whole file, and a legitimately long wallpaper on a slow
        // machine deserves real time. Still bounded, though: a truly stuck ffmpeg process (rare,
        // but real on certain malformed inputs) would otherwise hang this forever with no way for
        // the caller to know something's wrong.
        var timedOut = false
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut = true
            process.terminate()
        }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        timeoutTask.cancel()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0, !timedOut else {
            if timedOut { throw VideoTranscoderError.transcodeFailed("Timed out after 5 minutes") }
            let message = syncQueue.sync { String(data: stderrData, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VideoTranscoderError.transcodeFailed(message?.isEmpty == false ? message! : "ffmpeg exited with status \(process.terminationStatus)")
        }
        return (evenWidth, evenHeight)
    }
}
