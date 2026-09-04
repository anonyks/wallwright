//
//  DesktopHutService.swift
//  Wallwright
//
//  Fetches and imports live wallpapers from desktophut.com. Like MotionBgsService/MoeWallsService,
//  there's no public API — this parses server-rendered listing/detail HTML directly.
//
//  Easier than MoeWalls: the detail page's actual "Download Original" button is a plain, direct
//  `<a href="https://www.desktophut.com/files/{id}-{slug}.mp4">` link sitting in the server-
//  rendered HTML — no obfuscated click handler, no token reconstruction. Confirmed live
//  (2026-07-30) that URL serves the real file over a bare GET with no cookies/referrer/session
//  (`content-disposition: attachment`, direct 200).
//

import AppKit
import Foundation

struct DesktopHutItem: Identifiable, Hashable {
    /// The URL slug (e.g. "monochrome-samurai-with-glowing-blue-eyes-live-wallpaper-nlgi") — used
    /// as the stable identifier since DesktopHut's URLs are slug-based, not numeric IDs (unlike
    /// MoeWalls' post IDs).
    let id: String
    let title: String
    let detailURL: URL
    let thumbnailURL: URL
    /// A short, muted looping clip for grid-hover previews — parsed straight out of the same
    /// listing HTML `parseItems` already fetches (each card embeds a `<video class="card-preview-
    /// video">` with this as its `data-src`), so no extra request is needed. `nil` when a card's
    /// markup doesn't include one (degrades to no hover preview, same as before this existed).
    let previewVideoURL: URL?
}

enum DesktopHutCategory: CaseIterable, Identifiable {
    case trending, anime, abstract, animals, sciFi, games, landscape, moviesTv, pixelArt, cars, comics, animation3d, tech, nature

    var id: Self { self }

    var displayName: String {
        switch self {
        case .trending: return "Trending"
        case .anime: return "Anime"
        case .abstract: return "Abstract"
        case .animals: return "Animals"
        case .sciFi: return "Sci-fi"
        case .games: return "Games"
        case .landscape: return "Landscape"
        case .moviesTv: return "Movies & TV"
        case .pixelArt: return "Pixel Art"
        case .cars: return "Cars"
        case .comics: return "Comics"
        case .animation3d: return "3D Animation"
        case .tech: return "Tech"
        case .nature: return "Nature"
        }
    }

    /// Path relative to the site root for page 1 of this category. Mixed slug casing/shapes
    /// (`category/anime-live-wallpapers` vs the root `/`) confirmed directly off the site's own
    /// nav menu, not guessed.
    private var basePath: String {
        switch self {
        case .trending: return "/popular-live-wallpapers"
        case .anime: return "/category/anime-live-wallpapers"
        case .abstract: return "/category/abstract-live-wallpapers"
        case .animals: return "/category/animals-live-wallpapers"
        case .sciFi: return "/category/fantasy-sci-fi-live-wallpapers"
        case .games: return "/category/games-live-wallpapers"
        case .landscape: return "/category/landscape-live-wallpapers"
        case .moviesTv: return "/category/movies-tv-live-wallpapers"
        case .pixelArt: return "/category/pixel-art-live-wallpapers"
        case .cars: return "/category/cars-motorcycles-live-wallpapers"
        case .comics: return "/category/comics-live-wallpapers"
        case .animation3d: return "/category/3d-animation-live-wallpapers"
        case .tech: return "/category/tech-live-wallpapers"
        case .nature: return "/category/nature-live-wallpapers"
        }
    }

    /// `?page=N` query-param pagination, confirmed live; page 1 has no query param at all.
    func path(page: Int) -> String {
        page <= 1 ? basePath : basePath + "?page=\(page)"
    }
}

enum DesktopHutError: LocalizedError {
    case invalidURL
    case requestFailed
    case httpError(Int)
    case parsingFailed
    case downloadLinkNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid DesktopHut URL"
        case .requestFailed: return "Failed to reach desktophut.com — check your network connection"
        case .httpError(let code): return "desktophut.com returned HTTP \(code)"
        case .parsingFailed: return "Could not parse the wallpaper list"
        case .downloadLinkNotFound: return "Couldn't find a download link on this wallpaper's page"
        }
    }
}

final class DesktopHutService {
    static let baseURL = "https://www.desktophut.com"

    private func fetchHTML(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.browseSource.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { throw DesktopHutError.requestFailed }
        guard httpResponse.statusCode == 200 else { throw DesktopHutError.httpError(httpResponse.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw DesktopHutError.parsingFailed }
        return html
    }

    /// Fetches and parses one listing page for a category.
    func fetchItems(category: DesktopHutCategory, page: Int = 1) async throws -> [DesktopHutItem] {
        guard let url = URL(string: Self.baseURL + category.path(page: page)) else { throw DesktopHutError.invalidURL }
        return Self.parseItems(from: try await fetchHTML(url))
    }

    /// Free-text search — the term is a URL *path* segment (`/search/{term}`), not a `q=` query
    /// param. Confirmed live (2026-08-01) that `GET /search?q=...` silently ignores the query
    /// entirely: `naruto`, `saint`, and a nonsense string all returned the exact same default
    /// listing, byte-for-byte, with `cache-control: no-cache` ruling out a caching explanation.
    /// Found the real route from the page's own live-search dropdown JS (`liveSearchInput`'s
    /// "View all results" link builds `/search/' + encodeURIComponent(term)`) — confirmed that
    /// path returns genuinely filtered, relevant results. Pagination stays a query param on top
    /// of that path (`/search/{term}?page=N`); confirmed `/search/{term}/page/N` 404s.
    func searchItems(query: String, page: Int = 1) async throws -> [DesktopHutItem] {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw DesktopHutError.invalidURL
        }
        var components = URLComponents(string: "\(Self.baseURL)/search/\(encodedQuery)")
        components?.queryItems = page > 1 ? [URLQueryItem(name: "page", value: String(page))] : nil
        guard let url = components?.url else { throw DesktopHutError.invalidURL }
        return Self.parseItems(from: try await fetchHTML(url))
    }

    /// Parses wallpaper cards out of a DesktopHut listing page.
    ///
    /// Two-pass: find each card anchor's position first, then extract the thumbnail/title only
    /// from the HTML slice between that anchor and the next one. Card markup is NOT consistent
    /// across page types — category/tag/search pages have `title="Download {Title}"` on the
    /// anchor itself, but the Trending page (`/popular-live-wallpapers`) doesn't, and its special
    /// "Trending Now" ranking mini-cards lack the full `<img>`+`card-title` structure entirely. A
    /// single greedy/lazy regex spanning the whole card either misses Trending outright or, worse,
    /// bleeds past a malformed mini-card and pairs one card's slug with a later card's title. The
    /// `card-title` element inside the hover overlay is the one thing present and correctly scoped
    /// on every page variant, so per-card slicing + extracting within each slice is what's robust.
    static func parseItems(from html: String) -> [DesktopHutItem] {
        guard let anchorRegex = try? NSRegularExpression(pattern: #"<a href="(/[a-z0-9-]+)" class="wallpaper-card""#),
              let imgRegex = try? NSRegularExpression(pattern: #"<img src="(https://www\.desktophut\.com/images/[^"]+\.webp)""#),
              let titleRegex = try? NSRegularExpression(pattern: #"card-title">([^<]+)<"#),
              let previewRegex = try? NSRegularExpression(pattern: #"card-preview-video[^>]*data-src="(https://www\.desktophut\.com/previews/[^"]+\.mp4)""#)
        else { return [] }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let anchorMatches = anchorRegex.matches(in: html, range: fullRange)

        var seenSlugs = Set<String>()
        var items: [DesktopHutItem] = []

        for (index, match) in anchorMatches.enumerated() {
            guard let slugRange = Range(match.range(at: 1), in: html),
                  let anchorRange = Range(match.range, in: html)
            else { continue }

            let slug = String(html[slugRange])
            let id = String(slug.dropFirst()) // drop the leading "/"
            guard !seenSlugs.contains(id) else { continue }

            let blockEnd: String.Index
            if index + 1 < anchorMatches.count, let nextRange = Range(anchorMatches[index + 1].range, in: html) {
                blockEnd = nextRange.lowerBound
            } else {
                blockEnd = html.endIndex
            }
            guard anchorRange.lowerBound < blockEnd else { continue }
            let block = String(html[anchorRange.lowerBound..<blockEnd])
            let blockRange = NSRange(block.startIndex..<block.endIndex, in: block)

            guard let imgMatch = imgRegex.firstMatch(in: block, range: blockRange),
                  let thumbRange = Range(imgMatch.range(at: 1), in: block),
                  let titleMatch = titleRegex.firstMatch(in: block, range: blockRange),
                  let titleRange = Range(titleMatch.range(at: 1), in: block)
            else { continue }

            guard let detailURL = URL(string: Self.baseURL + slug),
                  let thumbnailURL = URL(string: String(block[thumbRange]))
            else { continue }

            seenSlugs.insert(id)
            let title = decodeHTMLEntities(String(block[titleRange]))
            let previewVideoURL = previewRegex.firstMatch(in: block, range: blockRange)
                .flatMap { Range($0.range(at: 1), in: block) }
                .flatMap { URL(string: String(block[$0])) }
            items.append(DesktopHutItem(id: id, title: title, detailURL: detailURL, thumbnailURL: thumbnailURL, previewVideoURL: previewVideoURL))
        }

        return items
    }

    /// Decodes HTML entities (`&quot;`, `&amp;`, ...) in scraped text via the HTML-document reader
    /// rather than manual character replacement, since titles can contain arbitrary entities.
    private static func decodeHTMLEntities(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return string }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else { return string }
        return attributed.string
    }

    /// Parses an item's own descriptive tags off its detail page (the `#tag pill` list under the
    /// description) — confirmed live: these are plain `#word` text nodes, not anchor tags, so this
    /// matches on the leading `#` rather than an href pattern the way MoeWalls' tag parsing does.
    static func parseTags(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #">#([A-Za-z][A-Za-z0-9 ]{1,30})<"#)
        else { return [] }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range]).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Extracts the direct download URL from a detail page — see this file's header comment for
    /// why no token/obfuscation handling is needed here, unlike MoeWalls.
    static func parseDownloadURL(from html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"href="(https://www\.desktophut\.com/files/[^"]+\.mp4)""#)
        else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: nsRange), let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return URL(string: String(html[range]))
    }

    /// Fetches an item's detail page and resolves its real download URL + tags.
    func resolveDownload(for item: DesktopHutItem) async throws -> (url: URL, tags: [String]) {
        let html = try await fetchHTML(item.detailURL)
        guard let downloadURL = Self.parseDownloadURL(from: html) else { throw DesktopHutError.downloadLinkNotFound }
        return (downloadURL, Self.parseTags(from: html))
    }

    /// Downloads the wallpaper video for the given item to a temporary location and returns its
    /// local URL, via `DirectURLImporter` for real byte-level progress.
    func downloadVideo(for item: DesktopHutItem, onProgress: @escaping (Double?) -> Void = { _ in }) async throws -> (url: URL, tags: [String]) {
        let (downloadURL, tags) = try await resolveDownload(for: item)
        let destination = try await DirectURLImporter.download(from: downloadURL, onProgress: onProgress)
        return (destination, tags)
    }

    /// Index of what's already in the local library, used to detect "you already have this" before
    /// re-downloading — same pattern as `MotionBgsService`/`MoeWallsService`, keyed on the slug
    /// (String) rather than an Int since DesktopHut has no numeric ID (matches `WallperService`'s
    /// String-keyed precedent for the same reason).
    struct ExistingLibraryIndex {
        let sourceIds: Set<String>
        let titles: Set<String>
    }

    /// Reads the already-in-memory library (`ContentViewModel.wallpapers`) instead of re-scanning
    /// `wallpapersDirectory` and re-decoding every `project.json` from disk — see
    /// `MotionBgsService.existingLibraryIndex(wallpapers:)`'s doc comment.
    static func existingLibraryIndex(wallpapers: [WEWallpaper]) -> ExistingLibraryIndex {
        var sourceIds = Set<String>()
        var titles = Set<String>()
        for wallpaper in wallpapers {
            let project = wallpaper.project
            titles.insert(project.title.lowercased())

            if project.sourceProvider == "desktophut", let sourceId = project.sourceId {
                sourceIds.insert(sourceId)
            }
        }
        return ExistingLibraryIndex(sourceIds: sourceIds, titles: titles)
    }
}
