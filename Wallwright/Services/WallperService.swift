//
//  WallperService.swift
//  Wallwright
//
//  Fetches and imports live wallpapers from wallper.app.
//
//  wallper.app's own gallery (wallper.app/wallpapers) is a Next.js app that fetches its listings
//  via React Server Components — a framework-internal streaming payload, not plain HTML or a
//  public JSON API, so scraping it directly would be fragile. Its `sitemap.xml`, however, is a
//  standard Google video sitemap (a stable, documented format meant for public consumption) that
//  already carries everything needed: title, thumbnail, category, and — unlike MotionBgs/MoeWalls,
//  where the real download link has to be resolved separately — the direct CDN video URL is right
//  there in `<video:content_loc>`. Confirmed live (2026-07-29): ~2,640 entries, one file, no
//  pagination needed since it's fetched and parsed once, then filtered/searched entirely in memory.
//

import Foundation

struct WallperItem: Identifiable, Hashable {
    let id: String // the wallpaper's UUID, parsed from its page URL
    let title: String
    let category: String
    let thumbnailURL: URL
    let videoURL: URL
    let pageURL: URL
}

enum WallperCategory: String, CaseIterable, Identifiable {
    case all, animals, anime, cars, games, graphics, minimalist, movies, nature, other, people, pixelart, scifi, space, winter

    var id: Self { self }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .animals: return "Animals"
        case .anime: return "Anime"
        case .cars: return "Cars"
        case .games: return "Games"
        case .graphics: return "Graphics"
        case .minimalist: return "Minimalist"
        case .movies: return "Movies"
        case .nature: return "Nature"
        case .other: return "Other"
        case .people: return "People"
        case .pixelart: return "PixelArt"
        case .scifi: return "SciFi"
        case .space: return "Space"
        case .winter: return "Winter"
        }
    }

    /// The `/wallpaper/{slug}/...` path segment this category's entries use in the sitemap.
    var pathSlug: String? { self == .all ? nil : rawValue }
}

enum WallperError: LocalizedError {
    case requestFailed
    case httpError(Int)
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Failed to reach wallper.app — check your network connection"
        case .httpError(let code): return "wallper.app returned HTTP \(code)"
        case .parsingFailed: return "Could not parse wallper.app's wallpaper index"
        }
    }
}

final class WallperService {
    static let baseURL = "https://www.wallper.app"

    /// Fetches and parses the full sitemap — the whole catalog in one request. Callers are
    /// expected to cache this (see `WallperViewModel.allItems`) rather than re-fetch per
    /// category/search, since filtering afterward is free.
    func fetchIndex() async throws -> [WallperItem] {
        guard let url = URL(string: "\(Self.baseURL)/sitemap.xml") else { throw WallperError.requestFailed }
        let (data, response) = try await URLSession.browseSource.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { throw WallperError.requestFailed }
        guard httpResponse.statusCode == 200 else { throw WallperError.httpError(httpResponse.statusCode) }
        guard let xml = String(data: data, encoding: .utf8) else { throw WallperError.parsingFailed }
        return Self.parseSitemap(xml)
    }

    /// Parses each `<url>...</url>` block that's actually a wallpaper entry (has a `<video:video>`
    /// child) out of the sitemap. Regex over the raw XML rather than a full XML parser — the
    /// structure here is simple, flat, and doesn't need one.
    static func parseSitemap(_ xml: String) -> [WallperItem] {
        guard let blockRegex = try? NSRegularExpression(pattern: "<url>(.*?)</url>", options: [.dotMatchesLineSeparators])
        else { return [] }

        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let blocks = blockRegex.matches(in: xml, range: nsRange).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[range])
        }

        var items: [WallperItem] = []
        for block in blocks {
            guard block.contains("<video:video>"),
                  let pageURLString = firstMatch(#"<loc>([^<]+)</loc>"#, in: block),
                  let pageURL = URL(string: pageURLString),
                  let id = extractID(from: pageURL),
                  let rawTitle = firstMatch(#"<video:title>([^<]+)</video:title>"#, in: block),
                  let thumbString = firstMatch(#"<video:thumbnail_loc>([^<]+)</video:thumbnail_loc>"#, in: block),
                  let thumbnailURL = URL(string: thumbString),
                  let videoString = firstMatch(#"<video:content_loc>([^<]+)</video:content_loc>"#, in: block),
                  let videoURL = URL(string: videoString)
            else { continue }

            // Page path looks like /wallpaper/{category}/{slug}-{id} — category is the segment
            // right after "wallpaper".
            let pathComponents = pageURL.pathComponents
            let category = pathComponents.firstIndex(of: "wallpaper").map { idx -> String in
                let next = idx + 1
                return next < pathComponents.count ? pathComponents[next] : "other"
            } ?? "other"

            // Titles are published as "{Name} — Live Wallpaper for Mac" — strip the boilerplate
            // suffix since the grid already shows this is a wallpaper.
            let title = rawTitle.replacingOccurrences(of: #" — Live Wallpaper for Mac$"#, with: "", options: .regularExpression)

            items.append(WallperItem(id: id, title: title, category: category, thumbnailURL: thumbnailURL, videoURL: videoURL, pageURL: pageURL))
        }
        return items
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }

    private static let uuidSuffixPattern = #"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$"#

    private static func extractID(from pageURL: URL) -> String? {
        firstMatch(uuidSuffixPattern, in: pageURL.lastPathComponent)
    }

    /// Downloads the wallpaper video for the given item to a temporary location — reuses the same
    /// generic downloader Direct URL Import uses, since `item.videoURL` is already the real file.
    func downloadVideo(for item: WallperItem, onProgress: @escaping (Double?) -> Void) async throws -> URL {
        try await DirectURLImporter.download(from: item.videoURL, onProgress: onProgress)
    }

    /// Index of what's already in the local library, used to detect "you already have this" before
    /// re-downloading — same pattern as `MotionBgsService.existingLibraryIndex()`.
    struct ExistingLibraryIndex {
        let sourceIds: Set<String>
        let titles: Set<String>
    }

    static func existingLibraryIndex() -> ExistingLibraryIndex {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fm.wallpapersDirectory, includingPropertiesForKeys: nil) else {
            return ExistingLibraryIndex(sourceIds: [], titles: [])
        }
        var sourceIds = Set<String>()
        var titles = Set<String>()
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.appending(path: "project.json")),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data)
            else { continue }

            titles.insert(project.title.lowercased())

            if project.sourceProvider == "wallper", let sourceId = project.sourceId {
                sourceIds.insert(sourceId)
            }
        }
        return ExistingLibraryIndex(sourceIds: sourceIds, titles: titles)
    }
}
