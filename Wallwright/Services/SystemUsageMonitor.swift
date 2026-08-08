//
//  SystemUsageMonitor.swift
//  Wallwright
//
//  On-demand CPU/memory sampling for this process. Deliberately not timer-driven — the wallpaper
//  and its stats should stay cheap, so this only samples when something actually asks (e.g. the
//  menu bar opens, or the Performance settings page appears), not continuously in the background.
//

import Foundation

enum SystemUsageMonitor {
    struct Snapshot {
        let cpuPercent: Double
        let memoryMB: Double

        var formatted: String {
            String(format: "CPU %.1f%% · Memory %.0f MB", cpuPercent, memoryMB)
        }
    }

    /// Synchronously samples this process's current CPU% and resident memory (MB) via `ps`,
    /// the same values Activity Monitor and `top` report.
    static func sample() -> Snapshot? {
        let pid = ProcessInfo.processInfo.processIdentifier

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "%cpu=,rss=", "-p", "\(pid)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let cpu = Double(parts[0]),
              let rssKB = Double(parts[1])
        else { return nil }

        return Snapshot(cpuPercent: cpu, memoryMB: rssKB / 1024)
    }
}
