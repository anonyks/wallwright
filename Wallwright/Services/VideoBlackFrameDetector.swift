//
//  VideoBlackFrameDetector.swift
//  Wallwright
//
//  Detects leading/trailing solid-black stretches in a video — a fade-in-from-black intro or
//  fade-to-black outro reads as the desktop going briefly dark every time a looping live wallpaper
//  restarts. Playback already supports trimming around this (`WEProject.trimStart`/`trimEnd`, see
//  their own doc comment) but only via manually scrubbing to a point and clicking "Set Trim Start"/
//  "Set Trim End" — this finds the black stretches automatically instead.
//
//  Uses ffmpeg's own `blackdetect` filter, same subprocess conventions as VideoCropDetector.
//

import Foundation

struct VideoBlackTrim {
    let trimStart: Double?
    let trimEnd: Double?
}

enum VideoBlackFrameDetector {
    /// `duration` is the file's already-known length (`WEProject.videoDuration`) — needed to tell a
    /// trailing black interval (one that runs to the end of the file) apart from an unrelated black
    /// moment somewhere in the middle, which should never affect the trim range.
    static func detectBlackTrim(at url: URL, duration: Double) async -> VideoBlackTrim? {
        guard duration.isFinite, duration > 0 else { return nil }
        guard let ffmpeg = VideoTranscoder.ffmpegPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", url.path,
            // `d=0.1`: ignore anything shorter than a tenth of a second — a single dark frame from
            // normal content (a scene cut, a blink of motion blur) shouldn't count. `pix_th=0.10`:
            // ffmpeg's own default, "pixel counts as black below 10% luma" — permissive enough to
            // still catch a black that's carrying a little compression noise.
            "-vf", "blackdetect=d=0.1:pix_th=0.10",
            "-an",
            "-f", "null", "-",
        ]
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // `syncQueue` serializes access to `stderrData` — same fix as VideoCropDetector's identical
        // pattern for why (the readability handler fires on its own background queue).
        let syncQueue = DispatchQueue(label: "VideoBlackFrameDetector.detectBlackTrim-sync")
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            syncQueue.sync { stderrData.append(chunk) }
        }
        guard (try? process.run()) != nil else { return nil }
        // Same class of bug as VideoCropDetector.detectBlackBars' identical timeout — this decodes
        // the whole file start-to-finish (unlike cropdetect's fixed 200-frame sample), but a
        // pathological input could still hang ffmpeg indefinitely with nothing here to stop it.
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
        return Self.trim(fromBlackdetectOutput: output, duration: duration)
    }

    /// Pure parsing step split out of `detectBlackTrim` above so it's testable without a real
    /// ffmpeg subprocess — `output` is exactly that call's captured stderr text.
    static func trim(fromBlackdetectOutput output: String, duration: Double) -> VideoBlackTrim? {
        guard let regex = try? NSRegularExpression(
            pattern: #"black_start:([\d.]+) black_end:([\d.]+)"#
        ) else { return nil }

        var intervals: [(start: Double, end: Double)] = []
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        regex.enumerateMatches(in: output, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 3,
                  let startRange = Range(match.range(at: 1), in: output),
                  let endRange = Range(match.range(at: 2), in: output),
                  let start = Double(output[startRange]),
                  let end = Double(output[endRange]) else { return }
            intervals.append((start, end))
        }
        guard !intervals.isEmpty else { return nil }

        // Leading: a black interval that actually starts at (or within a couple frames of) 0 — one
        // that starts a second or two in is real content that happens to briefly cut to black, not
        // an intro fade, and shouldn't be trimmed away.
        let leading = intervals.first(where: { $0.start < 0.2 })
        // Trailing: a black interval that runs to (or within a couple frames of) the end of the file.
        let trailing = intervals.last(where: { duration - $0.end < 0.2 })

        var trimStart = leading?.end
        var trimEnd = trailing?.start

        // Refuse a nonsensical single-sided range — e.g. a clip that's entirely (or almost
        // entirely) black, where "trim away the black" would leave nothing worth playing.
        if let start = trimStart, start >= duration * 0.9 { trimStart = nil }
        if let end = trimEnd, end <= duration * 0.1 { trimEnd = nil }
        // And a nonsensical two-sided range — leading/trailing black overlapping because the whole
        // file is effectively one continuous black interval.
        if let start = trimStart, let end = trimEnd, start >= end {
            trimStart = nil
            trimEnd = nil
        }

        guard trimStart != nil || trimEnd != nil else { return nil }
        return VideoBlackTrim(trimStart: trimStart, trimEnd: trimEnd)
    }
}
