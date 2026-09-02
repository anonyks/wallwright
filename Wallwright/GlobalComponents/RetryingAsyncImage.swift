//
//  RetryingAsyncImage.swift
//  Wallwright
//
//  Drop-in replacement for SwiftUI's `AsyncImage` that automatically retries a failed load a
//  couple of times — `AsyncImage` has no built-in retry (by design, per Apple's docs), so a single
//  dropped/timed-out request leaves that tile permanently stuck on the failure placeholder, even
//  though the same URL would very likely succeed on a second, less-contended attempt. This is
//  routine when a whole browse grid's worth of thumbnails (MotionBgs/MoeWalls/Wallper/Steam
//  Workshop) all start loading at once on a category switch — some individual requests fail under
//  that concurrent load, and previously just stayed broken forever with no way to recover short of
//  restarting the app. Confirmed live (2026-07-30): switching a category away then back left
//  several tiles stuck on the placeholder icon indefinitely.
//
//  Always uses the manual fetch path now, not SwiftUI's `AsyncImage` for the no-custom-headers
//  case — confirmed live (2026-08-09) via `vmmap` that plain `AsyncImage` decodes at the source
//  image's full native resolution with no downsampling hook available at all, and one source's
//  featured/hero image (7652x4073) was showing up as a ~119MB IOSurface for what's only ever
//  displayed as a browse-grid tile. `ThumbnailDownsampler` fixes the equivalent bug for local
//  library thumbnails; this is the same fix for remote ones.
//

import AppKit
import SwiftUI

struct RetryingAsyncImage<Content: View>: View {
    let url: URL?
    /// Extra HTTP headers for the request — needed for sources whose CDN enforces Referer-based
    /// hotlink protection (e.g. uhdpaper.com, confirmed live: its image CDN 301/302-redirects a
    /// bare request and only serves the real file with `Referer: https://www.uhdpaper.com/` set).
    /// Empty for every other source, which just means no extra headers get added below.
    var httpHeaders: [String: String] = [:]
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    /// Bumping this forces the load task to restart fresh (see `.task(id:)` below) — used the same
    /// way `AsyncImage` restarts internally on a URL change, just driven manually since this no
    /// longer wraps `AsyncImage` at all.
    @State private var retryToken = 0
    @State private var retryCount = 0
    @State private var phase: AsyncImagePhase = .empty

    private static var maxRetries: Int { 2 }
    private static var retryDelay: TimeInterval { 1.5 }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
            .id(retryToken)
    }

    private func load() async {
        guard let url else { return }
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                phase = .failure(URLError(.badServerResponse))
                scheduleRetryIfNeeded()
                return
            }
            // Downsampled at decode time, not `NSImage(data:)` — confirmed live (2026-08-09) a
            // source's hero image (7652x4073) was decoding to a ~119MB IOSurface for what's only
            // ever shown as a browse-grid tile. See `ThumbnailDownsampler`'s header for the
            // measured impact of the equivalent bug on local library thumbnails.
            //
            // Decoded off the main actor — `.task` on a SwiftUI View runs on the main actor by
            // default, and this synchronous ImageIO call was blocking it directly. Confirmed live
            // (2026-08-31): a whole browse grid's thumbnails "all start loading at once on a
            // category switch" (this file's own header comment), so switching tabs bunched many
            // main-thread decodes together — real, visible stutter, not a theoretical one.
            let decodeTask = Task.detached(priority: .userInitiated) {
                ThumbnailDownsampler.downsampledImage(from: data)
            }
            guard let nsImage = await decodeTask.value else {
                phase = .failure(URLError(.cannotDecodeContentData))
                scheduleRetryIfNeeded()
                return
            }
            phase = .success(Image(nsImage: nsImage))
        } catch {
            phase = .failure(error)
            scheduleRetryIfNeeded()
        }
    }

    private func scheduleRetryIfNeeded() {
        guard retryCount < Self.maxRetries else { return }
        retryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) {
            retryToken += 1
        }
    }
}
