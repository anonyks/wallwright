//
//  UhdPaperService.swift
//  Wallwright
//
//  Fetches and imports still wallpapers from uhdpaper.com — a Blogger-hosted blog. Rather than
//  regex-scraping listing HTML (fragile, like DesktopHut needed), this uses Blogger's own public
//  JSON feed API for listing/search — confirmed live (2026-07-30) to work identically for both a
//  real Blogger label (`/feeds/posts/default/-/{Label}`) and a free-text search
//  (`/feeds/posts/default?q=...`, the same mechanism the site's own nav links use), with
//  `start-index` giving clean, non-overlapping pagination.
//
//  The one genuinely reverse-engineered part is the download URL. A detail page's raw HTML (no JS
//  execution needed — this is present verbatim in the server response) embeds the exact template
//  its theme's script uses to build download links:
//
//    var dlqry='https://img.uhdpaper.com/wallpaper/{slug}-{code}';   // code = "{digits}@{shard}@{letter}"
//    document.getElementById("_4k").href = dlqry.replace(/.../, '//image-$4.$1-4k-wallpaper-uhdpaper.com-$2.jpg');
//    // ...same shape for _2k, _hd, and _8k (only present on posts actually tagged 8K)
//
//  i.e. the real file lives at `https://image-{shard}.uhdpaper.com/wallpaper/{slug}-{quality}-
//  wallpaper-uhdpaper.com-{code}.jpg` — confirmed live by constructing this exact URL for a real
//  post and loading it (resolved to a genuine 3840x2160 JPEG).
//

import Foundation

struct UhdPaperItem: Identifiable, Hashable {
    /// The detail page's slug (e.g. "gojo-eyes-4k-wallpaper-2845k") — stable, used as the source ID.
    let id: String
    let title: String
    let tags: [String]
    let detailURL: URL
    let thumbnailURL: URL
}

enum UhdPaperCategory: CaseIterable, Identifiable {
    case latest, game, anime, movie, series, abstract, animals, celebrity, comics, digitalArt, fantasy, nature, scenery, sciFi, space

    var id: Self { self }

    var displayName: String {
        switch self {
        case .latest: return "Home"
        case .game: return "Game"
        case .anime: return "Anime"
        case .movie: return "Movie"
        case .series: return "Series"
        case .abstract: return "Abstract"
        case .animals: return "Animals"
        case .celebrity: return "Celebrity"
        case .comics: return "Comics"
        case .digitalArt: return "Digital Art"
        case .fantasy: return "Fantasy"
        case .nature: return "Nature"
        case .scenery: return "Scenery"
        case .sciFi: return "Sci-Fi"
        case .space: return "Space"
        }
    }

    /// The exact `q=` value the site's own nav uses for this category (confirmed off its actual
    /// hrefs, e.g. `/search?q=Video+Game&by-date=true`) — `nil` for "Home" means no filter at all.
    var query: String? {
        switch self {
        case .latest: return nil
        case .game: return "Video Game"
        case .anime: return "Anime"
        case .movie: return "Movie"
        case .series: return "TV Series"
        case .abstract: return "Abstract"
        case .animals: return "Animals"
        case .celebrity: return "Celebrity"
        case .comics: return "Comics"
        case .digitalArt: return "Digital Art"
        case .fantasy: return "Fantasy"
        case .nature: return "Nature"
        case .scenery: return "Scenery"
        case .sciFi: return "Sci-Fi"
        case .space: return "Space"
        }
    }
}

enum UhdPaperError: LocalizedError {
    case invalidURL
    case requestFailed
    case httpError(Int)
    case parsingFailed
    case downloadLinkNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid UHDPaper URL"
        case .requestFailed: return "Failed to reach uhdpaper.com — check your network connection"
        case .httpError(let code): return "uhdpaper.com returned HTTP \(code)"
        case .parsingFailed: return "Could not parse the wallpaper list"
        case .downloadLinkNotFound: return "Couldn't find a download link on this wallpaper's page"
        }
    }
}

final class UhdPaperService {
    static let baseURL = "https://www.uhdpaper.com"
    private static let pageSize = 20

    /// uhdpaper.com's image CDN (both the thumbnail host and the asset host) enforces Referer-based
    /// hotlink protection — confirmed live via `curl`: a bare request 301/302-redirects instead of
    /// serving the file, but returns 200 directly once this header is set. Needed for both the
    /// thumbnail grid (`RetryingAsyncImage`, which has no way to attach headers unless told to) and
    /// the actual download (`DirectURLImporter`).
    static let refererHeaders = ["Referer": "\(baseURL)/"]

    /// Shape of Blogger's `alt=json` feed response — only the fields actually used.
    private struct FeedResponse: Decodable {
        struct Feed: Decodable {
            let entry: [Entry]?
        }
        struct Entry: Decodable {
            struct Text: Decodable {
                let t: String
                enum CodingKeys: String, CodingKey { case t = "$t" }
            }
            struct Link: Decodable {
                let rel: String
                let href: String
            }
            let title: Text
            let content: Text
            let link: [Link]
        }
        let feed: Feed
    }

    private func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.browseSource.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { throw UhdPaperError.requestFailed }
        guard httpResponse.statusCode == 200 else { throw UhdPaperError.httpError(httpResponse.statusCode) }
        return data
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        guard let html = String(data: data, encoding: .utf8) else { throw UhdPaperError.parsingFailed }
        return html
    }

    private func fetchFeed(query: String?, startIndex: Int) async throws -> [UhdPaperItem] {
        guard var components = URLComponents(string: "\(Self.baseURL)/feeds/posts/default") else {
            throw UhdPaperError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "alt", value: "json"),
            URLQueryItem(name: "max-results", value: String(Self.pageSize)),
            URLQueryItem(name: "start-index", value: String(startIndex)),
            query.map { URLQueryItem(name: "q", value: $0) },
        ].compactMap { $0 }
        guard let url = components.url else { throw UhdPaperError.invalidURL }

        let data = try await fetchData(url)
        guard let feed = try? JSONDecoder().decode(FeedResponse.self, from: data) else {
            throw UhdPaperError.parsingFailed
        }
        return (feed.feed.entry ?? []).compactMap(Self.parseEntry)
    }

    /// Fetches and parses one listing page for a category (page 1 = `startIndex: 1`).
    func fetchItems(category: UhdPaperCategory, startIndex: Int = 1) async throws -> [UhdPaperItem] {
        try await fetchFeed(query: category.query, startIndex: startIndex)
    }

    /// Free-text search — the same feed mechanism the site's own nav categories use.
    func searchItems(query: String, startIndex: Int = 1) async throws -> [UhdPaperItem] {
        try await fetchFeed(query: query, startIndex: startIndex)
    }

    /// Turns one feed entry into an item — title/tags cleanup, thumbnail suffix, slug extraction.
    private static func parseEntry(_ entry: FeedResponse.Entry) -> UhdPaperItem? {
        guard let detailHref = entry.link.first(where: { $0.rel == "alternate" })?.href,
              let detailURL = URL(string: detailHref)
        else { return nil }

        guard let imgSrcRegex = try? NSRegularExpression(pattern: #"src="([^"]+)""#) else { return nil }
        let contentRange = NSRange(entry.content.t.startIndex..<entry.content.t.endIndex, in: entry.content.t)
        guard let imgMatch = imgSrcRegex.firstMatch(in: entry.content.t, range: contentRange),
              let imgRange = Range(imgMatch.range(at: 1), in: entry.content.t)
        else { return nil }
        guard let thumbnailURL = URL(string: String(entry.content.t[imgRange]) + "-thumb.jpg") else { return nil }

        let id = detailURL.deletingPathExtension().lastPathComponent
        let (title, tags) = cleanTitle(from: entry.title.t)

        return UhdPaperItem(id: id, title: title, tags: tags, detailURL: detailURL, thumbnailURL: thumbnailURL)
    }

    /// Raw Blogger titles are a comma-separated word list ending in ", Wallpaper, #{code}" (e.g.
    /// "Anime, Girl, Tattoo, Sword, Wallpaper, #2255q") — strip that trailing boilerplate and the
    /// remaining words become both a clean space-joined title and a free set of tags, matching what
    /// the site's own JS-rendered grid shows (confirmed live) with no extra request needed.
    private static func cleanTitle(from rawTitle: String) -> (title: String, tags: [String]) {
        var words = rawTitle.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = words.last, last.hasPrefix("#") { words.removeLast() }
        if let last = words.last, last.caseInsensitiveCompare("Wallpaper") == .orderedSame { words.removeLast() }
        let title = words.joined(separator: " ")
        return (title.isEmpty ? rawTitle : title, words)
    }

    /// Resolves the best-available real download URL for an item by fetching its detail page and
    /// decoding the theme's own `dlqry`/quality-ID template — see this file's header comment.
    func resolveDownload(for item: UhdPaperItem) async throws -> URL {
        let html = try await fetchHTML(item.detailURL)

        guard let dlqryRegex = try? NSRegularExpression(pattern: #"var dlqry='https://img\.uhdpaper\.com/wallpaper/(.+?)-([0-9]+@[A-Za-z0-9]+@[A-Za-z0-9])'"#)
        else { throw UhdPaperError.downloadLinkNotFound }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = dlqryRegex.firstMatch(in: html, range: fullRange),
              let slugRange = Range(match.range(at: 1), in: html),
              let codeRange = Range(match.range(at: 2), in: html)
        else { throw UhdPaperError.downloadLinkNotFound }

        let slug = String(html[slugRange])
        let code = String(html[codeRange])
        let codeParts = code.components(separatedBy: "@")
        guard codeParts.count == 3 else { throw UhdPaperError.downloadLinkNotFound }
        let shard = codeParts[1]

        // Best available quality for this specific post — `_8k` only exists in the page's script
        // for posts actually tagged 8K; `_4k`/`_2k`/`_hd` are present otherwise.
        let bestTag = ["_8k", "_4k", "_2k", "_hd"].first { html.contains($0) } ?? "_hd"
        let quality = String(bestTag.dropFirst())

        guard let downloadURL = URL(string: "https://image-\(shard).uhdpaper.com/wallpaper/\(slug)-\(quality)-wallpaper-uhdpaper.com-\(code).jpg")
        else { throw UhdPaperError.downloadLinkNotFound }
        return downloadURL
    }

    /// Downloads the wallpaper image for the given item to a temporary location, via
    /// `DirectURLImporter` for real byte-level progress.
    func downloadImage(for item: UhdPaperItem, onProgress: @escaping (Double?) -> Void = { _ in }) async throws -> URL {
        let downloadURL = try await resolveDownload(for: item)
        return try await DirectURLImporter.download(from: downloadURL, headers: Self.refererHeaders, onProgress: onProgress)
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

            if project.sourceProvider == "uhdpaper", let sourceId = project.sourceId {
                sourceIds.insert(sourceId)
            }
        }
        return ExistingLibraryIndex(sourceIds: sourceIds, titles: titles)
    }
}
