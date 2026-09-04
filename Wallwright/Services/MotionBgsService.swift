//
//  MotionBgsService.swift
//  Wallwright
//
//  Fetches and imports live wallpapers from motionbgs.com. There is no public JSON API for this
//  site — it's a plain server-rendered site, so this parses the listing-page HTML directly rather
//  than loading the site in a WebView. Verified against the live site (2026-07-24): thumbnails and
//  video files serve with no auth, no referrer checks, and no rate limiting; robots.txt only
//  disallows /ajax/*, /admin/*, /a2/*, none of which this touches.
//

import Foundation

struct MotionBgsItem: Identifiable, Hashable {
    let id: Int
    let slug: String
    let title: String
    let thumbnailURL: URL

    /// A lightweight (sub-1MB) preview clip — same naming convention the site's own detail pages
    /// embed as `og:video`, but constructible directly from data we already have from listing
    /// pages, so no extra per-item request is needed just to enable hover-preview.
    var previewVideoURL: URL {
        URL(string: "\(MotionBgsService.baseURL)/media/\(id)/\(slug).960x540.mp4")!
    }

    /// This item's own page on motionbgs.com — same URL pattern `resolveDownload` already
    /// constructs internally, exposed here for a "copy/open source link" context menu action.
    var detailURL: URL {
        URL(string: "\(MotionBgsService.baseURL)/\(slug)")!
    }
}

enum MotionBgsCategory: CaseIterable, Identifiable {
    // "Mobile" and "GIFs" were here but always showed empty — motionbgs.com renders both with
    // completely different card markup than every other category (Mobile: portrait 235x418 crops
    // and slugs nested under /mobile/; GIFs: no video-wallpaper cards at all, just static .gif
    // images) that this parser doesn't handle, and neither fits this app's desktop-video-wallpaper
    // model even if parsed — Mobile's content is phone-portrait, and GIFs aren't the MP4s
    // downloadVideo()/VideoImporter expect. Removed rather than special-cased for content this app
    // can't actually use.
    case trending, fourK, anime, games, superhero, nature

    var id: Self { self }

    var displayName: String {
        switch self {
        case .trending: return "Trending"
        case .fourK: return "4K"
        case .anime: return "Anime"
        case .games: return "Games"
        case .superhero: return "Superhero"
        case .nature: return "Nature"
        }
    }

    /// Path relative to the site root for page 1 of this category.
    private var basePath: String {
        switch self {
        case .trending: return "/"
        case .fourK: return "/4k/"
        case .anime: return "/tag:anime/"
        case .games: return "/tag:games/"
        case .superhero: return "/tag:superhero/"
        case .nature: return "/tag:nature/"
        }
    }

    /// Pagination is `/{basePath}/{page}/`; page 1 has no page segment.
    func path(page: Int) -> String {
        page <= 1 ? basePath : basePath + "\(page)/"
    }
}

enum MotionBgsError: LocalizedError {
    case invalidURL
    case requestFailed
    case httpError(Int)
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid MotionBgs URL"
        case .requestFailed: return "Failed to reach motionbgs.com — check your network connection"
        case .httpError(let code): return "motionbgs.com returned HTTP \(code)"
        case .parsingFailed: return "Could not parse the wallpaper list"
        }
    }
}

final class MotionBgsService {
    static let baseURL = "https://motionbgs.com"

    /// Fetches and parses one listing page for a category.
    func fetchItems(category: MotionBgsCategory, page: Int = 1) async throws -> [MotionBgsItem] {
        guard let url = URL(string: Self.baseURL + category.path(page: page)) else {
            throw MotionBgsError.invalidURL
        }

        let (data, response) = try await URLSession.browseSource.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MotionBgsError.requestFailed
        }
        guard httpResponse.statusCode == 200 else {
            throw MotionBgsError.httpError(httpResponse.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw MotionBgsError.parsingFailed
        }
        return Self.parseItems(from: html)
    }

    /// Searches MotionBgs by free-text query. Confirmed live (2026-07-25): the site's own search
    /// form posts to `GET /search?q=`; results are the same card markup as category listing pages,
    /// so the existing parser works unchanged. Paginates via `&page=N`, not the `/N/` path style
    /// category listings use.
    func searchItems(query: String, page: Int = 1) async throws -> [MotionBgsItem] {
        var components = URLComponents(string: "\(Self.baseURL)/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components?.url else { throw MotionBgsError.invalidURL }

        let (data, response) = try await URLSession.browseSource.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MotionBgsError.requestFailed
        }
        guard httpResponse.statusCode == 200 else {
            throw MotionBgsError.httpError(httpResponse.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw MotionBgsError.parsingFailed
        }
        return Self.parseItems(from: html)
    }

    /// Parses wallpaper cards out of a MotionBgs listing page.
    ///
    /// Card markup looks like:
    /// `<a title="{Title} live wallpaper" href=/{slug}> <figure><picture>
    ///    <source srcset=/i/c/546x308/media/{id}/{filename}.webp type=image/webp> ...`
    static func parseItems(from html: String) -> [MotionBgsItem] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a title="([^"]+) live wallpaper" href=/([a-z0-9-]+)>.*?/i/c/546x308/media/(\d+)/([a-zA-Z0-9._-]+\.(?:jpg|png))\.webp"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)

        var seenIds = Set<Int>()
        var items: [MotionBgsItem] = []

        for match in matches {
            guard let titleRange = Range(match.range(at: 1), in: html),
                  let slugRange = Range(match.range(at: 2), in: html),
                  let idRange = Range(match.range(at: 3), in: html),
                  let filenameRange = Range(match.range(at: 4), in: html),
                  let id = Int(html[idRange])
            else { continue }

            guard !seenIds.contains(id) else { continue }
            seenIds.insert(id)

            let title = String(html[titleRange])
            let slug = String(html[slugRange])
            let filename = String(html[filenameRange])

            guard let thumbnailURL = URL(string: "\(Self.baseURL)/i/c/546x308/media/\(id)/\(filename).webp") else { continue }

            items.append(MotionBgsItem(id: id, slug: slug, title: title, thumbnailURL: thumbnailURL))
        }

        return items
    }

    /// Fetches an item's full tag list from its detail page's "subtags" block — confirmed live
    /// (2026-07-25): `<ul class="subtags mb-8"><li><a href=/tag:nature/> <picture>...</picture>
    /// <span>Nature</span> </a></li>...</ul>`. This is a superset of the breadcrumb trail (which
    /// only shows one primary hierarchical path, e.g. Nature > Water > Ocean) — a wallpaper tagged
    /// under both a subject (Nature/Ocean) and a style (Anime) only surfaces the style tag here,
    /// not in the breadcrumb, so the breadcrumb alone was under-tagging. Listing/search pages only
    /// carry a sitewide tag cloud, not per-item tags, so this needs the item's own page.
    func fetchTags(slug: String) async throws -> [String] {
        guard let url = URL(string: "\(Self.baseURL)/\(slug)") else { throw MotionBgsError.invalidURL }

        let (data, response) = try await URLSession.browseSource.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MotionBgsError.requestFailed
        }
        guard httpResponse.statusCode == 200 else {
            throw MotionBgsError.httpError(httpResponse.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw MotionBgsError.parsingFailed
        }
        return Self.parseSubtags(from: html)
    }

    /// Parses the tag labels out of the detail page's "subtags" list.
    static func parseSubtags(from html: String) -> [String] {
        guard let listStart = html.range(of: "class=\"subtags"),
              let ulStart = html.range(of: "<ul", options: .backwards, range: html.startIndex..<listStart.lowerBound),
              let ulEnd = html.range(of: "</ul>", range: listStart.upperBound..<html.endIndex)
        else { return [] }

        let listContent = String(html[ulStart.lowerBound..<ulEnd.lowerBound])
        guard let regex = try? NSRegularExpression(pattern: #"<span>([^<]+)</span>"#)
        else { return [] }

        let nsRange = NSRange(listContent.startIndex..<listContent.endIndex, in: listContent)
        return regex.matches(in: listContent, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: listContent) else { return nil }
            return String(listContent[range])
        }
    }

    /// Index of what's already in the local library, used to detect "you already have this"
    /// before re-downloading from MotionBgs.
    struct ExistingLibraryIndex {
        /// Source item IDs recorded via `sourceProvider`/`sourceId` — the precise match.
        let sourceIds: Set<Int>
        /// Lowercased titles of every wallpaper in the library — a fallback match for items
        /// downloaded before source-ID tracking existed, which have no `sourceId` to compare.
        let titles: Set<String>
    }

    /// Builds both matching signals from the already-in-memory library (`ContentViewModel.wallpapers`
    /// — every wallpaper's `project.json` is decoded once at refresh time and held in RAM), so the UI
    /// can show "Added" instead of "Download" for duplicates without re-downloading and wasting
    /// storage/bandwidth — including for wallpapers downloaded before this tracking existed. Used to
    /// re-scan `wallpapersDirectory` and re-decode every `project.json` from disk on every page load,
    /// category switch, and search — this is that same data, already parsed, for free.
    static func existingLibraryIndex(wallpapers: [WEWallpaper]) -> ExistingLibraryIndex {
        var sourceIds = Set<Int>()
        var titles = Set<String>()
        for wallpaper in wallpapers {
            let project = wallpaper.project
            titles.insert(project.title.lowercased())

            if project.sourceProvider == "motionbgs",
               let sourceId = project.sourceId,
               let id = Int(sourceId) {
                sourceIds.insert(id)
            }
        }
        return ExistingLibraryIndex(sourceIds: sourceIds, titles: titles)
    }

    /// Downloads the wallpaper video for the given item ("hd" = 1920x1080, "4k" = 3840x2160)
    /// to a temporary location and returns its local URL. Errors are translated back to
    /// `MotionBgsError` (rather than leaking `DirectURLImportError`) so the 4K→HD fallback logic in
    /// `MotionBgsViewModel.download` — which pattern-matches on `MotionBgsError.httpError` — keeps
    /// working unchanged.
    func downloadVideo(id: Int, quality: String, onProgress: @escaping (Double?) -> Void = { _ in }) async throws -> URL {
        guard let url = URL(string: "\(Self.baseURL)/dl/\(quality)/\(id)") else {
            throw MotionBgsError.invalidURL
        }
        do {
            return try await DirectURLImporter.download(from: url, onProgress: onProgress)
        } catch let error as DirectURLImportError {
            if case .badStatus(let code) = error {
                throw MotionBgsError.httpError(code)
            }
            throw MotionBgsError.requestFailed
        }
    }
}
