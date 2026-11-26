//
//  DesktopUpdates.swift
//  Wallwright
//

import Foundation

/// The one queue for everything that changes the desktop picture, aerial or lock screen. These
/// are slow (copying video, restarting WallpaperAgent), and on a concurrent queue an earlier
/// wallpaper's updates could finish after a later one's, leaving the lock screen (and the user's
/// `on_change.sh`) on a wallpaper already switched away from.
enum DesktopUpdates {
    private static let queue = DispatchQueue(label: "com.wallwright.DesktopUpdates", qos: .utility)
    private static let lock = NSLock()
    private static var latestSwitch = 0

    /// A wallpaper switch. `work` must set up that wallpaper completely, because a switch that's
    /// still waiting when a newer one arrives is skipped.
    static func applySwitch(_ work: @escaping () -> Void) {
        let ticket = lock.withLock { () -> Int in
            latestSwitch += 1
            return latestSwitch
        }
        queue.async {
            guard ticket == lock.withLock({ latestSwitch }) else { return }
            work()
        }
    }

    /// Reapplies whatever is current (self-heal, republish). Waits its turn, and never causes a
    /// pending switch to be skipped. Read the current state inside `work`, not before calling.
    static func refresh(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }
}
