//
//  FullscreenAppMonitor.swift
//  Wallwright
//
//  Detects whether the desktop wallpaper is currently fully covered by something else, so "Other
//  Application Fullscreen" in Settings can actually pause/stop wallpaper playback while it's fully
//  obscured, instead of being a purely decorative picker.
//
//  Event-driven via NSWindow occlusion state rather than polling CGWindowListCopyWindowInfo every
//  5s: reacts to actual compositor visibility the instant it changes, costs nothing between
//  changes, and catches real full coverage regardless of which app (or apps, tiled together) is
//  doing the covering — the old size-heuristic only ever checked the single frontmost app's own
//  windows, missing e.g. a non-frontmost window left on top, or two windows together covering the
//  screen. "Occluded" here means every enabled wallpaper window is occluded — if the user can still
//  see the wallpaper on even one screen, this deliberately doesn't fire (matches the existing
//  single global pause/resume decision this drives; going finer-grained to per-screen pausing is a
//  separate, bigger change).
//

import AppKit
import os

private let wallpaperDebugLog = Logger(subsystem: "com.wallwright.Wallwright", category: "VideoWallpaperDebug")

final class FullscreenAppMonitor {
    static let shared = FullscreenAppMonitor()
    static let didChangeNotification = Notification.Name("FullscreenAppMonitor.didChange")

    private(set) var isOtherAppFullscreen = false {
        didSet {
            guard oldValue != isOtherAppFullscreen else { return }
            wallpaperDebugLog.notice("FullscreenAppMonitor.isOtherAppFullscreen changed to \(self.isOtherAppFullscreen)")
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            isOtherAppFullscreen ? startSafetyNetTimer() : stopSafetyNetTimer()
        }
    }

    private var isObserving = false
    private var pendingRecomputeWorkItem: DispatchWorkItem?
    private var pendingFullscreenConfirmationWorkItem: DispatchWorkItem?
    private var isAwaitingFullscreenConfirmation = false

    /// Every trigger investigated so far (screen lock/unlock, and — confirmed live 2026-07-30 —
    /// macOS's "click wallpaper to reveal desktop" gesture) has, at some point, left our wallpaper
    /// windows' `NSWindow.occlusionState` reporting stale/wrong values for a while after the actual
    /// visual state already changed back. Chasing down a dedicated reliable signal for every single
    /// OS gesture that can transiently hide/reveal windows isn't tractable — this is a persistent
    /// fallback instead: as long as `isOtherAppFullscreen` reads true, keep re-checking every few
    /// seconds rather than trusting any one event to catch the moment it should flip back, so being
    /// stuck is bounded to a handful of seconds instead of indefinitely.
    private var safetyNetTimer: Timer?

    private func startSafetyNetTimer() {
        guard safetyNetTimer == nil else { return }
        safetyNetTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.recompute()
        }
    }

    private func stopSafetyNetTimer() {
        safetyNetTimer?.invalidate()
        safetyNetTimer = nil
    }

    private init() {}

    func startIfNeeded() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionStateDidChange),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil
        )
        // `recompute()`'s own occlusionState read isn't trustworthy after a lock/unlock cycle —
        // confirmed live (2026-07-30) our wallpaper windows' `occlusionState` can simply never
        // flip back to `.visible` post-unlock. A real unlock inherently means the user can see
        // their screen again, so trust that ground-truth signal directly instead of waiting on
        // occlusionState to (maybe never) catch up.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidUnlock),
            name: LockScreenSync.screenDidUnlockNotification, object: nil
        )
        recompute() // immediate initial read — nothing to debounce yet at startup
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        pendingRecomputeWorkItem?.cancel()
        pendingRecomputeWorkItem = nil
        pendingFullscreenConfirmationWorkItem?.cancel()
        pendingFullscreenConfirmationWorkItem = nil
        isAwaitingFullscreenConfirmation = false
        isOtherAppFullscreen = false
    }

    /// Occlusion state can flicker rapidly mid-transition — Mission Control, a Spaces switch, or a
    /// fullscreen enter/exit animation all post several intermediate occlusion changes before
    /// settling, not just one final one. Reacting to every intermediate flicker would flap the
    /// actual pause/resume/stop policy on and off, wasting resources and (for the "stop" policy,
    /// which hides windows) causing visible hitching. Debounced the same way ClockOverlay debounces
    /// its own high-frequency window-move notifications — 5s matches this monitor's own former
    /// polling interval and its original reasoning ("pausing a couple seconds later... is
    /// imperceptible, fullscreen transitions themselves take a moment"), just event-driven instead
    /// of polled now.
    ///
    /// Deliberately does NOT cancel-and-reschedule on every new notification anymore. Confirmed via
    /// live log analysis (2026-07-30): a real lock/unlock cycle produces occlusion-change
    /// notifications for *unrelated* windows continuously for several seconds (not just once) —
    /// cancel-and-reschedule against a rolling 5s window of "any window, anywhere" traffic meant
    /// `recompute()` could be deferred indefinitely as long as that noise kept arriving inside each
    /// 5s window, which in turn meant `isOtherAppFullscreen` never got reassigned, its `didSet`
    /// never posted `didChangeNotification`, and `GlobalSettingsService.otherApplicationFullscreenDidChange()`
    /// never ran the resume side of the "stop"/"pause" policy at all — leaving the wallpaper stuck
    /// paused/hidden with no other mechanism to un-stick it. Only scheduling when nothing is already
    /// pending bounds this to firing 5s after the *first* event in a burst, no matter how much
    /// further noise follows.
    @objc private func windowOcclusionStateDidChange(_ notification: Notification) {
        guard pendingRecomputeWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingRecomputeWorkItem = nil
            self?.recompute()
        }
        pendingRecomputeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func recompute() {
        let windows = AppDelegate.shared.wallpaperWindows.values
        guard !windows.isEmpty else {
            pendingFullscreenConfirmationWorkItem?.cancel()
            pendingFullscreenConfirmationWorkItem = nil
            isAwaitingFullscreenConfirmation = false
            isOtherAppFullscreen = false
            return
        }
        let allOccluded = windows.allSatisfy { !$0.occlusionState.contains(.visible) }
        // `occlusionState` only reports THAT a wallpaper window is covered, never BY WHAT — so
        // without this check, simply having Wallwright's own main window or Settings open (which
        // sits on top of the wallpaper the whole time the user is browsing/editing) reads
        // identically to "another app went fullscreen," permanently engaging the
        // otherApplicationFullscreen "stop"/"pause" policy against Wallwright's own UI. Confirmed
        // live (2026-07-31): `allOccluded` stuck `true` continuously for 10+ minutes with no
        // lock/unlock or app-switch in that window, correlating with normal in-app use.
        //
        // `isVisible` alone isn't enough: it reflects window-server order state, not the active
        // Space, so a window left open on a Space the user has since switched away from still
        // reports `isVisible == true` — wrongly suppressing a real other-app-fullscreen reading on
        // the Space the user is actually on. `isOnActiveSpace` closes that gap. Deliberately NOT
        // also requiring `isKeyWindow`: our window can be visible-but-unfocused on the active Space
        // (e.g. user clicked into another app without closing it) and still be the thing visually
        // covering the wallpaper — requiring key-ness would misread that as "other app fullscreen"
        // again, the same failure mode this check exists to prevent.
        let ownWindowIsCovering = (AppDelegate.shared.mainWindowController.window.isVisible
            && AppDelegate.shared.mainWindowController.window.isOnActiveSpace)
            || (AppDelegate.shared.settingsWindow.isVisible
                && AppDelegate.shared.settingsWindow.isOnActiveSpace)
        let effectiveOtherAppFullscreen = allOccluded && !ownWindowIsCovering
        wallpaperDebugLog.notice("FullscreenAppMonitor.recompute() — allOccluded=\(allOccluded), ownWindowIsCovering=\(ownWindowIsCovering), was isOtherAppFullscreen=\(self.isOtherAppFullscreen)")

        guard effectiveOtherAppFullscreen else {
            pendingFullscreenConfirmationWorkItem?.cancel()
            pendingFullscreenConfirmationWorkItem = nil
            isAwaitingFullscreenConfirmation = false
            isOtherAppFullscreen = false
            return
        }
        guard !isOtherAppFullscreen else { return } // already committed true, nothing to do

        // Confirmed live (2026-08-04): a single occluded reading can be a brief compositor blip
        // from a UI transition in our own window (e.g. clicking a tab) rather than a real other-app
        // fullscreen — the same shape of false positive already fixed once for OtherAudioMonitor's
        // CoreAudio signal. Committing to it immediately paused/resumed the wallpaper on a phantom
        // trigger, and that pause/resume cascaded into a full SwiftUI re-render of the whole app
        // (confirmed live: this is what made switching to the Library tab re-render its entire grid
        // multiple times). Requiring the same reading to still hold ~2s later before committing
        // filters out a one-off blip without meaningfully delaying a real, sustained fullscreen app.
        if isAwaitingFullscreenConfirmation {
            isAwaitingFullscreenConfirmation = false
            pendingFullscreenConfirmationWorkItem = nil
            isOtherAppFullscreen = true
        } else if pendingFullscreenConfirmationWorkItem == nil {
            isAwaitingFullscreenConfirmation = true
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingFullscreenConfirmationWorkItem = nil
                self?.recompute()
            }
            pendingFullscreenConfirmationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
        }
    }
}
