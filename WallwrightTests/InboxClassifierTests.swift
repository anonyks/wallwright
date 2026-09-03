//
//  InboxClassifierTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class InboxClassifierTests: XCTestCase {
    func testDirectExtensionMP4() {
        XCTAssertTrue(InboxClassifier.isDirectByExtension(URL(string: "https://example.com/video.mp4")!))
    }

    func testDirectExtensionCaseInsensitive() {
        XCTAssertTrue(InboxClassifier.isDirectByExtension(URL(string: "https://example.com/IMAGE.PNG")!))
    }

    func testNonDirectExtension() {
        XCTAssertFalse(InboxClassifier.isDirectByExtension(URL(string: "https://example.com/page.html")!))
    }

    func testNoExtension() {
        XCTAssertFalse(InboxClassifier.isDirectByExtension(URL(string: "https://example.com/watch")!))
    }

    func testKnownVideoOnlyHostExactMatch() {
        XCTAssertTrue(InboxClassifier.isKnownVideoOnlyHost(URL(string: "https://youtube.com/watch?v=x")!))
    }

    func testKnownVideoOnlyHostSubdomain() {
        XCTAssertTrue(InboxClassifier.isKnownVideoOnlyHost(URL(string: "https://m.youtube.com/watch?v=x")!))
        XCTAssertTrue(InboxClassifier.isKnownVideoOnlyHost(URL(string: "https://www.tiktok.com/@user/video/1")!))
    }

    func testUnknownHostIsNotVideoOnly() {
        XCTAssertFalse(InboxClassifier.isKnownVideoOnlyHost(URL(string: "https://instagram.com/p/x")!))
    }

    /// Guards the `host == $0 || host.hasSuffix(".\($0)")` check specifically — a naive
    /// `hasSuffix($0)` alone (no leading dot) would wrongly match "notyoutube.com" against
    /// "youtube.com".
    func testHostSuffixDoesNotFalsePositiveOnUnrelatedDomain() {
        XCTAssertFalse(InboxClassifier.isKnownVideoOnlyHost(URL(string: "https://notyoutube.com/watch")!))
    }
}
