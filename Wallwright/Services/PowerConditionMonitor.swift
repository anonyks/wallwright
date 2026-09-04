//
//  PowerConditionMonitor.swift
//  Wallwright
//
//  Modeled on Phosphene's PowerMonitor (MIT License, Copyright (c) 2026 kageroumado) —
//  https://github.com/kageroumado/phosphene — watches two conditions BatteryMonitor's plain
//  on/off-battery signal doesn't cover: thermal throttling and a critically low battery
//  percentage. Both are cases where continuing to decode is pure waste — nothing on any display
//  benefits from it.
//
//  Deliberately does NOT include Phosphene's third condition (near-zero display brightness):
//  confirmed live (2026-08-31) there is no event-driven notification for a display brightness
//  change on macOS at all — tried six known candidate names against a real, physical brightness
//  change (not just a programmatic one) and none fired, same conclusion Phosphene's own code
//  independently reached. The only way to observe it is polling, which this project doesn't do
//  anywhere else and isn't starting here for one soft signal.
//

import Foundation
import IOKit.ps

final class PowerConditionMonitor {
    static let shared = PowerConditionMonitor()
    static let didChangeNotification = Notification.Name("PowerConditionMonitor.didChange")

    private(set) var shouldPause = false

    private var runLoopSource: CFRunLoopSource?
    private var pendingTickWorkItem: DispatchWorkItem?
    private var started = false

    private init() {}

    func startIfNeeded() {
        guard !started else { return }
        started = true

        updateState()

        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil
        )

        // The same IOKit power-source event source `BatteryMonitor` registers its own independent
        // instance of — it fires on a real battery *percentage* change too, not just a plug/unplug
        // transition (confirmed by `BatteryMonitor`'s own doc comment and behavior), so the
        // low-battery check here stays fully event-driven with no polling at all.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerConditionMonitor>.fromOpaque(context).takeUnretainedValue().scheduleTick()
        }, context) else { return }
        let source = unmanagedSource.takeRetainedValue()
        // `.commonModes`, not just `.defaultMode` — see `BatteryMonitor.startIfNeeded()`'s identical
        // fix and doc comment for why: `.defaultMode` isn't pumped while the main run loop is in
        // `.eventTrackingRunLoopMode` (a menu open, a slider being dragged) or
        // `.modalPanelRunLoopMode` (a sheet/modal up — Settings, YouTube/Steam import, all reachable
        // here), so a power/thermal notification arriving during any of those would just sit unfired
        // until the interaction ends, on top of the debounce below.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    deinit {
        if let runLoopSource {
            // `.commonModes`, matching the add call above — removing with a different mode only
            // detaches it from that one mode (see `BatteryMonitor.deinit`'s identical comment).
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    /// Same debounce reasoning AND fix as `BatteryMonitor.scheduleTick()`: only schedule when
    /// nothing is already pending, rather than cancel-and-reschedule on every event. A rolling
    /// cancel-and-reschedule window can be deferred indefinitely as long as IOKit keeps firing
    /// within each 5s window — confirmed live for FullscreenAppMonitor's occlusion notifications
    /// during a lock/unlock cycle (see `BatteryMonitor`'s own doc comment) — which for THIS monitor
    /// specifically means a rapidly draining battery or a sustained thermal event could keep
    /// deferring the low-power pause check past when it should have fired. Scheduling only when idle
    /// bounds this to firing 5s after the *first* event in a burst, no matter how much further
    /// bouncing follows.
    private func scheduleTick() {
        guard pendingTickWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingTickWorkItem = nil
            self?.updateState()
        }
        pendingTickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    @objc private func thermalStateChanged() {
        updateState()
    }

    private func updateState() {
        // `ProcessInfo.thermalStateDidChangeNotification` is documented by Apple as not guaranteed
        // to arrive on the main thread — `thermalStateChanged()` below can call this from wherever
        // the OS happens to post it. `didChangeNotification` posted at the end of this method
        // eventually reaches `GlobalSettingsService.powerConditionDidChange()`, which does AppKit
        // window-server calls (`orderOut`/`orderFront`) and mutates `@Published` state — both
        // unsafe off the main thread. Redispatching here, at the source, fixes it for every caller
        // (`startIfNeeded()`/`scheduleTick()` are already main-thread; this is a no-op for them).
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateState() }
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        let thermalCritical = thermal == .critical || thermal == .serious
        // `BatteryMonitor.checkOnBattery()` (a live query), not `.shared.isOnBattery` (a
        // `@Published` property behind its own independent ~5s debounce off the same IOKit
        // notification this method's own 5s debounce already reacts to) — two independently
        // debounced consumers of the same OS event have no ordering guarantee between them, so
        // reading the cached property here risked evaluating against a stale pre-transition value.
        // Same live-check pattern `LockScreenSync.screenLocked()` already uses for the same reason.
        let batteryLow = BatteryMonitor.checkOnBattery() && Self.batteryLevel() < 20

        let newValue = thermalCritical || batteryLow
        guard newValue != shouldPause else { return }
        shouldPause = newValue
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func batteryLevel() -> Int {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return 100 }
        // `IOPSCopyPowerSourcesList` returns every registered power source, not just the Mac's own
        // battery — a Bluetooth peripheral that reports its own battery level (Magic Mouse/
        // Keyboard/Trackpad) registers here too, and ordering isn't documented/guaranteed, so
        // blindly taking `.first` risked reading a mouse's battery percentage instead of the
        // laptop's. Filtering for the internal battery specifically is the same thing every other
        // IOKit power-source reader (including Apple's own sample code) has to do.
        let descriptions = sources.compactMap { IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any] }
        guard let desc = descriptions.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType })
        else { return 100 }
        return desc[kIOPSCurrentCapacityKey] as? Int ?? 100
    }
}
