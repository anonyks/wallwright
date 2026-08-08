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

import AppKit
import SwiftUI

struct RetryingAsyncImage<Content: View>: View {
    let url: URL?
    /// Extra HTTP headers for the request — needed for sources whose CDN enforces Referer-based
    /// hotlink protection (e.g. uhdpaper.com, confirmed live: its image CDN 301/302-redirects a
    /// bare request and only serves the real file with `Referer: https://www.uhdpaper.com/` set).
    /// Empty by default, in which case this stays on plain `AsyncImage` unchanged — SwiftUI's
    /// `AsyncImage` has no `URLRequest`/header-based initializer at all, so headers require a
    /// separate manual-fetch path, only taken when actually needed.
    var httpHeaders: [String: String] = [:]
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    /// Bumping this forces SwiftUI to treat the wrapped image view as brand-new (fresh `.empty`
    /// phase, fresh load task) — there's no other public way to make `AsyncImage` retry, and the
    /// manual path reuses the same mechanism for consistency.
    @State private var retryToken = 0
    @State private var retryCount = 0
    @State private var manualPhase: AsyncImagePhase = .empty

    private static var maxRetries: Int { 2 }
    private static var retryDelay: TimeInterval { 1.5 }

    var body: some View {
        Group {
            if httpHeaders.isEmpty {
                AsyncImage(url: url) { phase in
                    content(phase)
                        .onAppear {
                            // The `.failure` case only becomes visible (and this `.onAppear` only
                            // fires) once per actual failure, since the switch-over to a different
                            // phase mounts a genuinely new child view — no separate tracking needed.
                            guard case .failure = phase else { return }
                            scheduleRetryIfNeeded()
                        }
                }
            } else {
                content(manualPhase)
                    .task(id: url) { await loadManually() }
            }
        }
        .id(retryToken)
    }

    private func loadManually() async {
        guard let url else { return }
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let nsImage = NSImage(data: data)
            else {
                manualPhase = .failure(URLError(.badServerResponse))
                scheduleRetryIfNeeded()
                return
            }
            manualPhase = .success(Image(nsImage: nsImage))
        } catch {
            manualPhase = .failure(error)
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
