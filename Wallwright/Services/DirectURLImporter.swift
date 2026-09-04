//
//  DirectURLImporter.swift
//  Wallwright
//
//  Downloads a file from a direct link (a URL pointing straight at the file itself, not a page
//  that needs scraping) into a scratch directory. Fully media-type-agnostic — just streams
//  whatever's at the URL to disk; the caller (ContentView's `pendingDirectURLDownload` handoff)
//  decides whether to route the result through VideoImporter or ImageImporter.
//

import Foundation
import UniformTypeIdentifiers

enum DirectURLImportError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case downloadFailed(String)
    case notMedia(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a valid http(s) URL"
        case .badStatus(let code):
            return "Server returned an error (HTTP \(code))"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .notMedia(let mimeType):
            return "That link points to a webpage (\(mimeType)), not a video or image file — a direct link ends at the file itself."
        }
    }
}

enum DirectURLImporter {
    /// Downloads `url` to a fresh scratch directory, reporting progress as it goes (`nil` when the
    /// server didn't report a content length, so the caller shows an indeterminate spinner instead
    /// of a stalled percentage). Uses `URLSessionDownloadTask` (streams straight to disk) rather
    /// than buffering the whole response in memory — video files can be hundreds of MB.
    ///
    /// `headers` is empty for every caller except sources whose CDN enforces Referer-based hotlink
    /// protection (e.g. uhdpaper.com — confirmed live: its asset CDN 302-redirects a bare request
    /// and only serves the real file with `Referer` set).
    static func download(from url: URL, headers: [String: String] = [:], onProgress: @escaping (Double?) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            task.resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let onProgress: (Double?) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(onProgress: @escaping (Double?) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            onProgress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // `URLSession` holds a strong reference to its delegate (this object) until explicitly
            // invalidated — same leak class already fixed in `NtfyInboxTransport`. This task is the
            // session's only task and has already finished by the time this method runs, so
            // `finishTasksAndInvalidate()` (not `invalidateAndCancel()`, which would cancel it)
            // releases the session/delegate pair the moment this method returns, on every exit path.
            defer { session.finishTasksAndInvalidate() }
            // The file at `location` is deleted the instant this method returns, so it has to be
            // moved out synchronously here rather than handed off for later.
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
                continuation?.resume(throwing: DirectURLImportError.badStatus(code))
                continuation = nil
                return
            }
            // Confirmed live (2026-08-22): a URL that actually resolves to a plain webpage (a
            // redirect landing page, anything that isn't really the file itself) still downloads
            // "successfully" — HTTP status alone says nothing about whether the bytes are actually
            // media, and the sheet was offering "Continue to Title & Tags" on a downloaded HTML
            // page. Blocklist, not allowlist: legitimate direct-file servers often send a generic
            // `application/octet-stream` or nothing at all, so only reject the unambiguous
            // "this is text, not a file" types rather than requiring an exact video/image match.
            // The file at `location` doesn't need explicit cleanup on this path — per
            // `URLSessionDownloadDelegate`'s contract, it's removed automatically once this method
            // returns without having moved it.
            if let mimeType = response.mimeType?.lowercased(),
               mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "application/xml" {
                continuation?.resume(throwing: DirectURLImportError.notMedia(mimeType))
                continuation = nil
                return
            }
            do {
                let scratchDir = FileManager.default.temporaryDirectory.appending(path: "wallwright-directurl-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
                var filename = response.suggestedFilename ?? location.lastPathComponent
                // A query-parameter-based or extensionless direct link (no `Content-Disposition`,
                // a URL path with no extension of its own) leaves `filename` without one — this
                // file's own header says routing the result is entirely up to the caller reading
                // the extension back off this URL (see `ContentView`'s handoff), so a missing
                // extension here silently misroutes an image download into the video import
                // pipeline, which then fails trying to transcode it. `mimeType` is already read
                // above for the text/JSON check; reusing it to infer the real extension when
                // needed costs nothing extra and doesn't change anything for the common case where
                // the filename already has one.
                //
                // A *present but non-media* extension needs the same treatment, not just a missing
                // one — a PHP/ASPX download gateway (confirmed live: MoeWalls' own
                // `go.moewalls.com/download.php?video=...`, already integrated in this app) has no
                // `Content-Disposition` either, so `suggestedFilename` falls back to the URL's own
                // path component, "download.php" — a non-empty extension that skipped this check
                // entirely before, leaving the file on disk (and everything downstream reading its
                // extension) thinking it was a PHP script rather than a video.
                let currentExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
                let isKnownMediaExtension = VideoImporter.importableExtensions.contains(currentExtension)
                    || ImageImporter.importableExtensions.contains(currentExtension)
                if (currentExtension.isEmpty || !isKnownMediaExtension),
                   let mimeType = response.mimeType,
                   let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension {
                    filename = currentExtension.isEmpty
                        ? filename + "." + ext
                        : URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent + "." + ext
                }
                let destination = scratchDir.appending(path: filename)
                try FileManager.default.moveItem(at: location, to: destination)
                continuation?.resume(returning: destination)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // Success invalidates from `didFinishDownloadingTo` instead — this fires again
            // afterward either way (with `error == nil` on success), so invalidating
            // unconditionally here too would just be a harmless no-op repeat, but returning early
            // keeps this method's own responsibility limited to the failure path it actually owns.
            guard let error else { return }
            session.finishTasksAndInvalidate()
            continuation?.resume(throwing: DirectURLImportError.downloadFailed(error.localizedDescription))
            continuation = nil
        }
    }
}
