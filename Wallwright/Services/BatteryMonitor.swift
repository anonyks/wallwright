//
//  BatteryMonitor.swift
//  Wallwright
//
//  Adapted from LivePaper (MIT License, Copyright (c) 2026 Raunak Gupta)
//  https://github.com/Raunik2/LivePaper
//

import Foundation
import IOKit
import IOKit.ps

final class BatteryMonitor {
    static let shared = BatteryMonitor()
    static let powerSourceDidChange = Notification.Name("BatteryMonitor.powerSourceDidChange")

    private(set) var isOnBattery: Bool
    private var runLoopSource: CFRunLoopSource?
    private var pendingTickWorkItem: DispatchWorkItem?

    private init() {
        isOnBattery = Self.checkOnBattery()
    }

    /// Event-driven via IOKit's power-source notification instead of a polling `Timer` — this used
    /// to check every 30s; `IOPSNotificationCreateRunLoopSource` reacts to an actual plug/unplug
    /// the moment it happens (immediate instead of up to 30s late) while costing nothing at all
    /// between events, since there's no timer firing/tolerance tradeoff to make anymore.
    func startIfNeeded() {
        guard runLoopSource == nil else { return }
        // The C callback can't capture `self` (it's a `@convention(c)` function pointer), so `self`
        // is threaded through as the opaque context instead and recovered inside the callback.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().scheduleTick()
        }, context) else { return }
        let source = unmanagedSource.takeRetainedValue()
        // Registered on the main run loop, so the callback above always lands on the main thread —
        // the standard, documented way to use this API — matching every other observer of
        // `powerSourceDidChange` (GlobalSettingsViewModel etc.), which expect a main-thread post.
        // `.commonModes`, not just `.defaultMode` — a plug/unplug is genuinely event-driven and can
        // happen while the main run loop is in `.eventTrackingRunLoopMode` (a menu open, a slider
        // being dragged) or `.modalPanelRunLoopMode` (a sheet/modal up), neither of which pumps
        // `.defaultMode` sources — without this, the notification would just sit unfired until the
        // user released the mouse/dismissed the modal, on top of the debounce below.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        // The callback only fires on a subsequent *change* — refresh the value now in case the
        // power source changed between `init()` and this call. Immediate, not debounced — nothing
        // to debounce yet at startup.
        tick()
    }

    deinit {
        if let runLoopSource {
            // `.commonModes`, matching `startIfNeeded()`'s own add call above — removing with a
            // different mode than it was added with only detaches it from that one mode, leaving it
            // still registered (and still firing into `Unmanaged.passUnretained(self)`, a dangling
            // reference once this object is gone) in whichever other modes `.commonModes` covers.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    /// IOKit can fire this notification more than once for a single physical plug/unplug (and a
    /// flaky connector can bounce a few times in quick succession) — debounced the same way
    /// FullscreenAppMonitor debounces its own occlusion notifications: only schedule when nothing
    /// is already pending, rather than cancel-and-reschedule on every event. Cancel-and-reschedule
    /// against a rolling window can be deferred indefinitely as long as events keep arriving inside
    /// each window — confirmed live (2026-07-30) for FullscreenAppMonitor's occlusion notifications
    /// during a lock/unlock cycle. Scheduling only when idle bounds this to firing 5s after the
    /// *first* event in a burst, no matter how much further bouncing follows.
    private func scheduleTick() {
        guard pendingTickWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingTickWorkItem = nil
            self?.tick()
        }
        pendingTickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func tick() {
        let was = isOnBattery
        isOnBattery = Self.checkOnBattery()
        if was != isOnBattery {
            NotificationCenter.default.post(name: Self.powerSourceDidChange, object: self)
        }
    }

    static func checkOnBattery() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return false }

        let externalConnected = dict["ExternalConnected"] as? Bool ?? true
        return !externalConnected
    }
}
