//
//  WallpaperDirectoryTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class WallpaperDirectoryTests: XCTestCase {
    /// Cleans up whatever this test created under the real `wallpapersDirectory` — these tests
    /// touch real filesystem state (the function under test checks `fileExists`), so nothing here
    /// should be left behind in the user's actual library directory.
    private var createdDirectories: [URL] = []

    override func tearDown() {
        for url in createdDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        createdDirectories = []
        super.tearDown()
    }

    private func makeDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        createdDirectories.append(url)
    }

    func testSanitizesSlashInsteadOfNestingAPath() {
        let destination = FileManager.default.uniqueWallpaperDestination(forTitle: "Tokyo / Rain (4K)")
        createdDirectories.append(destination)
        // A raw "/" in the title used to be treated as a path separator by `.appending(path:)`,
        // nesting into a subdirectory instead of being part of one folder name — the destination's
        // own parent must still be `wallpapersDirectory` directly. Compared as trimmed `.path`
        // strings, not `URL` equality: `.deletingLastPathComponent()` keeps a trailing "/" that a
        // freshly-built directory URL doesn't have, which `.standardizedFileURL` doesn't normalize
        // away — a cosmetic difference between two URLs naming the same real directory.
        let parentPath = destination.deletingLastPathComponent().path
        let wallpapersPath = FileManager.default.wallpapersDirectory.path
        XCTAssertEqual(parentPath.hasSuffix("/") ? String(parentPath.dropLast()) : parentPath, wallpapersPath)
    }

    func testDoesNotCollideWithAnExistingDifferentWallpaper() {
        let base = "WallwrightTests-Collision-\(UUID().uuidString.prefix(8))"
        let existing = FileManager.default.wallpapersDirectory.appending(path: base)
        makeDirectory(at: existing)

        let destination = FileManager.default.uniqueWallpaperDestination(forTitle: base)
        createdDirectories.append(destination)

        // Must never resolve to the same path as something that already exists — the whole point
        // is that an unrelated import sharing a title can't silently overwrite/delete it.
        XCTAssertNotEqual(destination.standardizedFileURL, existing.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path), "existing directory must survive untouched")
    }

    func testReturnsTheBareTitleWhenNothingCollides() {
        let base = "WallwrightTests-Unique-\(UUID().uuidString.prefix(8))"
        let destination = FileManager.default.uniqueWallpaperDestination(forTitle: base)
        createdDirectories.append(destination)
        XCTAssertEqual(destination.lastPathComponent, base)
    }

    func testEmptyTitleFallsBackToUntitledRatherThanAnEmptyPathComponent() {
        let destination = FileManager.default.uniqueWallpaperDestination(forTitle: "   ")
        createdDirectories.append(destination)
        XCTAssertFalse(destination.lastPathComponent.isEmpty)
        XCTAssertNotEqual(destination.lastPathComponent, " ")
    }
}
