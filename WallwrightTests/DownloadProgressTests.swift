//
//  DownloadProgressTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class DownloadProgressTests: XCTestCase {
    /// Feeds `callbacks` evenly spread over `seconds` and returns the values let through.
    private func shown(callbacks: Int, over seconds: Double) -> [Double] {
        var throttle = DownloadProgressThrottle()
        return (1...callbacks).compactMap { step in
            let progress = Double(step) / Double(callbacks)
            return throttle.shouldReport(progress, at: seconds * Double(step) / Double(callbacks)) ? progress : nil
        }
    }

    func testAFlurryOfCallbacksIsCutToAFewASecond() {
        let values = shown(callbacks: 1000, over: 10)
        XCTAssertLessThanOrEqual(values.count, 52)
        XCTAssertGreaterThanOrEqual(values.count, 40)
        XCTAssertEqual(values.last, 1)
    }

    func testTheFirstAndFinishedValuesAlwaysGetThrough() {
        let values = shown(callbacks: 300, over: 0.1)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.last, 1)
    }

    func testAnUnchangedPercentIsNotShownAgain() {
        var throttle = DownloadProgressThrottle()
        XCTAssertTrue(throttle.shouldReport(0.500, at: 0))
        XCTAssertFalse(throttle.shouldReport(0.505, at: 10))
        XCTAssertTrue(throttle.shouldReport(0.51, at: 11))
    }

    func testAnUnknownLengthIsReportedOnce() {
        var throttle = DownloadProgressThrottle()
        XCTAssertTrue(throttle.shouldReport(nil, at: 0))
        XCTAssertFalse(throttle.shouldReport(nil, at: 10))
    }
}
