//
//  LockScreenSync.swift
//  Wallwright
//
//  AerialsInjector registers the video with the system correctly, but that alone isn't enough —
//  by default the display sleeps ~30s after the screen locks, and the aerial ramps down to a
//  static frame on wake. This keeps the display awake for a while after the screen locks (on AC
//  power only, to avoid draining battery), so the injected aerial actually keeps playing, rather
//  than ramping down almost immediately.
//
//  Bounded to `assertionTimeout` below, not held for as long as the screen stays locked — confirmed
//  live (2026-08-25) via `pmset -g log` that an earlier, unbounded version held the assertion for
//  2h32m straight because nothing releases it until an actual unlock, which never happens if the
//  user just locks and walks away. The Mac never reached real sleep the whole time: "sleep prevented
//  by powerd" traced directly back to this assertion. The aerial ramping down to a static frame
//  after a while (the same fallback behavior this file exists to delay) is a fully acceptable
//  tradeoff against a locked Mac that can never sleep on its own.
//
//  Adapted from LivePaper (MIT License, Copyright (c) 2026 Raunak Gupta)
//  https://github.com/Raunik2/LivePaper
//

import Foundation
import IOKit.pwr_mgt
import os

/// Temporary diagnostic logging for the lock/screensaver "paused but not paused" bug — same
/// subsystem/category as `VideoWallpaperViewModel`'s own instance so both interleave in one query.
private let wallpaperDebugLog = Logger(subsystem: "com.wallwright.Wallwright", category: "VideoWallpaperDebug")

final class LockScreenSync {
    static let shared = LockScreenSync()

    /// Posted whenever `screenIsUnlocked` fires — the one signal confirmed (2026-07-30, live log
    /// analysis) to arrive reliably and promptly on every real unlock. `VideoWallpaperViewModel`
    /// listens for this directly instead of relying on `NSWindow.occlusionState`, which was found
    /// to sometimes simply never flip back to `.visible` for our wallpaper window after a lock
    /// cycle — a borderless, non-activating, always-behind window apparently isn't guaranteed
    /// reliable WindowServer occlusion tracking the way a normal window is.
    static let screenDidUnlockNotification = Notification.Name("Wallwright.LockScreenSync.screenDidUnlock")

    private var assertionID: IOPMAssertionID = 0
    private var started = false

    /// Kept minimal on purpose — just enough to smooth over a quick step-away without the aerial
    /// ramping down to a static frame at the default ~30s, but not so long that it meaningfully
    /// delays real sleep for anyone who locks and actually leaves.
    private static let assertionTimeout: TimeInterval = 2 * 60
    private var assertionExpiryTimer: Timer?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        // The BSD/Darwin notification names for lock state (NOT the DistributedNotificationCenter
        // names, which differ) — this is the reliable, kernel-level signal.
        CFNotificationCenterAddObserver(
            darwinCenter, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<LockScreenSync>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.screenLocked() }
            },
            "com.apple.sessionagent.screenIsLocked" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            darwinCenter, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<LockScreenSync>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.screenUnlocked() }
            },
            "com.apple.sessionagent.screenIsUnlocked" as CFString, nil, .deliverImmediately
        )

        // Screensaver activation/deactivation is a separate event from screen lock (it can fire
        // from idle without the screen ever locking) — posted on the DistributedNotificationCenter,
        // not the Darwin center used above. Names confirmed against LivePaper's own verified usage.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screensaverDidDeactivate),
            name: NSNotification.Name("com.apple.screensaver.didStop"), object: nil
        )
    }

    @objc private func screensaverDidDeactivate() {
        wallpaperDebugLog.notice("GROUND TRUTH: com.apple.screensaver.didStop received")
        AerialsInjector.shared.prewarmForNextActivation()
    }

    private func screenLocked() {
        wallpaperDebugLog.notice("GROUND TRUTH: screenIsLocked received")
        guard assertionID == 0, !BatteryMonitor.checkOnBattery() else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Wallwright lock screen video" as CFString,
            &assertionID
        )
        assertionExpiryTimer?.invalidate()
        assertionExpiryTimer = Timer.scheduledTimer(withTimeInterval: Self.assertionTimeout, repeats: false) { [weak self] _ in
            self?.releaseAssertion()
        }
    }

    private func releaseAssertion() {
        assertionExpiryTimer?.invalidate()
        assertionExpiryTimer = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    private func screenUnlocked() {
        wallpaperDebugLog.notice("GROUND TRUTH: screenIsUnlocked received")
        NotificationCenter.default.post(name: Self.screenDidUnlockNotification, object: nil)
        releaseAssertion()

        // Pre-warm for the *next* activation right here, while back on the normal desktop, rather
        // than at the moment of the next lock/screensaver — a WallpaperAgent restart takes real
        // time, and doing it exactly when the screen is trying to show the aerial produces a
        // visible black gap before the video appears. Doing it now instead means the restart is
        // already settled by the time anything needs to actually display it.
        AerialsInjector.shared.prewarmForNextActivation()
    }
}
