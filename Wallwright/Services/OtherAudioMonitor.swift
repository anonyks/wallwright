//
//  OtherAudioMonitor.swift
//  Wallwright
//
//  Detects whether some OTHER app is currently playing audio, so "Other Application Playing
//  Audio" in Settings can actually mute/pause our own wallpaper audio instead of being a purely
//  decorative picker.
//
//  History:
//  - Originally built on the private MediaRemote framework's "Now Playing" API — confirmed live
//    (2026-07-26) that it reports isPlaying=false for Spotify even while it's audibly playing,
//    since MediaRemote only reflects whatever an app chooses to report as its Now Playing
//    metadata, and not every app integrates with it consistently.
//  - Rewritten on CoreAudio's process properties (kAudioHardwarePropertyProcessObjectList /
//    kAudioProcessPropertyIsRunningOutput) — fully public API, no TCC prompt, asks the audio
//    hardware directly which processes have an active output stream. Fixed the "doesn't detect
//    Spotify starting" problem, but confirmed live (2026-07-26) it has the opposite problem:
//    Spotify holds its output stream open for a while after pausing (for gapless resume), so
//    "has an active stream" stays true long after playback actually stopped — CoreAudio has no
//    public per-process "is it actually audible right now" signal to fall back on.
//  - Current approach: for apps with a scripting dictionary that reports real transport state
//    (Spotify, Music), ask them directly via Apple Events — completely accurate, no stream-warm
//    ambiguity, and only costs a query for apps that are actually running. Falls back to the
//    CoreAudio signal for anything else so unlisted apps still get (coarser) coverage. The
//    trade-off: each scriptable app needs its own one-time Automation permission grant.
//  - Found via live debug logging (2026-07-26) that the CoreAudio fallback had a false-positive
//    source: `corespeechd` (bundle `com.apple.CoreSpeech`, macOS's on-device speech/accessibility
//    daemon) reports `isRunningOutput=1` while OUR OWN wallpaper audio is playing — some system
//    speech/accessibility feature reacts to audio playing anywhere and briefly opens its own
//    output stream. That got picked up as "some other app is playing audio" and muted us — an
//    indirect self-feedback loop mediated through a system daemon, not a real other app. It's
//    reactive (clears again once the audio settles), which is why the mute only ever happened
//    once near the start of playback and never again afterward — `isOtherAppPlaying`'s didSet
//    only re-fires on a value *change*, so once corespeechd's flag disappears, no further mute
//    calls occur.
//

import AppKit
import CoreAudio
import Foundation
import os

private let wallpaperDebugLog = Logger(subsystem: "com.wallwright.Wallwright", category: "VideoWallpaperDebug")

final class OtherAudioMonitor {
    static let shared = OtherAudioMonitor()

    static let didChangeNotification = Notification.Name("OtherAudioMonitor.didChange")

    private(set) var isOtherAppPlaying = false {
        didSet {
            guard oldValue != isOtherAppPlaying else { return }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private var started = false
    private var pollTimer: Timer?
    private var pendingStartWorkItem: DispatchWorkItem?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// `isKnownAppActuallyPlaying()` runs `NSAppleScript.executeAndReturnError` against Spotify/
    /// Music — a synchronous Apple Event call with no way to configure a short timeout, and Apple
    /// Events can legitimately take a long time (up to their default ~120s timeout) if the target
    /// app is hung, busy, or showing a blocking dialog. Without this guard, every 2s timer tick
    /// dispatched another `poll()` regardless of whether the previous one had returned, so a single
    /// slow/hung app could pile up many concurrent blocked utility-queue tasks over even a short
    /// stretch of ticks.
    private var isPolling = false

    /// How many consecutive polls in a row the coarse CoreAudio signal (see
    /// `isAnyOtherProcessOutputtingAudio`) has read "something's outputting audio." Only that
    /// signal needs this — `isKnownAppActuallyPlaying`'s Apple Event answer is already a direct,
    /// authoritative read of real transport state, nothing to debounce there.
    private var consecutiveCoreAudioTrueCount = 0

    /// Apps known to report real transport state via `tell application "X" to player state`,
    /// checked only when actually running so we never launch them just to ask.
    private static let scriptableApps: [(bundleID: String, appName: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Music"),
    ]

    /// System daemons/apps that show up in CoreAudio's process list with an active output stream
    /// but aren't a real "other app playing media" — see the CoreSpeech history note above.
    /// `com.microsoft.rdc.macos` (Microsoft Remote Desktop) is the second confirmed case: found
    /// live (2026-08-04) reporting `isRunningOutput=1` continuously with nothing actually playing,
    /// likely keeping its output stream warm for low-latency remote-audio redirection — same shape
    /// of false positive as CoreSpeech, and with the "mute" policy enabled this silenced Wallwright
    /// shortly after every launch.
    private static let ignoredBundleIDs: Set<String> = ["com.apple.CoreSpeech", "com.microsoft.rdc.macos"]

    private init() {}

    /// Only worth running while some `GSPlayback` policy actually consumes `isOtherAppPlaying`
    /// (i.e. `settings.otherApplicationPlayingAudio != .keepRunning`) — `.keepRunning` is the
    /// default, so for anyone who's never touched that setting this was previously real CoreAudio
    /// work (and occasionally an Apple Event round-trip to Spotify/Music) every 2 seconds for the
    /// app's entire lifetime, computing a signal nothing ever acted on. Caller
    /// (`GlobalSettingsService`) is responsible for calling `stop()` when the policy no longer
    /// needs it and `startIfNeeded()` again if it's turned back on.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        // The first check is delayed rather than run immediately — confirmed via a live debug
        // run (2026-07-26) that a clean launch never produces a false trigger once the process
        // is already settled, but at t≈0 our own AVPlayer/audio session and macOS's own audio
        // HAL are both still spinning up, which is exactly the kind of moment a CoreAudio
        // process-list heuristic can return a spurious one-off reading for. Waiting a few
        // seconds before the very first check avoids ever reacting to that startup transient —
        // this is what caused wallpaper audio to drop to 0% within 1-2s of launch.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Interval deliberately left at 2s, unlike the other monitors in this app — this is
            // the one polling loop where slower actually means worse UX (audible overlap between
            // this app's audio and whatever else just started playing), not just a cosmetic
            // delay, so it's not a good candidate for trading responsiveness for fewer wake-ups.
            // Tolerance alone still buys a small, free scheduling-efficiency win.
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.poll()
            }
            self.pollTimer?.tolerance = 1
            self.poll()
        }
        pendingStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    /// Stops polling entirely — cancels the initial-delay work item too, in case this is called
    /// during that 3s startup window before the timer even exists yet.
    func stop() {
        guard started else { return }
        started = false
        pendingStartWorkItem?.cancel()
        pendingStartWorkItem = nil
        pollTimer?.invalidate()
        pollTimer = nil
        consecutiveCoreAudioTrueCount = 0
        isOtherAppPlaying = false
    }

    private func poll() {
        guard !isPolling else {
            wallpaperDebugLog.notice("OtherAudioMonitor: poll() skipped — previous poll still in flight")
            return
        }
        isPolling = true
        let ownPID = self.ownPID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if let knownPlaying = Self.isKnownAppActuallyPlaying() {
                DispatchQueue.main.async {
                    self.isPolling = false
                    self.consecutiveCoreAudioTrueCount = 0
                    self.isOtherAppPlaying = knownPlaying
                }
                return
            }

            let coreAudioPlaying = Self.isAnyOtherProcessOutputtingAudio(excluding: ownPID)
            DispatchQueue.main.async {
                self.isPolling = false
                guard coreAudioPlaying else {
                    if self.consecutiveCoreAudioTrueCount > 0 {
                        wallpaperDebugLog.notice("OtherAudioMonitor: coreAudioPlaying=false, resetting count from \(self.consecutiveCoreAudioTrueCount)")
                    }
                    self.consecutiveCoreAudioTrueCount = 0
                    self.isOtherAppPlaying = false
                    return
                }
                // Confirmed live (2026-08-04): this coarse signal isn't just wrong for specific
                // known daemons (CoreSpeech, RDC — see `ignoredBundleIDs`), it can also flag any
                // one-off sound (tested: a plain `afplay` blip registers exactly the same way an
                // app playing real audio does). Requiring two consecutive polls — 4s+ apart — before
                // actually trusting it filters out anything that brief regardless of which process
                // made it, no allowlist needed, while still catching a genuinely sustained source
                // (a call, music, screen sharing) within one extra poll cycle.
                self.consecutiveCoreAudioTrueCount += 1
                wallpaperDebugLog.notice("OtherAudioMonitor: coreAudioPlaying=true, consecutiveCount=\(self.consecutiveCoreAudioTrueCount)")
                self.isOtherAppPlaying = self.consecutiveCoreAudioTrueCount >= 2
            }
        }
    }

    /// Asks each known scriptable app that's currently running for its real transport state.
    /// Returns nil (defer to the generic CoreAudio signal) if none of them are running.
    private static func isKnownAppActuallyPlaying() -> Bool? {
        // Was `return result.stringValue == "playing"` unconditionally — returning on the FIRST
        // scriptable app whose query succeeds, regardless of whether it was actually playing.
        // With Spotify checked before Music, having Spotify merely *open* (paused, idle) made this
        // return `false` immediately: `poll()`'s `if let knownPlaying = ...` binds just as
        // successfully to `Optional(false)` as to `Optional(true)`, so it took that as a definitive
        // "nothing else is playing" and skipped the CoreAudio fallback entirely — silencing
        // detection for every other app (Chrome, Zoom, Discord, even Apple Music) for as long as
        // Spotify stayed open, confirmed live by tracing the exact optional-binding mechanics.
        // `true` only on an actual confirmed "playing" now; every other case — paused, no
        // scriptable app running, or a query that errored — correctly falls through to `nil`, so
        // `poll()` defers to CoreAudio instead of treating "Spotify isn't playing" as "nothing is."
        for (bundleID, appName) in scriptableApps {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { continue }
            guard let script = NSAppleScript(source: "tell application \"\(appName)\" to player state as string") else { continue }
            guard let stringValue = runAppleScriptWithTimeout(script) else {
                wallpaperDebugLog.notice("OtherAudioMonitor: Apple Event to \(appName, privacy: .public) timed out or errored — falling through")
                continue
            }
            if stringValue == "playing" {
                return true
            }
        }
        return nil
    }

    /// Apple Events sent via `NSAppleScript` have no configurable timeout of their own and can
    /// legitimately block for the system's default (historically up to ~120s) if the target app
    /// is hung, busy, or showing a blocking modal dialog. `poll()`'s own `isPolling` guard (see its
    /// doc comment) treats "still running" as "don't start a new poll" — without bounding the wait
    /// here, a single stuck query to Spotify/Music would silently disable ALL other-app-audio
    /// detection, including the entirely unrelated CoreAudio fallback below, for however long the
    /// hang lasts. This can't cancel the underlying Apple Event dispatch itself (`NSAppleScript`
    /// exposes no such hook) — it only stops THIS poll cycle from waiting on it, so a hang degrades
    /// to "no answer this cycle, fall through to CoreAudio" instead of stalling the whole monitor.
    private static func runAppleScriptWithTimeout(_ script: NSAppleScript, timeout: TimeInterval = 3) -> String? {
        let lock = NSLock()
        var result: String?
        let workItem = DispatchWorkItem {
            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            lock.lock()
            result = error == nil ? descriptor.stringValue : nil
            lock.unlock()
        }
        DispatchQueue.global(qos: .utility).async(execute: workItem)
        guard workItem.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    /// Walks every process CoreAudio knows about and checks whether it has an active output
    /// stream right now — a direct hardware-level signal, not app-reported metadata. Coarse (see
    /// header) but the only option for apps with no scripting interface.
    private static func isAnyOtherProcessOutputtingAudio(excluding ownPID: pid_t) -> Bool {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processList = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize, &processList) == noErr else {
            return false
        }

        for process in processList {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != ownPID else { continue }

            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunningOutput: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &isRunningOutput) == noErr,
                  isRunningOutput != 0
            else { continue }

            if let bundleID = Self.bundleID(for: process), ignoredBundleIDs.contains(bundleID) { continue }

            return true
        }
        return false
    }

    private static func bundleID(for process: AudioObjectID) -> String? {
        var bundleAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &bundleAddress, 0, nil, &bundleSize) == noErr, bundleSize > 0 else { return nil }
        var cfStr: Unmanaged<CFString>?
        var size = bundleSize
        guard AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &size, &cfStr) == noErr, let cfStr else { return nil }
        return cfStr.takeRetainedValue() as String
    }
}
