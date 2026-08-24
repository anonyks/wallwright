//
//  CommandListener.swift
//  Wallwright
//
//  Lets a terminal or script control the app via a named pipe:
//    echo "pause"      > /tmp/wallwright.pipe
//    echo "resume"     > /tmp/wallwright.pipe
//    echo "volume 50"  > /tmp/wallwright.pipe
//    echo "quit"       > /tmp/wallwright.pipe
//
//  Adapted from LivePaper (MIT License, Copyright (c) 2026 Raunak Gupta)
//  https://github.com/Raunik2/LivePaper
//

import AppKit

final class CommandListener {
    static let shared = CommandListener()

    private let path = "/tmp/wallwright.pipe"
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
                // The FIFO node itself is missing (e.g. someone deleted /tmp/wallwright.pipe by
                // hand) — recreate it and retry. Rare enough that a plain `continue` (no delay) is
                // fine; `mkfifo` failing repeatedly this fast would mean something is seriously
                // wrong with /tmp, not something a sleep would help with.
                unlink(path)
                mkfifo(path, 0o600)
                continue
            }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            readLoop: while true {
                let bytesRead = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                switch bytesRead {
                case ..<0, 0: break readLoop // error, or EOF once the writer closes
                default: data.append(contentsOf: buffer[0..<bytesRead])
                }
            }
            close(fd)

            if let contents = String(data: data, encoding: .utf8) {
                let command = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.handle(command) }
                }
            }

            unlink(path)
            // 0600, not 0644 — this pipe's whole purpose is accepting commands, so it shouldn't be
            // world-readable to every other local account on a shared Mac (which 644 was: nobody
            // but the owner could write to it, but any user could still watch commands go by).
            mkfifo(path, 0o600)
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
