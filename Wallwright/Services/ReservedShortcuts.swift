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
        .init(label: String(localized: "Quick Switcher"), character: "k", modifiers: [.command]),
        .init(label: String(localized: "Close Window"), character: "w", modifiers: [.command]),
        .init(label: String(localized: "Undo"), character: "z", modifiers: [.command]),
        .init(label: String(localized: "Redo"), character: "z", modifiers: [.command, .shift]),
        .init(label: String(localized: "Cut"), character: "x", modifiers: [.command]),
        .init(label: String(localized: "Copy"), character: "c", modifiers: [.command]),
        .init(label: String(localized: "Paste"), character: "v", modifiers: [.command]),
        .init(label: String(localized: "Select All"), character: "a", modifiers: [.command]),
        // Real, automatic system-provided shortcut for any window supporting full screen — not
        // wired by this app's own code, so it won't show up in a source grep, but reserving it
        // stops a user from binding a custom hotkey that would silently fight the OS's own toggle.
        .init(label: String(localized: "Enter Full Screen"), character: "f", modifiers: [.command, .control])
    ]
    // Removed (2026-08-08), confirmed dead via a full-codebase grep for their key equivalents:
    // "Show Filter Results" (⌃⌘S) and "Wallpaper Explorer" (⌘⇧1) were leftovers from the View menu
    // deleted earlier this session; "Mute" (⌘M) and "Pause" (⌘P) never had a real fixed
    // keyEquivalent at all — those actions are only reachable via the user's own configurable
    // Hotkeys settings, checked separately (see `conflict(character:modifiers:)`'s doc comment).
    //
    // Removed again (2026-08-08), corrected: "Show Wallwright" (⌘O) and "Displays" (⌘D) are only
    // declared on `StatusBar.swift`'s `statusItem.menu` — a status-bar dropdown, not
    // `NSApplication.shared.mainMenu`. A menu that isn't the app's main menu only evaluates its key
    // equivalents while it's already open on screen, so these were never real, usable app-wide
    // shortcuts despite the `keyEquivalent` string being right there in source — a plain grep for
    // the string isn't enough to confirm a shortcut actually works; which menu it's attached to
    // matters just as much.

    /// Returns the label of whatever this combo already conflicts with — the other configurable
    /// hotkey (checked separately at the call site), a fixed app shortcut, or nil if it's free.
    static func conflict(character: String, modifiers: NSEvent.ModifierFlags) -> String? {
        all.first { $0.clashes(character: character, modifiers: modifiers) }?.label
    }
}
