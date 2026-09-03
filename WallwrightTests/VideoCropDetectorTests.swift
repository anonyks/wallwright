//
//  VideoCropDetectorTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class VideoCropDetectorTests: XCTestCase {
    func testPicksMostCommonCropLine() {
        let output = """
        [Parsed_cropdetect_0 @ 0x1] crop=1920:880:0:100
        [Parsed_cropdetect_0 @ 0x1] crop=1920:880:0:100
        [Parsed_cropdetect_0 @ 0x1] crop=1920:880:0:100
        [Parsed_cropdetect_0 @ 0x1] crop=1920:800:0:140
        """
        let result = VideoCropDetector.consensusCrop(fromCropdetectOutput: output, nativeWidth: 1920, nativeHeight: 1080)
        XCTAssertEqual(result?.width, 1920)
        XCTAssertEqual(result?.height, 880)
        XCTAssertEqual(result?.x, 0)
        XCTAssertEqual(result?.y, 100)
    }

    func testNoOutputReturnsNil() {
        XCTAssertNil(VideoCropDetector.consensusCrop(fromCropdetectOutput: "", nativeWidth: 1920, nativeHeight: 1080))
    }

    /// height 1078 vs native 1080 is a ~0.19% reduction — well under the 2% "meaningful border"
    /// threshold, so this must not report a crop.
    func testTinyReductionBelowThresholdReturnsNil() {
        let output = "crop=1920:1078:0:1\ncrop=1920:1078:0:1"
        XCTAssertNil(VideoCropDetector.consensusCrop(fromCropdetectOutput: output, nativeWidth: 1920, nativeHeight: 1080))
    }

    /// height 880 vs native 1080 is an ~18.5% reduction — clears the threshold.
    func testMeaningfulReductionAboveThresholdReturnsRect() {
        let output = "crop=1920:880:0:100\ncrop=1920:880:0:100"
        XCTAssertNotNil(VideoCropDetector.consensusCrop(fromCropdetectOutput: output, nativeWidth: 1920, nativeHeight: 1080))
    }

    func testZeroNativeDimensionsReturnsNil() {
        let output = "crop=1920:880:0:100"
        XCTAssertNil(VideoCropDetector.consensusCrop(fromCropdetectOutput: output, nativeWidth: 0, nativeHeight: 1080))
    }
}
