//
//  AlphaCodersService.swift
//  Wallwright
//
//  Fetches and imports still wallpapers from alphacoders.com's "The Best" and "Popular" listings.
//  Simpler than UhdPaper/DesktopHut in two ways:
//
//  - Every listing page already embeds full schema.org `ImageObject` microdata per card —
//    `contentUrl` is the genuine full-resolution file (confirmed live: a sampled `contentUrl`
//    resolved to a real 3620x2594 PNG), so there's no separate detail-page fetch/resolve step at
//    all, unlike UhdPaper's `dlqry` template or DesktopHut's per-post scrape.
//  - Pagination beyond page 1 is via the site's own infinite-scroll endpoint, found in its inline
//    JS (`loadNextPage()`): `GET {path}?page={n}&quickload=1` with header
//    `X-Requested-With: XMLHttpRequest` — confirmed live to return genuinely new, different items
//    each page.
//
//  Free-text search uses the site's own search form (`GET /search/view?q=...&type=wallpaper`, the
//  exact fields off the header search box's `<form>`/`<input>`) — confirmed live it returns
//  genuinely relevant results. `robots.txt` disallows crawling `/search/view` itself (an SEO
//  courtesy so search engines don't index infinite query-permutation pages, the same reason nearly
//  every site with a search box disallows it) — this app makes one request per explicit user
//  search action, the same as a person typing into the site's own search box in a browser, not a
//  crawler indexing it. The endpoint redirects to a query-specific results page (e.g. "naruto" →
//  `/naruto-wallpapers`) whose slug isn't predictable in advance, so the first page's *resolved*
//  URL is captured and reused for `?page=N&quickload=1` pagination, same convention as category
//  browsing.
//

import Foundation

struct AlphaCodersItem: Identifiable, Hashable {
    /// The numeric filename stem of `contentUrl` (e.g. "605592" from ".../605/605592.png") — also
    /// the same ID used in the detail page's `?i=` query param, so it's stable across both.
    let id: String
    let title: String
    let tags: [String]
    let detailURL: URL
    let thumbnailURL: URL
    /// The genuine full-resolution file — already known from the listing page's own microdata, no
    /// detail-page visit needed to resolve it.
    let fullImageURL: URL
}

enum AlphaCodersCategory: CaseIterable, Identifiable {
    case theBest, popular

    var id: Self { self }

    var displayName: String {
        switch self {
        case .theBest: return "The Best"
        case .popular: return "Popular"
        }
    }

    var path: String {
        switch self {
        case .theBest: return "the-best-wallpapers"
        case .popular: return "popular-wallpapers"
        }
    }
}

enum AlphaCodersError: LocalizedError {
    case invalidURL
    case requestFailed
    case httpError(Int)
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid AlphaCoders URL"
        case .requestFailed: return "Failed to reach alphacoders.com — check your network connection"
        case .httpError(let code): return "alphacoders.com returned HTTP \(code)"
        case .parsingFailed: return "Could not parse the wallpaper list"
        }
    }
}

final class AlphaCodersService {
    static let baseURL = "https://alphacoders.com"

    /// Returns the resolved (post-redirect) URL alongside the HTML — needed for search, whose
    /// results page lives at a query-specific slug the caller can't predict in advance.
    private func fetchHTML(_ url: URL, headers: [String: String] = [:]) async throws -> (html: String, resolvedURL: URL) {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.browseSource.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AlphaCodersError.requestFailed }
        guard httpResponse.statusCode == 200 else { throw AlphaCodersError.httpError(httpResponse.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw AlphaCodersError.parsingFailed }
        return (html, response.url ?? url)
    }

    /// Fetches and parses one listing page. Page 1 is the plain category URL; page 2+ goes through
    /// the infinite-scroll endpoint (see header comment) — confirmed live that page 1 does NOT need
    /// `quickload=1` (it's a normal full page load), while page 2+ does.
    func fetchItems(category: AlphaCodersCategory, page: Int = 1) async throws -> [AlphaCodersItem] {
        guard var components = URLComponents(string: "\(Self.baseURL)/\(category.path)") else {
            throw AlphaCodersError.invalidURL
        }
        var headers: [String: String] = [:]
        if page > 1 {
            components.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "quickload", value: "1"),
            ]
            headers["X-Requested-With"] = "XMLHttpRequest"
        }
        guard let url = components.url else { throw AlphaCodersError.invalidURL }
        let (html, _) = try await fetchHTML(url, headers: headers)
        return Self.parseItems(from: html)
    }

    /// Free-text search — see header comment for the endpoint and the resolved-URL pagination
    /// scheme. `resolvedSearchURL` should be `nil` for the first page of a new search, then the
    /// `resolvedURL` this returns should be passed back in for every subsequent page.
    func searchItems(query: String, page: Int, resolvedSearchURL: URL?) async throws -> (items: [AlphaCodersItem], resolvedURL: URL) {
        let url: URL
        var headers: [String: String] = [:]
        if let resolvedSearchURL, page > 1 {
            guard var components = URLComponents(url: resolvedSearchURL, resolvingAgainstBaseURL: false) else {
                throw AlphaCodersError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "quickload", value: "1"),
            ]
            guard let pagedURL = components.url else { throw AlphaCodersError.invalidURL }
            url = pagedURL
            headers["X-Requested-With"] = "XMLHttpRequest"
        } else {
            guard var components = URLComponents(string: "\(Self.baseURL)/search/view") else {
                throw AlphaCodersError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "wallpaper"),
            ]
            guard let searchURL = components.url else { throw AlphaCodersError.invalidURL }
            url = searchURL
        }
        let (html, resolvedURL) = try await fetchHTML(url, headers: headers)
        return (Self.parseItems(from: html), resolvedURL)
    }

    /// Parses every `schema.org/ImageObject` card out of a listing page. Two-pass, same shape as
    /// `DesktopHutService.parseItems`: find each card's start position first, then extract fields
    /// only from the slice up to the next card (or end of document), since a single regex spanning
    /// a whole card would risk bleeding into the next one.
    static func parseItems(from html: String) -> [AlphaCodersItem] {
        guard let markerRegex = try? NSRegularExpression(pattern: #"itemtype="http://schema\.org/ImageObject""#)
        else { return [] }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let markers = markerRegex.matches(in: html, range: fullRange)

        var items: [AlphaCodersItem] = []
        for (index, marker) in markers.enumerated() {
            guard let markerRange = Range(marker.range, in: html) else { continue }
            let blockEnd = (index + 1 < markers.count ? Range(markers[index + 1].range, in: html)?.lowerBound : nil) ?? html.endIndex
            guard markerRange.upperBound < blockEnd else { continue }
            let block = String(html[markerRange.upperBound..<blockEnd])

            guard let contentUrlString = firstMatch(#"itemprop="contentUrl" content="([^"]+)""#, in: block),
                  let fullImageURL = URL(string: contentUrlString),
                  let detailUrlString = firstMatch(#"itemprop="url" content="([^"]+)""#, in: block),
                  let detailURL = URL(string: detailUrlString),
                  let thumbUrlString = firstMatch(#"itemprop="thumbnailUrl" content="([^"]+)""#, in: block),
                  let thumbnailURL = URL(string: thumbUrlString)
            else { continue }

            let rawName = firstMatch(#"itemprop="name" content="([^"]+)""#, in: block)
            let rawKeywords = firstMatch(#"itemprop="keywords" content="([^"]+)""#, in: block) ?? ""

            let id = fullImageURL.deletingPathExtension().lastPathComponent
            let title = decodeHTMLEntities(rawName ?? id)
            let tags = rawKeywords.components(separatedBy: ", ")
                .map(decodeHTMLEntities)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            items.append(AlphaCodersItem(id: id, title: title, tags: tags, detailURL: detailURL, thumbnailURL: thumbnailURL, fullImageURL: fullImageURL))
        }
        return items
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[matchRange])
    }

    /// Listing pages HTML-escape their microdata `content="..."` attributes (e.g. `&amp;` in a
    /// title with "&" in it) — unescape the handful of entities that actually show up here.
    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Downloads the wallpaper image for the given item — `fullImageURL` is already the genuine
    /// full-resolution file (see header comment), so this is a direct download, no resolve step.
    func downloadImage(for item: AlphaCodersItem, onProgress: @escaping (Double?) -> Void = { _ in }) async throws -> URL {
        try await DirectURLImporter.download(from: item.fullImageURL, onProgress: onProgress)
    }

    /// Index of what's already in the local library — same pattern as `DesktopHutService`'s.
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

            if project.sourceProvider == "alphacoders", let sourceId = project.sourceId {
                sourceIds.insert(sourceId)
            }
        }
        return ExistingLibraryIndex(sourceIds: sourceIds, titles: titles)
    }
}
