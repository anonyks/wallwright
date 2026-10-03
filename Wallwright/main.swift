//
//  main.swift
//  Wallwright
//
//  Created by Haren on 2023/6/6.
//

import Cocoa

// Only one Wallwright may ever run. Two copies fight over the same wallpaper windows, aerial
// registration and menu bar item. Nothing enforced this, so any second launch (a stale login item
// pointing at a different build path, a manual open) simply ran alongside the first. Runs before
// `AppDelegate.shared` is touched so a duplicate exits before creating any state. The older
// process wins; if both start at once, ordering by launch date (then pid) means exactly one exits.
//
// Skipped entirely when launched as an XCTest host: Xcode runs the unit test bundle inside the
// actual Wallwright.app process, and if a regular (non-test) instance happens to already be
// running at the time, this guard would otherwise see it as "older" and exit before XCTest can
// even attach, failing every test run with "Early unexpected exit... before establishing
// connection" (confirmed live 2026-10-03: reproduced the exact failure with a regular instance
// running, and confirmed the test suite passes once that instance is killed).
let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
if !isRunningUnderXCTest, let bundleID = Bundle.main.bundleIdentifier {
    let me = NSRunningApplication.current
    let iAmNewer = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        .contains { other in
            if let otherDate = other.launchDate, let myDate = me.launchDate, otherDate != myDate {
                return otherDate < myDate
            }
            return other.processIdentifier < me.processIdentifier
        }
    if iAmNewer { exit(0) }
}

NSApplication.shared.delegate = AppDelegate.shared
NSApplication.shared.run()
