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

enum DirectURLImportError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a valid http(s) URL"
        case .badStatus(let code):
            return "Server returned an error (HTTP \(code))"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
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
            // The file at `location` is deleted the instant this method returns, so it has to be
            // moved out synchronously here rather than handed off for later.
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
                continuation?.resume(throwing: DirectURLImportError.badStatus(code))
                continuation = nil
                return
            }
            do {
                let scratchDir = FileManager.default.temporaryDirectory.appending(path: "wallwright-directurl-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
                let filename = response.suggestedFilename ?? location.lastPathComponent
                let destination = scratchDir.appending(path: filename)
                try FileManager.default.moveItem(at: location, to: destination)
                continuation?.resume(returning: destination)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return } // success is already resumed from didFinishDownloadingTo
            continuation?.resume(throwing: DirectURLImportError.downloadFailed(error.localizedDescription))
            continuation = nil
        }
    }
}
