//
//  SystemUsageMonitor.swift
//  Wallwright
//
//  On-demand CPU/memory sampling for this process. Deliberately not timer-driven — the wallpaper
//  and its stats should stay cheap, so this only samples when something actually asks (e.g. the
//  menu bar opens, or the Performance settings page appears), not continuously in the background.
//

import Darwin
import Foundation

enum SystemUsageMonitor {
    struct Snapshot {
        let cpuPercent: Double
        let memoryMB: Double

        var formatted: String {
            String(format: "CPU %.1f%% · Memory %.0f MB", cpuPercent, memoryMB)
        }
    }

    /// Guards against concurrent samples piling up separate blocking GCD worker threads — every
    /// caller already dispatches `sample()` onto `DispatchQueue.global`, a shared, bounded thread
    /// pool, and `sample()` itself blocks its calling thread for the full 3s window below (see
    /// `currentCPUPercent`'s own doc comment for why that's deliberate). Opening/closing the menu
    /// bar item repeatedly, or clicking the Performance page's refresh button a few times in a row,
    /// used to spawn a fresh 3-second-blocking thread for each click with nothing coalescing them —
    /// harmless once, but real thread-pool pressure under rapid repeated use, since GCD's global
    /// concurrent queues are shared with every other background task in the app (thumbnail decode,
    /// transcoding progress, etc.). A sample already in flight now serves its own in-progress result
    /// to any caller that shows up while it's running, instead of starting a second blocking sample.
    private static let stateLock = NSLock()
    private static var isSampling = false
    private static var lastSnapshot: Snapshot?

    /// Samples this process's *current* CPU% and real physical memory footprint.
    ///
    /// Previously shelled out to `ps -o %cpu=,rss=`, with a doc comment claiming that matched
    /// "the same values Activity Monitor and top report" — confirmed live (2026-08-08) that was
    /// wrong on both counts. `rss` undercounts the real footprint Activity Monitor/`leaks`/
    /// Stats.app report by a wide margin for an app like this (measured 370MB via `rss` against a
    /// real 679MB physical footprint at the same instant). `ps`'s `%cpu` is a cumulative average
    /// since the process launched, not a live reading — it showed 6.4% for a process idling at
    /// genuinely 0% CPU (confirmed via repeated live `top` samples), because it was smearing
    /// earlier activity (wallpaper switches, testing) across the process's entire lifetime instead
    /// of reporting what's happening right now.
    ///
    /// Reads Darwin's own task info directly instead — `phys_footprint` from `TASK_VM_INFO` is
    /// the exact figure Activity Monitor's Memory column and `leaks` report. CPU is measured over
    /// a short live window (two `getrusage` samples ~150ms apart) rather than an average since
    /// launch — still only runs when something actually asks, not on a background timer.
    static func sample() -> Snapshot? {
        stateLock.lock()
        if isSampling {
            let cached = lastSnapshot
            stateLock.unlock()
            return cached
        }
        isSampling = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            isSampling = false
            stateLock.unlock()
        }

        guard let memoryMB = physicalFootprintMB() else { return lastSnapshot }
        let cpuPercent = currentCPUPercent() ?? 0
        let snapshot = Snapshot(cpuPercent: cpuPercent, memoryMB: memoryMB)
        stateLock.lock()
        lastSnapshot = snapshot
        stateLock.unlock()
        return snapshot
    }

    private static func physicalFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    private static func cpuTimeSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + sys
    }

    /// A live-windowed CPU%, not a since-launch average — samples total CPU time consumed, waits,
    /// samples again, and reports the fraction of wall-clock time that was actual CPU time in
    /// between. Confirmed live (2026-08-08): an earlier 150ms window was too short — short enough
    /// that it was prone to catching a genuine but brief burst (e.g. the very act of building and
    /// rendering the menu this is called from) and reporting it as if it were the sustained rate,
    /// showing 22% while `top`, sampled repeatedly around the same moment, read 0% the whole time.
    ///
    /// Widened from an initial 1s to 3s — confirmed live (2026-08-31) that this app's real workload
    /// (video decode) is itself bursty, not steady, so even a 1s window could land squarely in a
    /// burst or a lull and report very different numbers for two checks taken a few seconds apart
    /// (0% vs 13.2%, same app, same moment in practice) — not a bug in the sampling code, just too
    /// short a window for a bursty workload. 3s averages across enough of that burst/lull cycle to
    /// give a stable, repeatable number instead. Only ever happens on a background thread (every
    /// call site already dispatches this off-main), so the longer wait never blocks the UI it's
    /// reporting on; the caller already shows a placeholder while this runs.
    private static func currentCPUPercent() -> Double? {
        guard let start = cpuTimeSeconds() else { return nil }
        let wallStart = Date()
        Thread.sleep(forTimeInterval: 3.0)
        guard let end = cpuTimeSeconds() else { return nil }
        let wallElapsed = Date().timeIntervalSince(wallStart)
        guard wallElapsed > 0 else { return nil }
        return max(0, (end - start) / wallElapsed) * 100
    }
}
