//
//  InboxClassifier.swift
//  Wallwright
//
//  Fast, cheap checks used by InboxLinksStore's classification step. Kept separate from its
//  persistence/routing concerns — this is pure, stateless logic, testable in isolation.
//
//  Deliberately NOT a hardcoded list of "sites that need yt-dlp" — yt-dlp itself already supports
//  well over a thousand sites and knows definitively whether it can handle a given URL, so
//  InboxLinksStore just asks it directly (see `classify(_:)` there) rather than this file trying
//  to maintain its own guess-list that would always be incomplete and could drift out of sync with
//  what yt-dlp actually supports.
//
//  `knownVideoOnlyHosts` below looks like exactly that guess-list, but it's answering a narrower
//  question: not "does yt-dlp support this site" (still yt-dlp's call, always), only "is a probe
//  even worth waiting on before saying yes." Confirmed live (2026-08-22): even bounded to a hard
//  15s timeout (see YtDlpService.fetchInfo), an up-front probe on every link reads as "stuck" for
//  the several real seconds a live network round-trip can genuinely take — for a domain whose
//  entire purpose is video, that wait buys nothing. Kept intentionally tiny and restricted to
//  platforms that structurally can't host anything else; anything even slightly mixed (Instagram,
//  Twitter/X, Reddit, Facebook all serve photos and video from the same URL shape) stays on the
//  real probe, since only yt-dlp can actually tell those apart.
//

import Foundation

enum InboxClassifier {
    private static let directExtensions: Set<String> = [
        "mp4", "mov", "m4v", "jpg", "jpeg", "png", "heic", "webp",
    ]

    private static let knownVideoOnlyHosts: Set<String> = [
        "youtube.com", "youtu.be", "vimeo.com", "tiktok.com", "twitch.tv",
    ]

    /// True if `url`'s own path extension is an obviously-direct media file — skips both a yt-dlp
    /// attempt and a network round-trip entirely for the common case of a link that's already
    /// unambiguous.
    static func isDirectByExtension(_ url: URL) -> Bool {
        directExtensions.contains(url.pathExtension.lowercased())
    }

    /// True for a domain on `knownVideoOnlyHosts` (subdomains included, e.g. `m.youtube.com` or
    /// `www.tiktok.com`) — lets `InboxLinksStore.classify` mark it `.indirect` immediately instead
    /// of waiting on a yt-dlp probe just to learn what's already certain. Title/thumbnail still get
    /// fetched, just deferred to `resolveIndirectLink` at Import time instead of up front.
    static func isKnownVideoOnlyHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return knownVideoOnlyHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// A HEAD request, not GET — only the `Content-Type` header is needed, not the body. Used as
    /// the last resort when a URL has no recognizable extension AND yt-dlp couldn't resolve it
    /// either (not one of its supported sites) — still worth checking whether it's a plain,
    /// directly-downloadable file before giving up on it.
    static func classifyByContentType(_ url: URL) async -> InboxLinkKind {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // `URLRequest` inherits `URLSession.shared`'s default 60s request timeout otherwise — same
        // class of bug as `YtDlpService.fetchInfo`'s missing timeout (see its doc comment): a
        // server that accepts the connection but never actually responds would hang this, the
        // fallback step of `resolveUnknownLink`, for up to a full minute on top of whatever the
        // yt-dlp probe before it already spent.
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        else {
            return .unknown
        }
        return (contentType.hasPrefix("video/") || contentType.hasPrefix("image/")) ? .direct : .unknown
    }
}
