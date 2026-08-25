//
//  MoeWallsService.swift
//  Wallwright
//
//  Fetches and imports live wallpapers from moewalls.com. Like MotionBgsService, there's no public
//  API — this parses server-rendered listing/detail HTML directly.
//
//  The site's own "Download Wallpaper" button runs through a deliberately obfuscated click handler
//  (a reversed-string-built URL, a popunder ad gate, a per-item encoded token) before ever reaching
//  a file — but none of that is actually required. Confirmed live (2026-07-29): the token sitting
//  in plain sight as the `#moe-download` element's `data-url` attribute, appended to
//  `https://go.moewalls.com/download.php?video=`, serves the real file directly over a bare GET —
//  no cookies, no referrer, no popup, no session. The whole click-handler dance is monetization
//  theater for regular visitors, not an actual gate on the file.
//

import Foundation

struct MoeWallsItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let detailURL: URL
    let thumbnailURL: URL
}

enum MoeWallsCategory: CaseIterable, Identifiable {
    case trending, abstract, animal, anime, fantasy, games, landscape, lifestyle, movies, others, pixelArt, sciFi, vehicle

    var id: Self { self }

    var displayName: String {
        switch self {
        case .trending: return "Trending"
        case .abstract: return "Abstract"
        case .animal: return "Animal"
        case .anime: return "Anime"
        case .fantasy: return "Fantasy"
        case .games: return "Games"
        case .landscape: return "Landscape"
        case .lifestyle: return "Lifestyle"
        case .movies: return "Movies"
        case .others: return "Others"
        case .pixelArt: return "Pixel Art"
        case .sciFi: return "Sci-fi"
        case .vehicle: return "Vehicle"
        }
    }

    /// Path relative to the site root for page 1 of this category.
    private var basePath: String {
        switch self {
        case .trending: return "/"
        case .abstract: return "/category/abstract/"
        case .animal: return "/category/animal/"
        case .anime: return "/category/anime/"
        case .fantasy: return "/category/fantasy/"
        case .games: return "/category/games/"
        case .landscape: return "/category/landscape/"
        case .lifestyle: return "/category/lifestyle/"
        case .movies: return "/category/movies/"
        case .others: return "/category/others/"
        case .pixelArt: return "/category/pixel-art/"
        case .sciFi: return "/category/sci-fi/"
        case .vehicle: return "/category/vehicle/"
        }
    }

    /// Standard WordPress pagination: `{basePath}page/{n}/`; page 1 has no page segment.
    func path(page: Int) -> String {
        page <= 1 ? basePath : basePath + "page/\(page)/"
    }
}

enum MoeWallsError: LocalizedError {
    case invalidURL
    case requestFailed
    case httpError(Int)
    case parsingFailed
    case downloadTokenNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid MoeWalls URL"
        case .requestFailed: return "Failed to reach moewalls.com — check your network connection"
        case .httpError(let code): return "moewalls.com returned HTTP \(code)"
        case .parsingFailed: return "Could not parse the wallpaper list"
        case .downloadTokenNotFound: return "Couldn't find a download link on this wallpaper's page"
        }
    }
}

final class MoeWallsService {
    static let baseURL = "https://moewalls.com"

    private func fetchHTML(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.browseSource.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { throw MoeWallsError.requestFailed }
        guard httpResponse.statusCode == 200 else { throw MoeWallsError.httpError(httpResponse.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw MoeWallsError.parsingFailed }
        return html
    }

    /// Fetches and parses one listing page for a category.
    func fetchItems(category: MoeWallsCategory, page: Int = 1) async throws -> [MoeWallsItem] {
        guard let url = URL(string: Self.baseURL + category.path(page: page)) else { throw MoeWallsError.invalidURL }
        return Self.parseItems(from: try await fetchHTML(url))
    }

    /// Searches MoeWalls by free-text query — standard WordPress `GET /?s=` search, same card
    /// markup as category listing pages. Confirmed live (2026-07-29).
    func searchItems(query: String, page: Int = 1) async throws -> [MoeWallsItem] {
        var components = URLComponents(string: page <= 1 ? "\(Self.baseURL)/" : "\(Self.baseURL)/page/\(page)/")
        components?.queryItems = [URLQueryItem(name: "s", value: query)]
        guard let url = components?.url else { throw MoeWallsError.invalidURL }
        return Self.parseItems(from: try await fetchHTML(url))
    }

    /// Parses wallpaper cards out of a MoeWalls listing page.
    ///
    /// Card markup looks like:
    /// `<article class="... post-{id} ... category-{slug} ...">
    ///    <div class="entry-featured-media "><a title="{Title}" class="g1-frame" href="{detailURL}">
    ///      <div class="g1-frame-inner"><img ... src="{thumbnailURL}" ...`
    static func parseItems(from html: String) -> [MoeWallsItem] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<article class="[^"]*post-(\d+)[^"]*">.*?<a title="([^"]+)" class="g1-frame" href="(https://moewalls\.com/[^"]+)">.*?src="(https://moewalls\.com/wp-content/uploads/[^"]+\.(?:jpg|png))""#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)

        var seenIds = Set<Int>()
        var items: [MoeWallsItem] = []

        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let detailRange = Range(match.range(at: 3), in: html),
                  let thumbRange = Range(match.range(at: 4), in: html),
                  let id = Int(html[idRange]),
                  let detailURL = URL(string: String(html[detailRange])),
                  let thumbnailURL = URL(string: String(html[thumbRange]))
            else { continue }

            guard !seenIds.contains(id) else { continue }
            seenIds.insert(id)

            items.append(MoeWallsItem(id: id, title: String(html[titleRange]), detailURL: detailURL, thumbnailURL: thumbnailURL))
        }

        return items
    }

    /// Parses an item's own tags off its detail page — matches only `rel="tag"` anchors, which is
    /// what distinguishes this item's real tags from the unrelated sitewide "popular tags" cloud
    /// every detail page also renders (that cloud's links carry a `tag-cloud-link` class instead).
    static func parseTags(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"href="https://moewalls\.com/tag/[^"]+/" rel="tag">([^<]+)"#)
        else { return [] }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
    }

    /// Extracts the `#moe-download` element's `data-url` token from a detail page.
    static func parseDownloadToken(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"id="moe-download"[^>]*?data-url="([^"]+)""#)
        else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: nsRange), let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    /// Fetches an item's detail page and resolves its real, direct download URL — see this file's
    /// header comment for why this bypasses the site's own download button entirely.
    func resolveDownload(for item: MoeWallsItem) async throws -> (url: URL, tags: [String]) {
        let html = try await fetchHTML(item.detailURL)
        guard let token = Self.parseDownloadToken(from: html) else { throw MoeWallsError.downloadTokenNotFound }
        guard let downloadURL = URL(string: "https://go.moewalls.com/download.php?video=\(token)") else {
            throw MoeWallsError.downloadTokenNotFound
        }
        return (downloadURL, Self.parseTags(from: html))
    }

    /// Downloads the wallpaper video for the given item to a temporary location and returns its
    /// local URL. Resolves the real file URL first (see `resolveDownload`), then streams it via
    /// `DirectURLImporter`, which also reports real progress.
    func downloadVideo(for item: MoeWallsItem, onProgress: @escaping (Double?) -> Void = { _ in }) async throws -> (url: URL, tags: [String]) {
        let (downloadURL, tags) = try await resolveDownload(for: item)
        let destination = try await DirectURLImporter.download(from: downloadURL, onProgress: onProgress)
        return (destination, tags)
    }

    /// Index of what's already in the local library, used to detect "you already have this" before
    /// re-downloading from MoeWalls — same pattern as `MotionBgsService.existingLibraryIndex()`.
    struct ExistingLibraryIndex {
        let sourceIds: Set<Int>
        let titles: Set<String>
    }

    static func existingLibraryIndex() -> ExistingLibraryIndex {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fm.wallpapersDirectory, includingPropertiesForKeys: nil) else {
            return ExistingLibraryIndex(sourceIds: [], titles: [])
        }
        var sourceIds = Set<Int>()
        var titles = Set<String>()
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.appending(path: "project.json")),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data)
            else { continue }

            titles.insert(project.title.lowercased())

            if project.sourceProvider == "moewalls", let sourceId = project.sourceId, let id = Int(sourceId) {
                sourceIds.insert(id)
            }
        }
        return ExistingLibraryIndex(sourceIds: sourceIds, titles: titles)
    }
}
