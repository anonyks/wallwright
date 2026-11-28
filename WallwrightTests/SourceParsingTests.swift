//
//  SourceParsingTests.swift
//  WallwrightTests
//
//  The page shapes below are trimmed from what the sites served on 2026-11-28.
//

import XCTest
@testable import Wallwright

final class SourceParsingTests: XCTestCase {
    private func button(_ href: String) -> String {
        """
        <a href="\(href)" download="x.mp4" rel="nofollow" id="primaryDownloadBtn" data-app-id="1">Download</a>
        """
    }

    func testDesktopHutReadsTheDownloadButtonOnEitherOfItsHosts() {
        for address in [
            "https://media.desktophut.com/files/1756906145.mp4",
            "https://www.desktophut.com/files/S74x_Black-Curtain-4K.mp4",
            "https://media.desktophut.com/files/Z0Q-samurai.zip",
        ] {
            XCTAssertEqual(DesktopHutService.parseDownloadURL(from: button(address))?.absoluteString, address)
        }
    }

    func testDesktopHutRejectsAddressesThatAreNotItsOwnFiles() {
        for address in [
            "https://example.com/files/a.mp4",
            "https://desktophut.com.example.com/files/a.mp4",
            "http://media.desktophut.com/files/a.mp4",
            "https://media.desktophut.com/previews/a-player.mp4",
        ] {
            XCTAssertNil(DesktopHutService.parseDownloadURL(from: button(address)), address)
        }
    }

    func testDesktopHutFallsBackToADirectVideoLinkWithoutTheButton() {
        let html = #"<a href="https://media.desktophut.com/files/a.mp4">file</a>"#
        XCTAssertEqual(DesktopHutService.parseDownloadURL(from: html)?.lastPathComponent, "a.mp4")
        XCTAssertNil(DesktopHutService.parseDownloadURL(from: "<p>nothing here</p>"))
    }

    func testAlphaCodersTitlesAndTagsAreDecodedTwice() {
        let html = """
        <div itemscope itemtype="http://schema.org/ImageObject">
        <meta itemprop="contentUrl" content="https://images.alphacoders.com/1/123.png">
        <meta itemprop="url" content="https://wall.alphacoders.com/big.php?i=123">
        <meta itemprop="thumbnailUrl" content="https://images.alphacoders.com/1/thumb-123.png">
        <meta itemprop="name" content="NARUTO &amp;amp; KURAMA">
        <meta itemprop="keywords" content="Rock &amp;amp; Roll, Anime">
        </div>
        """
        let item = AlphaCodersService.parseItems(from: html).first
        XCTAssertEqual(item?.title, "NARUTO & KURAMA")
        XCTAssertEqual(item?.tags, ["Rock & Roll", "Anime"])
    }
}
