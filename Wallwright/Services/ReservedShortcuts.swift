//
//  ReservedShortcuts.swift
//  Wallwright
//
//  A fixed list mirroring every key equivalent already wired up in MainMenu.swift/StatusBar.swift,
//  so the Hotkeys settings page can warn when a user picks a combo that's already doing something
//  else. Kept as plain (label, character, modifiers) data rather than introspecting the live
//  NSMenu, since the status bar menu's items aren't part of the app's main menu and app-wide
//  key-equivalent conflicts matter regardless of which menu they live in.
//

import Cocoa

struct ReservedShortcut {
    let label: String
    let character: String
    let modifiers: NSEvent.ModifierFlags

    /// True if a recorded hotkey (character + modifiers, as captured by HotkeyRecorderView) would
    /// trigger the same keypress as this reserved shortcut.
    func clashes(character: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.character.uppercased() == character.uppercased() && self.modifiers == modifiers
    }
}

enum ReservedShortcuts {
    static let all: [ReservedShortcut] = [
        .init(label: String(localized: "Settings..."), character: ",", modifiers: [.command]),
        .init(label: String(localized: "Quit"), character: "q", modifiers: [.command]),
        .init(label: String(localized: "Hide"), character: "h", modifiers: [.command]),
        .init(label: String(localized: "Hide Others"), character: "h", modifiers: [.command, .option]),
        .init(label: String(localized: "Wallpaper from Folder"), character: "i", modifiers: [.command]),
        .init(label: String(localized: "Close Window"), character: "w", modifiers: [.command]),
        .init(label: String(localized: "Undo"), character: "z", modifiers: [.command]),
        .init(label: String(localized: "Redo"), character: "z", modifiers: [.command, .shift]),
        .init(label: String(localized: "Cut"), character: "x", modifiers: [.command]),
        .init(label: String(localized: "Copy"), character: "c", modifiers: [.command]),
        .init(label: String(localized: "Paste"), character: "v", modifiers: [.command]),
        .init(label: String(localized: "Select All"), character: "a", modifiers: [.command]),
        .init(label: String(localized: "Show Filter Results"), character: "s", modifiers: [.command, .control]),
        .init(label: String(localized: "Enter Full Screen"), character: "f", modifiers: [.command, .control]),
        .init(label: String(localized: "Wallpaper Explorer"), character: "1", modifiers: [.command, .shift]),
        .init(label: String(localized: "Show Wallwright"), character: "o", modifiers: [.command]),
        .init(label: String(localized: "Displays"), character: "d", modifiers: [.command]),
        .init(label: String(localized: "Mute"), character: "m", modifiers: [.command]),
        .init(label: String(localized: "Pause"), character: "p", modifiers: [.command])
    ]

    /// Returns the label of whatever this combo already conflicts with — the other configurable
    /// hotkey (checked separately at the call site), a fixed app shortcut, or nil if it's free.
    static func conflict(character: String, modifiers: NSEvent.ModifierFlags) -> String? {
        all.first { $0.clashes(character: character, modifiers: modifiers) }?.label
    }
}
