//
//  InboxLinksStore.swift
//  Wallwright
//
//  Holds every link shared into the Inbox from a phone (see InboxTransport) — persisted the same
//  way PlaylistViewModel/GlobalSettingsService already persist their own state: a flat JSON file,
//  atomic write, no database. Owns the whole lifecycle of a link: classification (direct vs.
//  indirect, see InboxClassifier), routing an import to the right existing pipeline, and removal.
//

import Foundation

enum InboxLinkKind: Codable, Equatable {
    case direct     // URL points straight at a media file
    case indirect   // page URL needing yt-dlp (or similar) to resolve the real file
    case unknown    // not yet classified
}

enum InboxLinkStatus: Codable, Equatable {
    case pending
    case resolving
    case resolved
    case downloading
    case importing
    case completed
    case failed(reason: String)
}

struct InboxLink: Codable, Identifiable, Equatable {
    let id: UUID
    let url: URL
    let dateAdded: Date
    var kind: InboxLinkKind
    var status: InboxLinkStatus
    var resolvedTitle: String?
    var resolvedThumbnailURL: URL?

    init(
        id: UUID = UUID(), url: URL, dateAdded: Date = Date(),
        kind: InboxLinkKind = .unknown, status: InboxLinkStatus = .pending,
        resolvedTitle: String? = nil, resolvedThumbnailURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.dateAdded = dateAdded
        self.kind = kind
        self.status = status
        self.resolvedTitle = resolvedTitle
        self.resolvedThumbnailURL = resolvedThumbnailURL
    }
}

@MainActor
final class InboxLinksStore: ObservableObject {
    @Published private(set) var links: [InboxLink] = []

    /// Live download percentage per link, keyed by `InboxLink.id` — deliberately NOT part of
    /// `InboxLink` itself. A download's progress ticks many times a second; persisting that as
    /// part of the Codable model would mean rewriting the whole JSON file to disk on every tick.
    /// `status` alone (which only changes a handful of times per link) drives what gets saved;
    /// this is transient, in-memory-only UI state, same split `MotionBgsViewModel.downloadState`
    /// already uses for its own (non-persisted) items.
    @Published var downloadProgress: [UUID: Double] = [:]

    /// Links currently past the download itself and into ffmpeg re-encoding to H.264 — yt-dlp/
    /// YouTube can serve AV1/VP9, which AVFoundation can't reliably decode, so `YtDlpService`
    /// transcodes when needed. That step has no percentage to report, so without tracking this
    /// separately the row's progress bar just sits frozen at 100% for however long the re-encode
    /// takes, which reads as stuck rather than working — confirmed live (2026-08-21).
    @Published var isConverting: Set<UUID> = []

    /// Set right before opening the existing Direct URL Import sheet for a `.direct` link's Import
    /// action — see `importDirectLink(_:)`. `ContentView`'s existing `pendingDirectURLDownload`
    /// handoff calls `markSheetImportCompletedIfPending()` once that sheet's own download actually
    /// succeeds, which is the only reliable "did this finish" signal (the user can always cancel
    /// the sheet instead).
    private var pendingSheetImportLinkId: UUID?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wallwright Settings")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appending(path: "InboxLinks.json")
    }

    init() {
        links = Self.loadPersisted()
        // Anything caught mid-flight by the last relaunch can never actually finish — the
        // Process/URLSession that was driving it died with the previous app instance. Reset those
        // back to a state the user can act on again instead of leaving a permanently stuck row.
        for index in links.indices {
            switch links[index].status {
            case .downloading, .importing, .resolving:
                links[index].status = .pending
            case .pending, .resolved, .completed, .failed:
                break
            }
        }
        // Re-runs the two free checks for anything persisted as `.unknown` from before this
        // migration (or before `knownVideoOnlyHosts` grew a new entry) — cheap and idempotent, so
        // no harm re-checking on every launch rather than tracking whether it's needed.
        for link in links where link.kind == .unknown {
            classify(link.id)
        }
    }

    private static func loadPersisted() -> [InboxLink] {
        guard let data = try? Data(contentsOf: fileURL),
              let links = try? JSONDecoder().decode([InboxLink].self, from: data)
        else { return [] }
        return links
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(links) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Adding / removing

    /// Called from `InboxTransport.onLinkReceived` and from the manual "+" add path. Rejects a URL
    /// already present (normalized: scheme+host lowercased, trailing slash ignored) rather than
    /// creating a duplicate row for the same link shared twice.
    @discardableResult
    func add(urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard !links.contains(where: { $0.url.inboxDedupKey == url.inboxDedupKey }) else { return false }

        let link = InboxLink(url: url)
        links.insert(link, at: 0) // newest first
        classify(link.id) // cheap/synchronous now — see its doc comment
        return true
    }

    func remove(_ link: InboxLink) {
        links.removeAll { $0.id == link.id }
        downloadProgress[link.id] = nil
        save()
    }

    func removeAll() {
        links.removeAll()
        downloadProgress.removeAll()
        save()
    }

    func removeCompletedAndFailed() {
        links.removeAll {
            switch $0.status {
            case .completed, .failed: return true
            case .pending, .resolving, .resolved, .downloading, .importing: return false
            }
        }
        save()
    }

    func retry(_ link: InboxLink) {
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[index].status = .pending
        save()
    }

    // MARK: - Classification

    /// Two free checks only — no network, no yt-dlp, nothing that can take real time. Confirmed
    /// live (2026-08-22): the previous version ran a yt-dlp probe here too, the moment a link
    /// arrived — but arriving isn't importing, most shared links sit in the Inbox for a while
    /// (some never get imported at all), and there's no reason to spend a real network round-trip
    /// (several seconds even in the fast case, up to the 15s hard cap otherwise — see
    /// `YtDlpService.fetchInfo`) on every single one just for a "Classifying…" label nobody asked
    /// for yet. Anything neither check can place stays `.unknown` — not "still working on it," just
    /// "don't know yet, and won't try to know until asked." `importLink` resolves that lazily, on
    /// the actual tap, via `resolveUnknownLink`.
    private func classify(_ id: UUID) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        let url = links[index].url

        if InboxClassifier.isDirectByExtension(url) {
            links[index].kind = .direct
        } else if InboxClassifier.isKnownVideoOnlyHost(url) {
            links[index].kind = .indirect
        }
        save()
    }

    // MARK: - Importing

    /// Kicks off the right pipeline for a link's classified kind. `.unknown` is the common case for
    /// anything that isn't an obviously-direct file or a known video-only host — resolved lazily
    /// here, on the actual tap, rather than the moment the link arrived (see `classify`'s doc
    /// comment for why).
    func importLink(_ link: InboxLink) {
        switch link.kind {
        case .direct:
            importDirectLink(link)
        case .indirect:
            if case .resolved = link.status {
                downloadIndirectLink(link)
            } else {
                Task { await resolveIndirectLink(link) }
            }
        case .unknown:
            Task { await resolveUnknownLink(link) }
        }
    }

    /// The yt-dlp-probe-then-Content-Type-fallback logic `classify` used to run eagerly on arrival
    /// — same two paths, just triggered by an actual Import tap instead. On success, continues
    /// straight into the matching import pipeline rather than making the user tap Import a second
    /// time now that its kind is finally known.
    private func resolveUnknownLink(_ link: InboxLink) async {
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[index].status = .resolving
        save()

        do {
            let info = try await YtDlpService.fetchInfo(url: link.url.absoluteString)
            guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
            links[index].kind = .indirect
            links[index].resolvedTitle = info.title
            links[index].resolvedThumbnailURL = info.thumbnailURL
            links[index].status = .resolved
            save()
            downloadIndirectLink(links[index])
        } catch {
            // Not necessarily "yt-dlp doesn't support this site" — could just as easily be a real,
            // specific failure on a site it DOES support (private/login-required content, a region
            // lock, an extractor-side error). Content-Type is still worth checking in case this is
            // actually a plain direct file yt-dlp was never going to handle regardless, but if that
            // comes up empty too, yt-dlp's own error is by far the more informative of the two to
            // show — confirmed live (2026-08-21): a real Vimeo OAuth/token error was otherwise
            // getting swallowed and replaced with a generic "couldn't figure out" message.
            guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
            let kind = await InboxClassifier.classifyByContentType(link.url)
            links[index].kind = kind
            if kind == .direct {
                save()
                importDirectLink(links[index])
            } else {
                links[index].status = .failed(reason: error.localizedDescription)
                save()
            }
        }
    }

    /// Reuses the existing Direct URL Import sheet wholesale rather than re-implementing its
    /// download/review/commit flow here — pre-fills the sheet's own URL field and opens it exactly
    /// as if the user had pasted the link there themselves. `markSheetImportCompletedIfPending()`
    /// (called from `ContentView`'s existing `pendingDirectURLDownload` handoff) is what actually
    /// marks the row `.completed`, since the user can always cancel the sheet instead of finishing.
    private func importDirectLink(_ link: InboxLink) {
        pendingSheetImportLinkId = link.id
        let contentViewModel = AppDelegate.shared.contentViewModel
        // `DirectURLImportViewModel` is `@MainActor`-isolated; this method is always called from a
        // SwiftUI button action (already on the main thread), same pattern `ContentViewModel` itself
        // already uses elsewhere to cross into that isolation.
        Task { @MainActor in
            contentViewModel.directURLImportViewModel.reset()
            contentViewModel.directURLImportViewModel.urlString = link.url.absoluteString
            contentViewModel.isDirectURLImportReveal = true
        }
    }

    /// Called from `ContentView`'s `pendingDirectURLDownload` handoff once the Direct URL sheet's
    /// download has actually succeeded — the only reliable "did this finish" signal, since the
    /// sheet can always be cancelled instead.
    func markSheetImportCompletedIfPending() {
        guard let id = pendingSheetImportLinkId else { return }
        pendingSheetImportLinkId = nil
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].status = .completed
        save()
    }

    /// Called from `ContentView`'s `pendingDirectURLDownload` handoff when the Direct URL sheet
    /// closes WITHOUT a completed download (the user cancelled, or dismissed it) — without this,
    /// `pendingSheetImportLinkId` stays set to this link's id indefinitely, since
    /// `markSheetImportCompletedIfPending()` above only ever runs on the success path. The next
    /// time the user opens Direct URL Import for anything else entirely and that one actually
    /// succeeds, `markSheetImportCompletedIfPending()` would find this stale id still set and
    /// wrongly mark THIS link `.completed`, even though it was never imported.
    func cancelPendingSheetImport() {
        pendingSheetImportLinkId = nil
    }

    /// Fetches title/thumbnail via yt-dlp without downloading any video data — same call
    /// `YouTubeImportViewModel` already makes, just not restricted to youtube.com. Sets `.resolved`
    /// on success (ready for `downloadIndirectLink` on the next tap) or `.failed` with yt-dlp's own
    /// reported reason (unsupported site, private/login-required content, 404, ...).
    private func resolveIndirectLink(_ link: InboxLink) async {
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[index].status = .resolving
        do {
            let info = try await YtDlpService.fetchInfo(url: link.url.absoluteString)
            guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
            links[index].resolvedTitle = info.title
            links[index].resolvedThumbnailURL = info.thumbnailURL
            links[index].status = .resolved
            save()
        } catch {
            setFailed(link.id, reason: error.localizedDescription)
        }
    }

    private func downloadIndirectLink(_ link: InboxLink) {
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[index].status = .downloading
        downloadProgress[link.id] = 0
        isConverting.remove(link.id)
        Task {
            do {
                let result = try await YtDlpService.download(
                    url: link.url.absoluteString, includeAudio: true, start: nil, end: nil,
                    onProgress: { [weak self] progress in self?.downloadProgress[link.id] = progress },
                    onTranscodingStart: { [weak self] in self?.isConverting.insert(link.id) }
                )
                await commitIndirectImport(fileURL: result.fileURL, link: link)
            } catch {
                setFailed(link.id, reason: error.localizedDescription)
            }
        }
    }

    private func commitIndirectImport(fileURL: URL, link: InboxLink) async {
        // Same cleanup-on-early-return as `commitDirectImport` below — if the link was deleted
        // from the Inbox while this download was still in flight, this guard used to return
        // without ever touching `fileURL`'s scratch directory, permanently orphaning it.
        guard let index = links.firstIndex(where: { $0.id == link.id }) else {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            return
        }
        isConverting.remove(link.id)
        links[index].status = .importing
        let title = links[index].resolvedTitle
        let success = await withCheckedContinuation { continuation in
            VideoImporter.importVideoFile(
                at: fileURL, title: title, tags: nil,
                sourceProvider: "inbox", sourceId: link.id.uuidString
            ) { success in continuation.resume(returning: success) }
        }
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        if success {
            links[index].status = .completed
        } else {
            links[index].status = .failed(reason: "Import failed")
        }
        save()
    }

    private func setFailed(_ id: UUID, reason: String) {
        isConverting.remove(id)
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].status = .failed(reason: reason)
        downloadProgress[id] = nil
        save()
    }

    // MARK: - Direct links batch import

    func downloadAndImportDirectLink(_ link: InboxLink) {
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[index].status = .downloading
        downloadProgress[link.id] = 0
        save()
        Task {
            do {
                let fileURL = try await DirectURLImporter.download(from: link.url) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress[link.id] = progress
                    }
                }
                await commitDirectImport(fileURL: fileURL, link: link)
            } catch {
                setFailed(link.id, reason: error.localizedDescription)
            }
        }
    }

    private func commitDirectImport(fileURL: URL, link: InboxLink) async {
        guard let index = links.firstIndex(where: { $0.id == link.id }) else {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            return
        }
        links[index].status = .importing
        let title = links[index].resolvedTitle ?? fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let isImage = ImageImporter.importableExtensions.contains(ext)
        let success: Bool
        if isImage {
            success = ImageImporter.importImageFile(
                at: fileURL, title: title, tags: nil,
                sourceProvider: "inbox", sourceId: link.id.uuidString
            )
        } else {
            success = await withCheckedContinuation { continuation in
                VideoImporter.importVideoFile(
                    at: fileURL, title: title, tags: nil,
                    sourceProvider: "inbox", sourceId: link.id.uuidString
                ) { success in continuation.resume(returning: success) }
            }
        }
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        if success {
            links[index].status = .completed
        } else {
            links[index].status = .failed(reason: "Import failed")
        }
        save()
    }

    // MARK: - Batch actions

    /// Toolbar's "Import All Direct" — batch-downloads and imports every already-classified
    /// `.direct` link sitting idle in the background without stomping sheet state.
    func importAllDirect() {
        for link in links where link.kind == .direct {
            switch link.status {
            case .pending, .resolved:
                downloadAndImportDirectLink(link)
            case .resolving, .downloading, .importing, .completed, .failed:
                continue
            }
        }
    }
}

private extension URL {
    /// Loose normalization for dedup — scheme+host lowercased, trailing slash on the path ignored.
    /// Not trying to be a fully correct URL-equivalence check (query param ordering, tracking
    /// params, etc.) — just enough to catch "the exact same link shared twice," which is the
    /// actual case this exists to prevent.
    var inboxDedupKey: String {
        var path = self.path
        if path.hasSuffix("/") { path.removeLast() }
        return "\(scheme?.lowercased() ?? "")://\(host?.lowercased() ?? "")\(path)?\(query ?? "")"
    }
}
