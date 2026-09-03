//
//  DynamicDesktopHEICTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class DynamicDesktopHEICTests: XCTestCase {
    /// Builds a `Date` for a specific hour/minute using the same `Calendar.current` that
    /// `currentFrameIndex` itself reads back from — keeps the round-trip deterministic regardless
    /// of the machine's actual timezone.
    private func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    func testMidnightIsFrameZero() {
        XCTAssertEqual(DynamicDesktopHEIC.currentFrameIndex(frameCount: 16, now: date(hour: 0, minute: 0)), 0)
    }

    func testJustBeforeMidnightIsLastFrame() {
        XCTAssertEqual(DynamicDesktopHEIC.currentFrameIndex(frameCount: 16, now: date(hour: 23, minute: 59)), 15)
    }

    func testNoonIsMiddleFrame() {
        XCTAssertEqual(DynamicDesktopHEIC.currentFrameIndex(frameCount: 16, now: date(hour: 12, minute: 0)), 8)
    }

    func testZeroFrameCountReturnsZero() {
        XCTAssertEqual(DynamicDesktopHEIC.currentFrameIndex(frameCount: 0, now: date(hour: 12, minute: 0)), 0)
    }

    func testSingleFrameAlwaysReturnsZero() {
        XCTAssertEqual(DynamicDesktopHEIC.currentFrameIndex(frameCount: 1, now: date(hour: 18, minute: 30)), 0)
    }

    /// The `min(frameCount - 1, ...)` clamp exists specifically so no hour/minute combination can
    /// ever produce an out-of-range index — swept across every hour of the day as the regression
    /// guard for that.
    func testIndexNeverExceedsFrameCountMinusOne() {
        for hour in 0..<24 {
            let idx = DynamicDesktopHEIC.currentFrameIndex(frameCount: 16, now: date(hour: hour, minute: 59))
            XCTAssertTrue(idx >= 0 && idx < 16, "index \(idx) out of range for hour \(hour)")
        }
    }
}
