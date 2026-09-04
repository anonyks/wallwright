//
//  CommandListener.swift
//  Wallwright
//
//  Lets a terminal or script control the app via a named pipe (substitute your own UID for
//  `501` — `id -u`):
//    echo "pause"      > /tmp/wallwright-501.pipe
//    echo "resume"     > /tmp/wallwright-501.pipe
//    echo "volume 50"  > /tmp/wallwright-501.pipe
//    echo "next"       > /tmp/wallwright-501.pipe
//    echo "prev"       > /tmp/wallwright-501.pipe
//    echo "quit"       > /tmp/wallwright-501.pipe
//
//  Adapted from LivePaper (MIT License, Copyright (c) 2026 Raunak Gupta)
//  https://github.com/Raunik2/LivePaper
//

import AppKit

final class CommandListener {
    static let shared = CommandListener()

    // UID-scoped, not a bare `/tmp/wallwright.pipe` — `/tmp` has the sticky bit set, so only the
    // file's owner (or root) can `unlink`/replace it. Under Fast User Switching, a second user
    // launching Wallwright while the first user's instance is still running (and still owns the
    // existing FIFO, mode 0600) would hit `unlink`/`mkfifo`/`open` all failing on permissions —
    // `listen()`'s error path retries every 0.5s forever with no way to ever succeed, since
    // nothing about the failure is transient. Scoping the path per-user means two users' instances
    // never contend for the same node at all.
    private let path = "/tmp/wallwright-\(getuid()).pipe"
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        unlink(path)
        // 0600, not 0644 — this pipe's whole purpose is accepting commands, so it shouldn't be
        // world-readable to every other local account on a shared Mac (which 644 was: nobody but
        // the owner could write to it, but any user could still watch commands go by).
        mkfifo(path, 0o600)
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.listen() }
    }

    /// `String(contentsOfFile:)` doesn't give a true blocking FIFO read — confirmed live
    /// (2026-08-09) via `sample`: this thread spent 2550 of 2554 profiled samples sitting in
    /// `Thread.sleep(forTimeInterval:)`, meaning the read was failing/returning immediately and
    /// this was busy-retrying on a 0.5s cycle for the entire life of the app. A cheap wakeup twice
    /// a second still means the CPU never reaches its deepest idle state — exactly what Activity
    /// Monitor's Energy Impact penalizes, independent of raw %CPU looking like ~0.
    ///
    /// Opening the FIFO with the raw POSIX `open()`/`read()` calls instead gives the behavior a
    /// named pipe is actually meant to have: `open` blocks until a writer connects, `read` blocks
    /// until data arrives or the writer closes — genuine event-driven waiting, zero wakeups, no
    /// polling, until a command actually shows up.
    private func listen() {
        while true {
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else {
                // The FIFO node itself is missing or unopenable — recreate it and wait briefly
                // before retrying to prevent an unthrottled 100% CPU busy-spin loop.
                unlink(path)
                mkfifo(path, 0o600)
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            // Every real command in the header comment above is a couple of words — a writer that
            // never closes (`cat /dev/zero > pipe`, a runaway script) would otherwise make `data`
            // grow without bound for as long as it keeps streaming, since this loop only stops on
            // EOF/error. 64KB is generous for any legitimate command while still capping the worst
            // case; once past it, the excess is simply not read into memory (the fd is still
            // drained below so `read` doesn't block a well-behaved writer forever).
            let maxCommandBytes = 65536
            readLoop: while true {
                let bytesRead = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                switch bytesRead {
                case ..<0, 0: break readLoop // error, or EOF once the writer closes
                default:
                    if data.count < maxCommandBytes {
                        data.append(contentsOf: buffer[0..<bytesRead])
                    }
                }
            }
            close(fd)

            if let contents = String(data: data, encoding: .utf8) {
                // One write to the pipe can carry multiple newline-separated commands (e.g. a
                // script doing `printf "pause\nvolume 50\n" > pipe` in one shot) — trimming only
                // the outer whitespace and handling the whole blob as a single command left an
                // embedded "\n" inside `parts.first`, which matched none of the switch's cases and
                // silently dropped every command in the batch. Splitting first means each line
                // gets its own, independent dispatch to `handle`.
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !command.isEmpty else { continue }
                    DispatchQueue.main.async { [weak self] in self?.handle(command) }
                }
            }
        }
    }

    private func handle(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1)
        switch parts.first {
        case "pause":
            AppDelegate.shared.wallpaperViewModel.isPausedByUser = true
            AppDelegate.shared.pause()
        case "resume", "play":
            AppDelegate.shared.wallpaperViewModel.isPausedByUser = false
            AppDelegate.shared.resume()
        case "mute": AppDelegate.shared.mute()
        case "unmute": AppDelegate.shared.unmute()
        case "volume":
            if parts.count > 1, let value = Float(parts[1]) {
                AppDelegate.shared.wallpaperViewModel.playVolume = max(0, min(1, value / 100))
            }
        case "next", "skip": AppDelegate.shared.skipToNextPlaylistItem()
        case "prev", "previous": AppDelegate.shared.skipToPreviousPlaylistItem()
        case "quit": NSApplication.shared.terminate(nil)
        case "toggleclock":
            AppDelegate.shared.globalSettingsViewModel.settings.showClockOverlay.toggle()
        case "clockalignment":
            if parts.count > 1, let alignment = GSClockTextAlignment(rawValue: String(parts[1])) {
                AppDelegate.shared.globalSettingsViewModel.settings.clockTextAlignment = alignment
            }
        default: break
        }
    }
}
