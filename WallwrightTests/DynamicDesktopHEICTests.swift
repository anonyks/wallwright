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

    /// A 2-frame Dynamic Desktop is Apple's Light/Dark appearance toggle, not a chronological
    /// cycle — confirmed by decoding the real `apple_desktop:apr` metadata on a genuine Apple
    /// wallpaper (/System/Library/Desktop Pictures/Sonoma.heic), whose own appearance map is
    /// `{"l": 0, "d": 1}`. `currentFrameIndex` special-cases this to match the system's actual
    /// current appearance instead of time of day, so — unlike every other frame count — the result
    /// doesn't depend on `now` at all. This can't assert *which* of 0/1 without controlling the
    /// test host's actual appearance, but it does guard the one thing that must always hold: the
    /// result stays in range and doesn't fall through to the time-based formula (which would make
    /// it vary with `now`, unlike the real, always-in-range appearance-based branch).
    func testTwoFrameCountStaysInRangeRegardlessOfTime() {
        let morning = DynamicDesktopHEIC.currentFrameIndex(frameCount: 2, now: date(hour: 3, minute: 0))
        let evening = DynamicDesktopHEIC.currentFrameIndex(frameCount: 2, now: date(hour: 21, minute: 0))
        XCTAssertTrue((0...1).contains(morning))
        XCTAssertTrue((0...1).contains(evening))
        XCTAssertEqual(morning, evening, "should track system appearance, not time of day")
    }
}
