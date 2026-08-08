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

    private func listen() {
        while true {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let command = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.handle(command) }
            }
            unlink(path)
            // 0600, not 0644 — this pipe's whole purpose is accepting commands, so it shouldn't be
        // world-readable to every other local account on a shared Mac (which 644 was: nobody but
        // the owner could write to it, but any user could still watch commands go by).
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
