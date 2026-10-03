//
//  ProcessRunnerTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class ProcessRunnerTests: XCTestCase {
    func testResolvesStandardSystemBinary() {
        // Not one of ProcessRunner's hardcoded Homebrew/MacPorts/Nix candidate paths, so this
        // only passes if the `which` fallback actually works.
        let path = ProcessRunner.resolveBinary(named: "sh")
        XCTAssertNotNil(path)
        if let path {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        }
    }

    func testNonexistentBinaryReturnsNil() {
        let path = ProcessRunner.resolveBinary(named: "nonexistent_binary_xyz_12345")
        XCTAssertNil(path)
    }
}
