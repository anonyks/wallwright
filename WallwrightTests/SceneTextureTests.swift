//
//  SceneTextureTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

/// Small helpers for hand-building the exact binary shapes PKGArchive/TEXTexture parse, so these
/// tests don't depend on a real downloaded Workshop item being present on disk.
private extension Data {
    mutating func appendU32(_ value: UInt32) {
        append(contentsOf: Swift.withUnsafeBytes(of: value.littleEndian, Array.init))
    }
    mutating func appendI32(_ value: Int32) {
        appendU32(UInt32(bitPattern: value))
    }
    mutating func appendLengthPrefixed(_ string: String) {
        let bytes = Array(string.utf8)
        appendU32(UInt32(bytes.count))
        append(contentsOf: bytes)
    }
    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(0)
    }
}

final class SceneTextureTests: XCTestCase {
    // MARK: - PKGArchive

    private func makePKG(entries: [(name: String, payload: Data)]) -> Data {
        var tableAndHeader = Data()
        tableAndHeader.appendLengthPrefixed("PKGV0001")
        tableAndHeader.appendU32(UInt32(entries.count))
        var offset: UInt32 = 0
        var offsets: [UInt32] = []
        for entry in entries {
            offsets.append(offset)
            offset += UInt32(entry.payload.count)
        }
        for (entry, off) in zip(entries, offsets) {
            tableAndHeader.appendLengthPrefixed(entry.name)
            tableAndHeader.appendU32(off)
            tableAndHeader.appendU32(UInt32(entry.payload.count))
        }
        var full = tableAndHeader
        for entry in entries { full.append(entry.payload) }
        return full
    }

    func testPKGArchiveExtractsEntryByName() throws {
        let payload = Data("hello world".utf8)
        let pkg = makePKG(entries: [("scene.json", payload)])
        let archive = try PKGArchive(data: pkg)
        XCTAssertEqual(archive["scene.json"], payload)
        XCTAssertNil(archive["missing.json"])
    }

    func testPKGArchiveRejectsBadMagic() {
        var bad = Data()
        bad.appendLengthPrefixed("NOTAPKG!")
        XCTAssertThrowsError(try PKGArchive(data: bad)) {
            guard case SceneTextureFormatError.badMagic = $0 else {
                return XCTFail("expected .badMagic, got \($0)")
            }
        }
    }

    func testPKGArchiveRejectsOutOfBoundsEntry() {
        var bad = Data()
        bad.appendLengthPrefixed("PKGV0001")
        bad.appendU32(1)
        bad.appendLengthPrefixed("x")
        bad.appendU32(0)
        bad.appendU32(999_999)  // size far larger than any payload actually present
        XCTAssertThrowsError(try PKGArchive(data: bad)) {
            XCTAssertEqual($0 as? SceneTextureFormatError, .truncated)
        }
    }

    // MARK: - TEXTexture

    /// Builds the simplest possible valid .tex: TEXB0001 container (no LZ4, no FreeImage fields),
    /// a single mip, raw RGBA8888 pixels.
    private func makeRGBA8888TEX(width: Int, height: Int, pixels: Data, flags: UInt32 = 0) -> Data {
        var tex = Data()
        tex.appendCString("TEXV0005")
        tex.appendCString("TEXI0001")
        tex.appendI32(0)  // format: rgba8888
        tex.appendU32(flags)
        tex.append(Data(repeating: 0, count: 8))  // padded texture size, unused here
        tex.appendU32(UInt32(width))
        tex.appendU32(UInt32(height))
        tex.appendU32(0)
        tex.appendCString("TEXB0001")
        tex.appendU32(1)  // imageCount
        tex.appendU32(1)  // mipmap count
        tex.appendU32(UInt32(width))
        tex.appendU32(UInt32(height))
        tex.appendU32(UInt32(pixels.count))
        tex.append(pixels)
        return tex
    }

    func testTEXTextureDecodesRGBA8888() throws {
        // 2x2 image: red, green, blue, white pixels (RGBA8888).
        var pixels = Data()
        pixels.append(contentsOf: [255, 0, 0, 255])
        pixels.append(contentsOf: [0, 255, 0, 255])
        pixels.append(contentsOf: [0, 0, 255, 255])
        pixels.append(contentsOf: [255, 255, 255, 255])
        let texData = makeRGBA8888TEX(width: 2, height: 2, pixels: pixels)

        let texture = try TEXTexture(data: texData)
        XCTAssertEqual(texture.format, .rgba8888)
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(texture.imageWidth, 2)
        XCTAssertEqual(texture.imageHeight, 2)
        XCTAssertEqual(texture.rgba, pixels)
    }

    func testTEXTextureRejectsBadMagic() {
        var bad = Data()
        bad.appendCString("NOTATEX!")
        XCTAssertThrowsError(try TEXTexture(data: bad)) {
            guard case SceneTextureFormatError.badMagic = $0 else {
                return XCTFail("expected .badMagic, got \($0)")
            }
        }
    }

    func testTEXTextureFlagsVideoViaFlagBit() {
        // flags & 32 marks a video texture regardless of pixel format — the texture never reaches
        // pixel decoding at all, so the "pixels" payload here is just arbitrary placeholder bytes.
        let placeholderPayload = Data("not really a video, just testing the flag path".utf8)
        let texData = makeRGBA8888TEX(width: 2, height: 2, pixels: placeholderPayload, flags: 32)

        XCTAssertThrowsError(try TEXTexture(data: texData)) {
            guard case SceneTextureFormatError.videoPayload(let payload) = $0 else {
                return XCTFail("expected .videoPayload, got \($0)")
            }
            XCTAssertEqual(payload, placeholderPayload)
        }
    }

    func testTEXTextureSniffsFtypBoxEvenWithoutFlag() {
        // The flag bit is Wallpaper Engine's own declared signal, but some real files only show
        // it via the payload itself starting with an MP4 "ftyp" box 4 bytes in (TEX.swift mirrors
        // this exact sniff after the normal decompression step).
        var mp4Like = Data([0, 0, 0, 0x18])  // box size (arbitrary, unused by the sniff)
        mp4Like.append(Data("ftyp".utf8))
        mp4Like.append(Data("isommp42".utf8))
        let texData = makeRGBA8888TEX(width: 1, height: 1, pixels: mp4Like)

        XCTAssertThrowsError(try TEXTexture(data: texData)) {
            guard case SceneTextureFormatError.videoPayload(let payload) = $0 else {
                return XCTFail("expected .videoPayload, got \($0)")
            }
            XCTAssertEqual(payload, mp4Like)
        }
    }

    // MARK: - SceneTextureResolver

    private func makeSceneArchive(sceneJSON: [String: Any], extraFiles: [String: Data] = [:]) -> PKGArchive {
        let sceneData = try! JSONSerialization.data(withJSONObject: sceneJSON)
        var entries: [(String, Data)] = [("scene.json", sceneData)]
        entries.append(contentsOf: extraFiles.map { ($0.key, $0.value) })
        return try! PKGArchive(data: makePKG(entries: entries))
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testResolverPrefersFullscreenLayerOverOthers() {
        let scene: [String: Any] = [
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [
                ["image": "models/icon.json"],
                ["image": "models/background.json"],
            ],
        ]
        let archive = makeSceneArchive(sceneJSON: scene, extraFiles: [
            "models/icon.json": json(["material": "materials/icon.json"]),
            "materials/icon.json": json(["textures": ["icon_tex"]]),
            "models/background.json": json(["material": "materials/background.json", "fullscreen": true]),
            "materials/background.json": json(["textures": ["bg_tex"]]),
        ])

        let candidates = SceneTextureResolver.candidateTexturePaths(in: archive)
        XCTAssertEqual(candidates.first?.path, "materials/bg_tex.tex")
        XCTAssertEqual(candidates.first?.isLikelyBackground, true)
        XCTAssertEqual(candidates.last?.path, "materials/icon_tex.tex")
        XCTAssertEqual(candidates.last?.isLikelyBackground, false)
    }

    func testResolverPrefersSizeMatchingCanvasOverUnmatchedSize() {
        let scene: [String: Any] = [
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [
                ["image": "models/small.json"],
                ["image": "models/fullsize.json"],
            ],
        ]
        let archive = makeSceneArchive(sceneJSON: scene, extraFiles: [
            "models/small.json": json(["material": "materials/small.json", "width": 64, "height": 64]),
            "materials/small.json": json(["textures": ["small_tex"]]),
            "models/fullsize.json": json(["material": "materials/fullsize.json", "width": 1920, "height": 1080]),
            "materials/fullsize.json": json(["textures": ["full_tex"]]),
        ])

        let candidates = SceneTextureResolver.candidateTexturePaths(in: archive)
        XCTAssertEqual(candidates.first?.path, "materials/full_tex.tex")
    }

    func testResolverSkipsObjectsWithoutAnImageKey() {
        let scene: [String: Any] = [
            "objects": [
                ["particle": "effects/snow.json"],
                ["sound": "audio/wind.json"],
                ["image": "models/only_image.json"],
            ],
        ]
        let archive = makeSceneArchive(sceneJSON: scene, extraFiles: [
            "models/only_image.json": json(["material": "materials/only.json"]),
            "materials/only.json": json(["textures": ["only_tex"]]),
        ])

        let candidates = SceneTextureResolver.candidateTexturePaths(in: archive)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.path, "materials/only_tex.tex")
    }

    func testResolverReturnsEmptyWhenNoSceneJSON() {
        let archive = try! PKGArchive(data: makePKG(entries: [("other.txt", Data("x".utf8))]))
        XCTAssertEqual(SceneTextureResolver.candidateTexturePaths(in: archive).count, 0)
    }

    // MARK: - SteamWorkshopPreview Types

    func testSteamWorkshopPreviewTypeDistinction() {
        let videoPreview = SteamWorkshopPreview(title: "Vid", previewImageURL: nil, fileSizeText: nil, workshopType: "Video")
        XCTAssertFalse(videoPreview.isScene)
        XCTAssertFalse(videoPreview.isUnsupportedType)

        let scenePreview = SteamWorkshopPreview(title: "Scn", previewImageURL: nil, fileSizeText: nil, workshopType: "Scene")
        XCTAssertTrue(scenePreview.isScene)
        XCTAssertFalse(scenePreview.isUnsupportedType)

        let webPreview = SteamWorkshopPreview(title: "Web", previewImageURL: nil, fileSizeText: nil, workshopType: "Web")
        XCTAssertFalse(webPreview.isScene)
        XCTAssertTrue(webPreview.isUnsupportedType)

        let appPreview = SteamWorkshopPreview(title: "App", previewImageURL: nil, fileSizeText: nil, workshopType: "Application")
        XCTAssertFalse(appPreview.isScene)
        XCTAssertTrue(appPreview.isUnsupportedType)
    }
}
