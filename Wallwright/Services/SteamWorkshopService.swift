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

    /// A GUI-launched app's process environment often doesn't include Homebrew's bin directory on
    /// PATH the way an interactive Terminal session does, so the common install locations are
    /// tried directly first — same pattern as YtDlpService/VideoTranscoder.
    private static func resolveBinary(named name: String) -> String? {
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        guard which.terminationStatus == 0,
              let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }

    static var steamcmdPath: String? { resolveBinary(named: "steamcmd") }
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

        let title = extractMetaContent(property: "og:title", html: html)?
            .replacingOccurrences(of: "Steam Workshop::", with: "")
            ?? "Workshop Item \(itemId)"
        let imageURLString = extractMetaContent(property: "og:image", html: html)?
            .replacingOccurrences(of: "&amp;", with: "&")
        let fileSizeText = extractLabeledStat(label: "File Size", html: html)

        return SteamWorkshopPreview(
            title: title,
            previewImageURL: imageURLString.flatMap(URL.init(string:)),
            fileSizeText: fileSizeText
        )
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
        let labels = regexMatches(#"detailsStatLeft\">([^<]*)<"#, in: html)
        let values = regexMatches(#"detailsStatRight\">([^<]*)<"#, in: html)
        guard let index = labels.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == label }), index < values.count else {
            return nil
        }
        return values[index].trimmingCharacters(in: .whitespaces)
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
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
