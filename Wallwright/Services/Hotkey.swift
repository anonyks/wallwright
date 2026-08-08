//
//  Hotkey.swift
//  Wallwright
//
//  A user-configurable key combo, stored as the raw virtual keyCode + modifier flags captured at
//  record time (see HotkeyRecorderView) so it survives keyboard layout differences the same way
//  AppKit's own key equivalents do.
//

import Carbon.HIToolbox
import Cocoa

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    /// The character(s) shown to the user (e.g. "P"), captured at record time — avoids having to
    /// re-derive a display glyph from keyCode via the current keyboard layout later.
    var characters: String

    var nsModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift])
    }

    var carbonModifiers: UInt32 {
        let flags = nsModifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    var displayString: String {
        let flags = nsModifierFlags
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += characters.uppercased()
        return s
    }

    /// True if this combo would trigger the same keypress as `other` — used both for detecting
    /// clashes against the app's fixed menu shortcuts and between the two configurable hotkeys.
    func clashes(with other: Hotkey) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }
}
