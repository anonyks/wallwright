//
//  VideoFitTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class VideoFitTests: XCTestCase {
    private let project = WEProject(file: "test.mp4", preview: "preview.jpg", title: "Test", type: "video")

    private func decode(_ extraKeys: String) throws -> WEProject {
        let json = """
        {"file":"test.mp4","preview":"preview.jpg","title":"Test","type":"video"\(extraKeys)}
        """
        return try JSONDecoder().decode(WEProject.self, from: Data(json.utf8))
    }

    func testAProjectWithoutItsOwnFitFollowsTheGeneralSetting() throws {
        let project = try decode("")
        XCTAssertNil(project.videoFitOverride)
        XCTAssertEqual(project.fit(otherwise: .stretch), .stretch)
    }

    func testAProjectsOwnFitWinsAndSurvivesSaving() throws {
        var edited = project
        edited.videoFit = GSVideoFit.fit.rawValue
        let reloaded = try JSONDecoder().decode(WEProject.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(reloaded.fit(otherwise: .fill), .fit)
    }

    /// An unknown value must not turn the whole wallpaper into a broken library entry.
    func testAnUnknownFitValueIsIgnored() throws {
        let project = try decode(#","videoFit":"tile""#)
        XCTAssertNil(project.videoFitOverride)
        XCTAssertEqual(project.fit(otherwise: .fill), .fill)
    }

    func testOnlyAChangeOfScalingCountsAsTheSameContent() {
        var rescaled = project
        rescaled.videoFit = GSVideoFit.stretch.rawValue
        XCTAssertTrue(rescaled.hasSameContent(as: project))

        var trimmed = rescaled
        trimmed.trimEnd = 4
        XCTAssertFalse(trimmed.hasSameContent(as: project))
    }
}
