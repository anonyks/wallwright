//
//  WWLog.swift
//  Wallwright
//
//  One place to get an os.Logger for each subsystem, replacing scattered per-file
//  `private let xLog = Logger(...)` declarations and ad-hoc print() calls.
//

import os

enum WWLog {
    private static let subsystem = "com.wallwright.Wallwright"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let playback = Logger(subsystem: subsystem, category: "Playback")
    static let aerial = Logger(subsystem: subsystem, category: "Aerial")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let importing = Logger(subsystem: subsystem, category: "Importing")
    static let hotkeys = Logger(subsystem: subsystem, category: "Hotkeys")
    static let inbox = Logger(subsystem: subsystem, category: "Inbox")
}
