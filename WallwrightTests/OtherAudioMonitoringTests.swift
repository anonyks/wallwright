//
//  OtherAudioMonitoringTests.swift
//  WallwrightTests
//

import XCTest
@testable import Wallwright

final class OtherAudioMonitoringTests: XCTestCase {
    private func isNeeded(
        _ rule: GSPlayback, volume: Float, otherAppPlaying: Bool = false, mutedByUser: Bool = false
    ) -> Bool {
        GlobalSettingsViewModel.needsOtherAudioMonitoring(
            rule: rule, volume: volume, otherAppPlaying: otherAppPlaying, mutedByUser: mutedByUser
        )
    }

    func testRunsWhileTheWallpaperCanBeHeard() {
        XCTAssertTrue(isNeeded(.mute, volume: 1))
        XCTAssertTrue(isNeeded(.pause, volume: 0.5))
        XCTAssertFalse(isNeeded(.keepRunning, volume: 1))
    }

    /// Stopping here would unmute the wallpaper, and the next check would mute it again.
    func testKeepsRunningWhileTheMuteRuleIsWhatSilencedTheWallpaper() {
        XCTAssertTrue(isNeeded(.mute, volume: 0, otherAppPlaying: true))
    }

    func testStopsWhenTheWallpaperIsSilentForAnyOtherReason() {
        XCTAssertFalse(isNeeded(.mute, volume: 0))
        XCTAssertFalse(isNeeded(.mute, volume: 0, otherAppPlaying: true, mutedByUser: true))
        XCTAssertFalse(isNeeded(.pause, volume: 0, otherAppPlaying: true))
        XCTAssertFalse(isNeeded(.keepRunning, volume: 0, otherAppPlaying: true))
    }
}
