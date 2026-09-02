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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    /// Same debounce reasoning as `BatteryMonitor.scheduleTick()` — IOKit can fire this more than
    /// once for a single real change.
    private func scheduleTick() {
        pendingTickWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.updateState() }
        pendingTickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    @objc private func thermalStateChanged() {
        updateState()
    }

    private func updateState() {
        let thermal = ProcessInfo.processInfo.thermalState
        let thermalCritical = thermal == .critical || thermal == .serious
        let batteryLow = BatteryMonitor.shared.isOnBattery && Self.batteryLevel() < 20

        let newValue = thermalCritical || batteryLow
        guard newValue != shouldPause else { return }
        shouldPause = newValue
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func batteryLevel() -> Int {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any]
        else { return 100 }
        return desc[kIOPSCurrentCapacityKey] as? Int ?? 100
    }
}
