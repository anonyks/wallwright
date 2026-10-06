//
//  SceneFallbackTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class SceneFallbackTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "SceneFallbackTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func writePNG(to url: URL, width: Int = 20, height: Int = 10) {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        let pngData = bitmap.representation(using: .png, properties: [:])!
        try? pngData.write(to: url)
    }

    func testScenePreviewBecomesImageFile() async throws {
        let dir = makeTempDir()
        writePNG(to: dir.appending(path: "preview.gif"))
        let project = WEProject(file: "scene.pkg", preview: "preview.gif", title: "Rainy City", type: "scene")

        let updated = try await SceneFallback.apply(to: project, in: dir)

        XCTAssertEqual(updated.type, "image")
        XCTAssertEqual(updated.file, "preview.gif")
        XCTAssertEqual(updated.preview, "preview.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "preview.jpg").path))
        XCTAssertEqual(updated.videoWidth, 20)
        XCTAssertEqual(updated.videoHeight, 10)
    }

    func testPreviewNamedPreviewJpgIsRenamedNotOverwritten() async throws {
        let dir = makeTempDir()
        let originalURL = dir.appending(path: "preview.jpg")
        writePNG(to: originalURL, width: 40, height: 40)
        let originalBytes = try Data(contentsOf: originalURL)
        let project = WEProject(file: "scene.pkg", preview: "preview.jpg", title: "Collision Case", type: "scene")

        let updated = try await SceneFallback.apply(to: project, in: dir)

        XCTAssertEqual(updated.file, "scene.jpg")
        let renamedBytes = try Data(contentsOf: dir.appending(path: "scene.jpg"))
        XCTAssertEqual(renamedBytes, originalBytes, "the original full-resolution preview must survive intact under its new name")
        // "preview.jpg" legitimately exists again at this point, but as the NEW downsampled
        // thumbnail, not a leftover of the original full-resolution file moved aside above.
        let newThumbnailBytes = try Data(contentsOf: originalURL)
        XCTAssertNotEqual(newThumbnailBytes, originalBytes, "preview.jpg must hold the new thumbnail, not the original file's bytes")
    }

    func testMissingPreviewThrowsCleanly() async throws {
        let dir = makeTempDir()
        let project = WEProject(file: "scene.pkg", preview: "preview.jpg", title: "No Preview", type: "scene")

        do {
            _ = try await SceneFallback.apply(to: project, in: dir)
            XCTFail("expected missingPreview to be thrown")
        } catch {
            XCTAssertEqual(error as? SceneFallbackError, .missingPreview)
        }
    }

    func testZeroByteAndCorruptPreviewBothThrowCleanly() async throws {
        let zeroByteDir = makeTempDir()
        try? Data().write(to: zeroByteDir.appending(path: "preview.jpg"))
        let zeroByteProject = WEProject(file: "scene.pkg", preview: "preview.jpg", title: "Empty", type: "scene")
        do {
            _ = try await SceneFallback.apply(to: zeroByteProject, in: zeroByteDir)
            XCTFail("expected missingPreview to be thrown")
        } catch {
            XCTAssertEqual(error as? SceneFallbackError, .missingPreview)
        }

        let corruptDir = makeTempDir()
        try? Data([0x00, 0x01, 0x02, 0x03]).write(to: corruptDir.appending(path: "preview.jpg"))
        let corruptProject = WEProject(file: "scene.pkg", preview: "preview.jpg", title: "Corrupt", type: "scene")
        do {
            _ = try await SceneFallback.apply(to: corruptProject, in: corruptDir)
            XCTFail("expected unreadablePreview to be thrown")
        } catch {
            XCTAssertEqual(error as? SceneFallbackError, .unreadablePreview)
        }
    }

    /// When the import review sheet offered a picker and the user chose a candidate, that choice
    /// must actually be what gets committed — not silently re-derived via SceneArtExtractor's own
    /// first-match again. Uses a directory with no scene.pkg at all (which would normally fall all
    /// the way through to the preview-image fallback) specifically so a pass meaningfully proves
    /// `chosenArt` was used, not just coincidentally agreed with what extraction would have found.
    func testSceneFallbackUsesChosenArtInsteadOfReExtracting() async throws {
        let dir = makeTempDir()
        writePNG(to: dir.appending(path: "preview.jpg"))
        // A real (dummy) scene.pkg on disk, specifically so this test can also assert it gets
        // cleaned up — nothing reads it again once `apply` commits a chosen candidate, and it's
        // often hundreds of MB in real content (confirmed live 2026-10-05 against a real 246MB
        // archive), left behind as pure waste otherwise.
        try Data("dummy scene.pkg bytes".utf8).write(to: dir.appending(path: "scene.pkg"))
        let project = WEProject(file: "scene.pkg", preview: "preview.jpg", title: "Chosen Art", type: "scene")
        let chosen = SceneArtExtractor.Extracted(jpegData: Data("not a real jpeg, just a marker".utf8), width: 123, height: 456)

        let updated = try await SceneFallback.apply(to: project, in: dir, chosenArt: chosen)

        XCTAssertEqual(updated.type, "image")
        XCTAssertEqual(updated.file, "scene-art.jpg")
        XCTAssertEqual(updated.videoWidth, 123)
        XCTAssertEqual(updated.videoHeight, 456)
        let written = try Data(contentsOf: dir.appending(path: "scene-art.jpg"))
        XCTAssertEqual(written, chosen.jpegData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "scene.pkg").path), "scene.pkg must be deleted once its art has been extracted")
    }

    func testVideoAndImagePassThroughPreparePendingUnchanged() async throws {
        for type in ["video", "image"] {
            let dir = makeTempDir()
            writePNG(to: dir.appending(path: "preview.jpg"))
            let project = WEProject(file: "main.mp4", preview: "preview.jpg", title: "Untouched \(type)", type: type)

            let pending = try await PackageImporter.preparePending(project: project, directory: dir)

            XCTAssertEqual(pending.title, "Untouched \(type)", "a plain \(type) project's title must not get a scene marker")
            XCTAssertEqual(pending.type, type)
        }
    }

    func testUnsupportedWebTypeStillRejected() async throws {
        let dir = makeTempDir()
        writePNG(to: dir.appending(path: "preview.jpg"))
        let project = WEProject(file: "index.html", preview: "preview.jpg", title: "Web Wallpaper", type: "web")

        do {
            _ = try await PackageImporter.preparePending(project: project, directory: dir)
            XCTFail("expected .unsupportedType to be thrown")
        } catch PackageImportError.unsupportedType(let type) {
            XCTAssertEqual(type, "web")
        }
    }

    func testLiveExtractionOnDownloadedScenesIfPresent() async {
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Steam/steamapps/workshop/content/431960")
        guard FileManager.default.fileExists(atPath: baseDir.path) else { return }

        let itemIDs = ["3738629251", "3810092560", "3804459999", "3326873240"]
        for id in itemIDs {
            let dir = baseDir.appending(path: id)
            guard FileManager.default.fileExists(atPath: dir.appending(path: "scene.pkg").path) else { continue }
            let extracted = await SceneArtExtractor.extract(directory: dir)
            XCTAssertNotNil(extracted, "Extraction should succeed for item \(id)")
            if let extracted {
                XCTAssertGreaterThan(extracted.width, 0)
                XCTAssertGreaterThan(extracted.height, 0)
                XCTAssertGreaterThan(extracted.jpegData.count, 1000)
                NSLog("[LiveExtractionTest] Item %@ extracted %dx%d (%d bytes)", id, extracted.width, extracted.height, extracted.jpegData.count)
            }
        }
    }
}
