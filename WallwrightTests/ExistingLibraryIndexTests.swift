//
//  ExistingLibraryIndexTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

/// Covers `MotionBgsService.existingLibraryIndex` as the canonical implementation — the other five
/// browse sources (AlphaCoders, DesktopHut, MoeWalls, UhdPaper, Wallper) build their own
/// `ExistingLibraryIndex` with the exact same structure and logic.
final class ExistingLibraryIndexTests: XCTestCase {
    private func wallpaper(title: String, sourceProvider: String? = nil, sourceId: String? = nil) -> WEWallpaper {
        var project = WEProject(file: "x.mp4", preview: "preview.jpg", title: title, type: "video")
        project.sourceProvider = sourceProvider
        project.sourceId = sourceId
        return WEWallpaper(using: project, where: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"))
    }

    /// The precise match: a wallpaper tagged with this exact source's provider/id is recognized
    /// regardless of what else is in the library.
    func testSourceIdMatchesPrecisely() {
        let wallpapers = [wallpaper(title: "Anything", sourceProvider: "motionbgs", sourceId: "12345")]
        let index = MotionBgsService.existingLibraryIndex(wallpapers: wallpapers)
        XCTAssertTrue(index.sourceIds.contains(12345))
    }

    /// A wallpaper with no `sourceId` at all (imported before source tracking existed, or dragged
    /// in manually) falls back to a title match — this is the one case the fallback exists for.
    func testUntrackedWallpaperFallsBackToTitleMatch() {
        let wallpapers = [wallpaper(title: "Minecraft Sunset", sourceProvider: nil, sourceId: nil)]
        let index = MotionBgsService.existingLibraryIndex(wallpapers: wallpapers)
        XCTAssertTrue(index.titles.contains("minecraft sunset"))
    }

    /// A wallpaper that DOES have a `sourceId` — from this source or any other — must never leak
    /// into the title fallback, even if its title happens to match something else in the library.
    /// Confirmed live (2026-10-06) as a real false positive: deleting a Steam-sourced "Minecraft
    /// Sunset" still showed the MotionBgs browse card as "Added" because an unrelated,
    /// differently-sourced wallpaper of the same name was still in the library.
    func testTrackedWallpaperDoesNotLeakIntoTitleFallback() {
        let wallpapers = [wallpaper(title: "Minecraft Sunset", sourceProvider: "steamworkshop", sourceId: "999")]
        let index = MotionBgsService.existingLibraryIndex(wallpapers: wallpapers)
        XCTAssertFalse(index.titles.contains("minecraft sunset"))
        XCTAssertTrue(index.sourceIds.isEmpty, "a different source's id must never be read into this source's own sourceIds set")
    }
}
