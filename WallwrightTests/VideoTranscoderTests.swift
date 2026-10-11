//
//  VideoTranscoderTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

/// Guarded on `VideoTranscoder.isAvailable` (ffmpeg/ffprobe on PATH or Homebrew's default
/// location), same pattern as `SceneFallbackTests.testLiveExtractionOnDownloadedScenesIfPresent` —
/// runs for real against a real (synthetic, generated here) video file rather than mocking ffmpeg
/// itself, consistent with how every other subprocess-shelling service in this app is verified.
final class VideoTranscoderTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "VideoTranscoderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// Generates a short, solid-color H.264 mp4 at the given resolution directly via ffmpeg's own
    /// `testsrc` filter — no real footage needed, just real dimensions and a real compatible codec
    /// in a real native container, which is exactly what `ensureCompatible`'s guard inspects.
    private func makeTestVideo(width: Int, height: Int, in dir: URL) -> URL {
        let url = dir.appending(path: "test-\(width)x\(height).mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: VideoTranscoder.ffmpegPath!)
        process.arguments = [
            "-y", "-f", "lavfi", "-i", "testsrc=duration=1:size=\(width)x\(height):rate=10",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return url
    }

    /// The real gap this covers: a source already in a compatible codec/container used to pass
    /// through `ensureCompatible` completely untouched regardless of resolution — only a source
    /// needing a codec re-encode anyway ever got scaled down. Confirmed live that
    /// `AVPlayerItem.preferredMaximumResolution` (relied on elsewhere to cap *playback* decode
    /// resolution) has no effect on local files at all, making this the only place an oversized
    /// source's resolution can actually be capped.
    func testOversizedCompatibleSourceGetsDownscaled() async throws {
        try XCTSkipUnless(VideoTranscoder.isAvailable, "ffmpeg/ffprobe not installed")
        let dir = makeTempDir()
        let source = makeTestVideo(width: 7680, height: 4320, in: dir)
        guard let sourceInfo = VideoTranscoder.probeVideoInfo(at: source) else {
            XCTFail("ffmpeg failed to produce a readable test video — can't verify this live")
            return
        }
        XCTAssertEqual(sourceInfo.width, 7680)
        XCTAssertEqual(sourceInfo.height, 4320)

        let result = try await VideoTranscoder.ensureCompatible(source, outputDirectory: dir, deleteSourceOnSuccess: false)

        XCTAssertNotEqual(result.url, source, "an oversized source must not be passed through untouched")
        guard let outputInfo = VideoTranscoder.probeVideoInfo(at: result.url) else {
            XCTFail("couldn't read the transcoded output back")
            return
        }
        XCTAssertLessThanOrEqual(outputInfo.width, 3840)
        XCTAssertLessThanOrEqual(outputInfo.height, 2160)
    }

    /// The existing, already-shipped behavior this change must not disturb: a compatible codec in
    /// a native container, already within the resolution cap, still passes through untouched.
    func testCompatibleSourceWithinCapPassesThroughUntouched() async throws {
        try XCTSkipUnless(VideoTranscoder.isAvailable, "ffmpeg/ffprobe not installed")
        let dir = makeTempDir()
        let source = makeTestVideo(width: 640, height: 360, in: dir)
        guard VideoTranscoder.probeVideoInfo(at: source) != nil else {
            XCTFail("ffmpeg failed to produce a readable test video — can't verify this live")
            return
        }

        let result = try await VideoTranscoder.ensureCompatible(source, outputDirectory: dir, deleteSourceOnSuccess: false)

        XCTAssertEqual(result.url, source)
        XCTAssertNil(result.transcodedFrom)
    }
}
