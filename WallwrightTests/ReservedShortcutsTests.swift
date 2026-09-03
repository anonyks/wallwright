//
//  ReservedShortcutsTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class ReservedShortcutsTests: XCTestCase {
    func testDetectsQuitConflict() {
        let expectedLabel = ReservedShortcuts.all.first { $0.character == "q" }?.label
        XCTAssertNotNil(expectedLabel)
        XCTAssertEqual(ReservedShortcuts.conflict(character: "q", modifiers: [.command]), expectedLabel)
    }

    func testCaseInsensitiveCharacterMatch() {
        XCTAssertNotNil(ReservedShortcuts.conflict(character: "Q", modifiers: [.command]))
    }

    func testNoConflictForFreeCombo() {
        XCTAssertNil(ReservedShortcuts.conflict(character: "j", modifiers: [.command, .shift, .option]))
    }

    /// Quit is Cmd+Q specifically — Cmd+Shift+Q must not be flagged as the same conflict.
    func testModifiersMustMatchExactly() {
        XCTAssertNil(ReservedShortcuts.conflict(character: "q", modifiers: [.command, .shift]))
    }
}
