//
//  HotkeyTests.swift
//  WallwrightTests
//

import XCTest
import Carbon.HIToolbox
@testable import Wallwright

final class HotkeyTests: XCTestCase {
    func testCarbonModifiersCommandOnly() {
        let hotkey = Hotkey(keyCode: 35, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "P")
        XCTAssertEqual(hotkey.carbonModifiers, UInt32(cmdKey))
    }

    func testCarbonModifiersCombination() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        let hotkey = Hotkey(keyCode: 35, modifiers: flags.rawValue, characters: "P")
        XCTAssertEqual(hotkey.carbonModifiers, UInt32(cmdKey) | UInt32(shiftKey))
    }

    func testDisplayStringOrdering() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let hotkey = Hotkey(keyCode: 35, modifiers: flags.rawValue, characters: "p")
        XCTAssertEqual(hotkey.displayString, "⌃⌥⇧⌘P")
    }

    func testClashesSameKeyCodeAndModifiers() {
        let a = Hotkey(keyCode: 35, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "P")
        let b = Hotkey(keyCode: 35, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "P")
        XCTAssertTrue(a.clashes(with: b))
    }

    func testDoesNotClashDifferentKeyCode() {
        let a = Hotkey(keyCode: 35, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "P")
        let b = Hotkey(keyCode: 36, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "M")
        XCTAssertFalse(a.clashes(with: b))
    }

    func testDoesNotClashDifferentModifiers() {
        let a = Hotkey(keyCode: 35, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "P")
        let b = Hotkey(keyCode: 35, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, characters: "P")
        XCTAssertFalse(a.clashes(with: b))
    }

    /// `nsModifierFlags` intersects with only [.command, .option, .control, .shift] — an incidental
    /// bit like `.capsLock` riding along in the raw value must not affect clash detection.
    func testNonRelevantModifierBitsIgnoredInClash() {
        let rawWithExtra = NSEvent.ModifierFlags([.command, .capsLock]).rawValue
        let a = Hotkey(keyCode: 35, modifiers: rawWithExtra, characters: "P")
        let b = Hotkey(keyCode: 35, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "P")
        XCTAssertTrue(a.clashes(with: b))
    }
}
