//
//  PinningTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class PinningTests: XCTestCase {
    func testLegacyProjectWithoutPinningKeyDecodesToNilAndDefaultsToFalse() throws {
        let legacyJSON = """
        {"file":"test.mp4","preview":"preview.jpg","title":"Legacy Wallpaper","type":"video"}
        """.data(using: .utf8)!

        let project = try JSONDecoder().decode(WEProject.self, from: legacyJSON)
        XCTAssertNil(project.isPinned)

        let wallpaper = WEWallpaper(using: project, where: URL(fileURLWithPath: "/tmp/test"))
        XCTAssertFalse(wallpaper.isPinned)
    }

    func testProjectWithPinningKeyDecodesAndRoundTrips() throws {
        var project = WEProject(file: "test.mp4", preview: "preview.jpg", title: "Pinned Wallpaper", type: "video")
        project.isPinned = true

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(WEProject.self, from: data)
        XCTAssertEqual(decoded.isPinned, true)

        let wallpaper = WEWallpaper(using: decoded, where: URL(fileURLWithPath: "/tmp/test"))
        XCTAssertTrue(wallpaper.isPinned)
    }

    func testPinnedWallpapersSortBeforeUnpinnedWhilePreservingOrder() {
        func makeWallpaper(title: String, pinned: Bool) -> WEWallpaper {
            var project = WEProject(file: "\(title).mp4", preview: "preview.jpg", title: title, type: "video")
            project.isPinned = pinned
            return WEWallpaper(using: project, where: URL(fileURLWithPath: "/tmp/\(title)"))
        }

        let items = [
            makeWallpaper(title: "Alpha", pinned: false),
            makeWallpaper(title: "Bravo", pinned: true),
            makeWallpaper(title: "Charlie", pinned: false),
            makeWallpaper(title: "Delta", pinned: true),
        ]

        // Same comparator `ContentViewModel.sortedWallpapers` layers on top of the chosen sort —
        // see that property's doc comment for why this partition-by-boolean form is stable.
        let sorted = items.sorted { $0.isPinned && !$1.isPinned }

        XCTAssertEqual(sorted.map(\.project.title), ["Bravo", "Delta", "Alpha", "Charlie"])
    }
}
