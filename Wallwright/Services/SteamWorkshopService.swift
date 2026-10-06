//
//  SteamWorkshopService.swift
//  Wallwright
//
//  Downloads a Wallpaper Engine Workshop item via a system-installed `steamcmd` — shelled out to,
//  not bundled. Workshop content for a paid app is gated behind actually owning that app on the
//  logged-in account, so this always forces the Windows platform (`@sSteamCmdForcePlatformType
//  windows`, since Wallpaper Engine has no macOS build and its Workshop depot only exists under
//  Windows) and logs in with a specific username rather than anonymously.
//
//  Deliberately does NOT ever prompt for or handle a password itself: the one-time login (which
//  needs the real password and, on first use, a Steam Guard code) happens once outside the app, in
//  Terminal — `steamcmd` then caches that login locally, and every call this file makes afterward
//  reuses the cache via `+login <username>` alone. `GlobalSettings.steamUsername` just remembers
//  which cached account to reuse; it is never a password and is safe to store in plain settings.

import Foundation

struct SteamWorkshopResult {
    let contentDirectory: URL
    let project: WEProject
}

/// Scraped from the item's public Workshop page — no login needed, unlike the actual download, so
/// this is shown before committing to the (slower, ownership-gated) `steamcmd` step.
struct SteamWorkshopPreview {
    let title: String
    let previewImageURL: URL?
    let fileSizeText: String?
    /// The Workshop page's own "Type:" tag (e.g. "Video", "Scene", "Web", "Application"). Lets the
    /// import sheet warn before committing to the full steamcmd download, rather than only finding
    /// out it's an unsupported type (see `WEProject.supportedTypes`) after paying that cost.
    /// Confirmed live (2026-10-04): a 247MB download that only then rejected at import, when the
    /// page itself already said "Type: Scene" for free.
    let workshopType: String?

    /// Whether this is a Scene wallpaper, which Wallwright can import as a static image via SceneFallback.
    var isScene: Bool {
        guard let workshopType else { return false }
        return workshopType.caseInsensitiveCompare("Scene") == .orderedSame
    }

    /// True for types Wallwright cannot render or import even via fallback (e.g. "Web", "Application").
    var isUnsupportedType: Bool {
        guard let workshopType else { return false }
        return workshopType.caseInsensitiveCompare("Video") != .orderedSame
            && workshopType.caseInsensitiveCompare("Scene") != .orderedSame
    }
}

/// One row from a Workshop search/browse result page — just enough to show a thumbnail grid and
/// let the user pick one, which then flows into the exact same `fetchPreview(itemId:)` the
/// paste-a-link path already uses (type validation, file size, the full preview). Search never
/// pre-filters by type itself; that check already happens for free once a result is selected.
struct SteamWorkshopSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let thumbnailURL: URL?
}

/// Steam's own `requiredtags[]` filter values this app offers in the search UI — see
/// `SteamWorkshopService.searchItems`'s own doc comment for how/why this list is scoped to only
/// what's confirmed to actually work, not Workshop's full (unpublished) tag taxonomy.
/// Steam's real Workshop filter taxonomy for Wallpaper Engine, read directly off
/// steamcommunity.com/workshop/browse's own filter sidebar (2026-10-05) rather than guessed —
/// an earlier guessed list missed several real genres (CGI, Cyberpunk, Medieval, MMD, Relaxing,
/// Vehicle, ...) and included at least one that isn't a real Genre value there at all ("Space" —
/// it happened to still return results, but as a loose text match, not a real tag). Every list
/// below is copied verbatim from that sidebar's own section headings and values; nothing here is
/// invented or assumed.
enum WorkshopTag {
    /// Mirrors this app's own Video-Source/Image-Source split: a "Video" result plays as a real
    /// video wallpaper; a "Scene" result is converted to a static image via SceneFallback and
    /// behaves exactly like any other image-source wallpaper from here on — picking one in search
    /// is the Steam equivalent of picking a source from the Image Sources popover.
    static let typeTags = ["Video", "Scene"]

    /// Applied whenever `GlobalSettings.steamWorkshopSafeMode` is on (the default) — not a user-
    /// facing chip itself. The sidebar's own "Category" facet also offers "Preset" and "Asset",
    /// neither of which is a real importable wallpaper (a preset is saved settings for an
    /// existing wallpaper; an asset is raw material for the editor, not a finished scene), so
    /// Safe Mode scopes every search to real wallpapers only, the same way every other browse
    /// source in this app only ever lists its own kind of content. Turning Safe Mode off stops
    /// sending this, the same way any other optional filter here would be left off.
    static let requiredCategoryTag = "Wallpaper"

    /// Applied whenever `GlobalSettings.steamWorkshopSafeMode` is on (the default) — not a user-
    /// facing chip itself. The sidebar's own "Age Rating" facet also offers "Questionable" and
    /// "Mature"; Safe Mode scopes every search to "Everyone" only. Turning Safe Mode off stops
    /// sending this, the same way any other optional filter here would be left off.
    static let requiredAgeRatingTag = "Everyone"

    /// The sidebar's "Genre" facet, verbatim — every value it actually lists, alphabetical
    /// ordering preserved as shown there. "Unspecified" is real (untagged items) but surfaced
    /// last since including it is a narrower, less typical choice than every named genre above it.
    static let genreTags = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game", "Girls",
        "Guys", "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature", "Pixel art", "Relaxing",
        "Retro", "Sci-Fi", "Sports", "Technology", "Television", "Vehicle", "Unspecified",
    ]

    /// The sidebar's "Miscellaneous" facet, verbatim — technical/interactivity properties rather
    /// than visual genre (e.g. "Audio responsive" = reacts to system audio, "Puppet Warp" = has
    /// bone-rigged animated parts), same ordering shown there.
    static let miscellaneousTags = [
        "Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR",
        "Media Integration", "User Shortcut", "Video Texture", "Asset Pack",
    ]
}

enum SteamWorkshopError: LocalizedError {
    case notInstalled
    case invalidURL
    case notLoggedIn
    case notOwned
    case timedOut(String)
    case downloadFailed(String)
    case missingProjectFile

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "steamcmd isn't installed. Install it with: brew install steamcmd"
        case .invalidURL:
            return "That doesn't look like a Steam Workshop URL or item ID"
        case .notLoggedIn:
            return "steamcmd isn't logged in as this user yet (or the cached login expired). Run the one-time Terminal login again."
        case .notOwned:
            return "This Steam account doesn't own Wallpaper Engine — Workshop content is locked to accounts that own the app."
        case .timedOut(let lastOutput):
            let tail = lastOutput.isEmpty ? "" : " Last output before giving up:\n\(lastOutput)"
            return "steamcmd didn't respond in time.\(tail)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .missingProjectFile:
            return "That download doesn't contain a valid project.json — it may not be a Wallpaper Engine wallpaper"
        }
    }
}

enum SteamWorkshopService {
    static let wallpaperEngineAppId = "431960"

    // Compiled once, not on every call — `searchItems` alone can run per keystroke of a chip tap
    // or "load more" scroll, and `NSRegularExpression`'s pattern compile is real, avoidable work
    // against a fixed, never-varying literal pattern.
    private static let searchResultRegex = try? NSRegularExpression(
        pattern: #"href="https://steamcommunity\.com/sharedfiles/filedetails/\?id=(\d+)"[^>]*><img src="([^"]+)"[^>]*alt="([^"]*)""#
    )
    private static let workshopTypeTagRegex = try? NSRegularExpression(pattern: #"workshopTagsTitle">Type:&nbsp;</span><a[^>]*>([^<]+)</a>"#)
    private static let detailsStatLeftRegex = try? NSRegularExpression(pattern: #"detailsStatLeft\">([^<]*)<"#)
    private static let detailsStatRightRegex = try? NSRegularExpression(pattern: #"detailsStatRight\">([^<]*)<"#)

    static var steamcmdPath: String? { ProcessRunner.resolveBinary(named: "steamcmd") }
    static var isAvailable: Bool { steamcmdPath != nil }

    /// Accepts a full Workshop URL (`.../filedetails/?id=123...`) or a bare numeric item ID.
    static func extractItemId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber) { return trimmed }
        guard let idRange = trimmed.range(of: "id=") else { return nil }
        let digits = trimmed[idRange.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// Fetches title/preview-image/file-size off the item's public Workshop page — plain HTTP, no
    /// steamcmd or login involved, so this works even before the one-time setup is done.
    static func fetchPreview(itemId: String) async throws -> SteamWorkshopPreview {
        guard let pageURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(itemId)") else {
            throw SteamWorkshopError.invalidURL
        }
        let (data, response) = try await URLSession.browseSource.data(from: pageURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw SteamWorkshopError.downloadFailed("Couldn't load that Workshop page")
        }

        // `og:title` comes back with HTML entities intact (`&quot;`, `&#39;`, `&amp;`, ...) — Steam
        // doesn't pre-decode its own meta tags. This is only the preview's title (shown before the
        // user commits to downloading); the item actually downloads with its own `project.json`
        // title straight from Wallpaper Engine's package metadata, which never passes through this
        // scraped HTML at all.
        let title = (extractMetaContent(property: "og:title", html: html)?
            .replacingOccurrences(of: "Steam Workshop::", with: "")
            ?? "Workshop Item \(itemId)").decodingHTMLEntities()
        let imageURLString = extractMetaContent(property: "og:image", html: html)?
            .replacingOccurrences(of: "&amp;", with: "&")
        let fileSizeText = extractLabeledStat(label: "File Size", html: html)
        let workshopType = extractWorkshopTypeTag(html: html)

        return SteamWorkshopPreview(
            title: title,
            previewImageURL: imageURLString.flatMap(URL.init(string:)),
            fileSizeText: fileSizeText,
            workshopType: workshopType
        )
    }

    /// Scrapes the public Workshop *browse* page (`workshop/browse/?searchtext=...`) — a different,
    /// modern React-rendered template than `fetchPreview`'s single-item page, with hashed/
    /// build-specific CSS class names that aren't stable to match against. The one thing that *is*
    /// stable: each result renders as an `<a href=".../filedetails/?id=N">` immediately wrapping an
    /// `<img src="thumbnail" alt="title">` — confirmed live (2026-10-05) against real search
    /// results. `page` is Steam's own 1-based `p=` query param (confirmed live to return a distinct
    /// result set per page, i.e. real pagination, not a no-op).
    ///
    /// No login, no steamcmd — same anonymous plain-HTTP approach as `fetchPreview`. Mature-rated
    /// items are gated behind a content-preference cookie real browsers carry; an anonymous
    /// request like this one doesn't send it, so Steam's own browse page already excludes most
    /// mature-flagged results before this ever sees the HTML — not something this app filters
    /// itself, since there's no reliable signal for it in this page's markup to filter *with*.
    /// `requiredTags`: Steam's own `requiredtags[]` browse-page filter — confirmed live (2026-10-05)
    /// that multiple values AND together (narrow, not widen) the same way checking several boxes
    /// in Steam's own sidebar filter would. `WorkshopTag.typeTags`/`.topicTags` below are the
    /// subset this app actually offers, each individually confirmed live to return real, distinct
    /// results — Steam's tag taxonomy isn't published anywhere, and a handful of plausible-looking
    /// guesses (e.g. "Cars", "Movies", "4K") came back empty, so this list is deliberately only
    /// what was actually verified, not every tag Workshop might really support.
    /// Empty `query` falls back to Steam's own "Trending" sort with no `searchtext` at all —
    /// confirmed live (2026-10-05) that this still returns 60 real, current results, same as the
    /// browse tabs for every other source here default to "trending"/"newest" on first open rather
    /// than requiring the user to type something before seeing anything.
    /// `excludedTags`: Steam's own `excludedtags[]` — confirmed live (2026-10-05) to genuinely
    /// remove matching items (zero ID overlap between a tag's own `requiredtags[]` result set and
    /// the same search's `excludedtags[]` result set), not just a no-op query param.
    static func searchItems(query: String, page: Int = 1, requiredTags: [String] = [], excludedTags: [String] = []) async throws -> [SteamWorkshopSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var queryItems = [
            URLQueryItem(name: "appid", value: wallpaperEngineAppId),
            URLQueryItem(name: "p", value: String(max(1, page))),
        ]
        if trimmed.isEmpty {
            // "Most Popular (Six Months)" — same default Steam's own Workshop browse page used
            // before any filter was touched. "Most Popular" is `browsesort=trend`; the time frame
            // is a separate param (`days=180` for Six Months) — confirmed live (2026-10-06) by
            // actually selecting both in Steam's own sort dropdown and reading the resulting URL,
            // not guessed. Mandatory, matching how every other browse source's own default sort
            // isn't user-configurable either (MotionBgs opens on "Trending", not a saved choice).
            queryItems.append(URLQueryItem(name: "browsesort", value: "trend"))
            queryItems.append(URLQueryItem(name: "days", value: "180"))
        } else {
            queryItems.append(URLQueryItem(name: "searchtext", value: trimmed))
            queryItems.append(URLQueryItem(name: "browsesort", value: "textsearch"))
        }
        queryItems += requiredTags.map { URLQueryItem(name: "requiredtags[]", value: $0) }
        queryItems += excludedTags.map { URLQueryItem(name: "excludedtags[]", value: $0) }
        components.queryItems = queryItems
        guard let pageURL = components.url else { throw SteamWorkshopError.invalidURL }

        let (data, response) = try await URLSession.browseSource.data(from: pageURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw SteamWorkshopError.downloadFailed("Couldn't load Workshop search results")
        }

        guard let regex = searchResultRegex else { return [] }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        var results: [SteamWorkshopSearchResult] = []
        var seenIds = Set<String>()
        for match in matches where match.numberOfRanges == 4 {
            let id = nsHTML.substring(with: match.range(at: 1))
            guard !seenIds.contains(id) else { continue }
            seenIds.insert(id)
            let rawThumbnailURL = URL(string: nsHTML.substring(with: match.range(at: 2)).replacingOccurrences(of: "&amp;", with: "&"))
            let title = nsHTML.substring(with: match.range(at: 3)).decodingHTMLEntities()
            results.append(SteamWorkshopSearchResult(id: id, title: title, thumbnailURL: nonLetterboxedThumbnail(rawThumbnailURL)))
        }
        return results
    }

    /// The browse page's own `<img>` thumbnails force `letterbox=true` at a fixed 322×322 square —
    /// every non-square source image gets padded with visible black bars to fill that square,
    /// confirmed live (2026-10-05) by comparing both against a handful of real results. The exact
    /// same underlying image, at the exact same CDN path, renders properly fit-not-padded when
    /// asked for with `letterbox=false` instead — confirmed by comparing to `fetchPreview`'s own
    /// `og:image` URL for the same items, which already uses this recipe (that page was never
    /// letterboxed to begin with). Rewriting the query here keeps every thumbnail in this app —
    /// search results and the single-item preview alike — visually consistent, with one fewer
    /// network request than re-fetching each result's own detail page just for a better image.
    private static func nonLetterboxedThumbnail(_ url: URL?) -> URL? {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return url }
        components.queryItems = [
            URLQueryItem(name: "imw", value: "512"),
            URLQueryItem(name: "ima", value: "fit"),
            URLQueryItem(name: "impolicy", value: "Letterbox"),
            URLQueryItem(name: "imcolor", value: "#000000"),
            URLQueryItem(name: "letterbox", value: "false"),
        ]
        return components.url ?? url
    }

    /// The page's "Type:" tag renders as `<span class="workshopTagsTitle">Type:&nbsp;</span>`
    /// immediately followed by a single `<a>` whose text is the actual value (e.g. "Scene").
    /// Confirmed live (2026-10-04) against a real Scene-type item's page.
    private static func extractWorkshopTypeTag(html: String) -> String? {
        guard let regex = workshopTypeTagRegex,
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    private static func extractMetaContent(property: String, html: String) -> String? {
        guard let propRange = html.range(of: "property=\"\(property)\" content=\"") else { return nil }
        let afterProp = html[propRange.upperBound...]
        guard let endQuote = afterProp.range(of: "\"") else { return nil }
        return String(afterProp[..<endQuote.lowerBound])
    }

    /// Steam renders each stat as two parallel lists — `detailsStatLeft` labels ("File Size",
    /// "Posted", ...) and `detailsStatRight` values, in matching order — so the label's index
    /// gives the value's index rather than needing to know each stat's exact position up front.
    private static func extractLabeledStat(label: String, html: String) -> String? {
        guard let labelRegex = detailsStatLeftRegex, let valueRegex = detailsStatRightRegex else { return nil }
        let labels = regexMatches(labelRegex, in: html)
        let values = regexMatches(valueRegex, in: html)
        guard let index = labels.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == label }), index < values.count else {
            return nil
        }
        return values[index].trimmingCharacters(in: .whitespaces)
    }

    private static func regexMatches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
    }

    /// Downloads `itemId` and returns its content folder plus the already-parsed `project.json` —
    /// callers hand that straight to `PackageImporter` for the title/tags review step. `onProgress`
    /// is called with each non-empty line steamcmd prints, as it prints it — actual wall-clock time
    /// varies wildly run to run (confirmed live: 7s one attempt, 2m11s the next, same account/item —
    /// Steam's own connection speed, not anything controllable here), so surfacing real status
    /// instead of a static spinner is the only thing that actually helps a slow run not look stuck.
    static func download(itemId: String, username: String, onProgress: @escaping (String) -> Void = { _ in }) async throws -> SteamWorkshopResult {
        guard let steamcmd = steamcmdPath else { throw SteamWorkshopError.notInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: steamcmd)
        process.arguments = [
            "+@sSteamCmdForcePlatformType", "windows",
            "+login", username,
            "+workshop_download_item", wallpaperEngineAppId, itemId,
            "+quit",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drained continuously, not read after exit — same pipe-buffer-deadlock hazard already
        // hit (and fixed) in YtDlpService: steamcmd's own update-check chatter can exceed 64KB.
        //
        // `syncQueue` serializes every read/write of `stdoutData`/`stderrData`/`didResume` below —
        // `readabilityHandler` (fires on its own background queue), `terminationHandler` (fires on
        // a queue Foundation owns), and the `asyncAfter` timeout below all run concurrently with
        // each other with no inherent ordering. Without this, `terminationHandler` and the timeout
        // could both pass their `!didResume` check before either set it, and both call
        // `continuation.resume()` — a checked continuation resumed twice is a hard runtime crash,
        // not just a data race; confirmed via Swift 6 strict-concurrency diagnostics on this exact
        // code (`mutation of captured var ... in concurrently-executing code`), which correctly
        // flags this as a real, reachable bug, not a false positive.
        let syncQueue = DispatchQueue(label: "SteamWorkshopService.subprocess-sync")
        var stdoutData = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            syncQueue.sync { stdoutData.append(chunk) }
            if let text = String(data: chunk, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    DispatchQueue.main.async { onProgress(trimmed) }
                }
            }
        }
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            syncQueue.sync { stderrData.append(chunk) }
        }

        try process.run()

        // If the cached login is missing/stale, steamcmd sits at an interactive password prompt
        // forever (this call feeds no stdin) — without a timeout that reads as the UI hanging.
        // Confirmed live (2026-07-26): a real successful download — cached login, no prompt
        // involved — took 2m11s end to end (steamcmd's own self-update check dominates this, not
        // the actual file transfer), so anything shorter than a few minutes here throws out
        // perfectly good downloads as false "timeouts."
        let timeoutTail: String? = await withCheckedContinuation { continuation in
            var didResume = false
            process.terminationHandler = { _ in
                syncQueue.sync {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: nil)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                syncQueue.sync {
                    guard !didResume else { return }
                    didResume = true
                    let tail = String(data: stdoutData, encoding: .utf8)?
                        .split(separator: "\n").suffix(6).joined(separator: "\n") ?? ""
                    if process.isRunning { process.terminate() }
                    continuation.resume(returning: tail)
                }
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // `terminationHandler` firing doesn't guarantee `readabilityHandler` has already delivered
        // every byte steamcmd wrote before exiting — process-exit detection and pipe-buffer
        // delivery are two independent mechanisms with no ordering guarantee between them, and
        // steamcmd prints its "Downloaded item ... to ..." marker on the very last line right
        // before exiting. Nilling the handler above only stops FUTURE callbacks; it doesn't discard
        // whatever's still sitting unread in the kernel pipe buffer — draining it explicitly here
        // (blocking, but the process has already exited so this returns immediately) guarantees the
        // marker line is captured even if it arrived in that last, easy-to-miss window.
        syncQueue.sync {
            stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        }

        if let timeoutTail { throw SteamWorkshopError.timedOut(timeoutTail) }

        let stdout = syncQueue.sync { String(data: stdoutData, encoding: .utf8) ?? "" }

        if stdout.contains("Missing decryption key") {
            throw SteamWorkshopError.notOwned
        }
        if stdout.contains("Invalid Password") || stdout.contains("Login Failure")
            || stdout.contains("Cached credentials not found") || stdout.contains("Two-factor") {
            throw SteamWorkshopError.notLoggedIn
        }

        // Scanning steamcmd's own "Downloaded item <id> to "<path>"" line rather than assuming a
        // path — simpler and doesn't depend on Steam's on-disk layout, which isn't documented API.
        guard let marker = stdout.range(of: "Downloaded item \(itemId) to \""),
              let closingQuote = stdout[marker.upperBound...].range(of: "\"")
        else {
            let message = syncQueue.sync { String(data: stderrData, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = stdout.split(separator: "\n").suffix(3).joined(separator: " ")
            throw SteamWorkshopError.downloadFailed(message?.isEmpty == false ? message! : (tail.isEmpty ? "unknown error" : tail))
        }
        let path = String(stdout[marker.upperBound..<closingQuote.lowerBound])
        let contentDirectory = URL(fileURLWithPath: path)

        guard let projectData = try? Data(contentsOf: contentDirectory.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: projectData)
        else {
            throw SteamWorkshopError.missingProjectFile
        }

        return SteamWorkshopResult(contentDirectory: contentDirectory, project: project)
    }
}
