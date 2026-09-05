//
//  NtfyInboxTransport.swift
//  Wallwright
//
//  ntfy.sh's free hosted pub-sub push, subscribed to over Server-Sent Events. Android side: the
//  stock ntfy app, subscribed to the same topic, fed via Reels' share sheet. No account, no
//  self-hosting, no companion app — the topic name itself is the only "auth," which is why it's a
//  user-set Settings value (see GlobalSettings.inboxNtfyTopic's doc comment) rather than anything
//  baked into this file.
//
//  Event-driven, not polled: the SSE connection blocks on the open socket until ntfy actually has
//  something to send. Reconnects happen only from real lifecycle transitions (see AppDelegate's
//  four call sites into ActiveInboxTransport.shared.start()) that are already known to disrupt
//  network/state elsewhere in this app — never a timer-based retry loop.
//

import Foundation
import os

private let inboxDebugLog = Logger(subsystem: "com.wallwright.Wallwright", category: "InboxDebug")

final class NtfyInboxTransport: NSObject, InboxTransport {
    var onLinkReceived: ((String) -> Void)?

    private var task: URLSessionDataTask?
    private var session: URLSession?
    // `buffer` is touched both from whatever thread calls `start()`/`stop()` (AppDelegate's
    // lifecycle hooks — main thread in practice) and from `urlSession(_:dataTask:didReceive:)`,
    // which fires on URLSession's own private delegate queue (`delegateQueue: nil` below), not
    // main. Same class of bug already fixed elsewhere in this codebase for subprocess stdout/
    // stderr (VideoTranscoder/YtDlpService/SteamWorkshopService/VideoCropDetector's `syncQueue`
    // pattern) — narrower exposure here since reconnects only happen on real lifecycle events, but
    // still a real unsynchronized-Data race without this.
    private let bufferQueue = DispatchQueue(label: "NtfyInboxTransport.buffer-sync")
    private var buffer = Data()

    func start() {
        // Checking `.running` rather than just non-nil — confirmed live (2026-08-21) that a real
        // system sleep can kill the underlying socket without ever calling
        // `urlSession(_:task:didCompleteWithError:)`, which is the only place `self.task` gets
        // cleared. That left `task` non-nil but dead, so this idempotency guard silently no-opped
        // every later lifecycle-triggered reconnect (unlock, wake, becomeActive) forever — the
        // Inbox just stopped receiving after one sleep cycle with no way to recover short of
        // relaunching the app.
        guard task?.state != .running else {
            inboxDebugLog.notice("start() skipped — task already running")
            return
        }
        task?.cancel()
        // `URLSession` holds a strong reference to its `delegate` until explicitly invalidated —
        // every real caller of `start()` (all four are lifecycle reconnects, per this class's own
        // header comment) reaches this without necessarily going through `stop()` first, so a
        // bare `self.session = session` below would silently orphan whatever session was already
        // here on every reconnect, not just on an explicit `stop()`.
        session?.invalidateAndCancel()
        let topic = AppDelegate.shared.globalSettingsViewModel.settings.inboxNtfyTopic
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, let url = URL(string: "https://ntfy.sh/\(topic)/sse") else {
            inboxDebugLog.notice("start() aborted — empty topic or bad URL (topic=\(topic, privacy: .public))")
            return
        }

        bufferQueue.sync { buffer.removeAll() }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity // SSE is a long-lived stream, not a normal request
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
        inboxDebugLog.notice("start() connecting to \(url.absoluteString, privacy: .public)")
    }

    func stop() {
        task?.cancel()
        task = nil
        // Same reasoning as `start()`'s own `invalidateAndCancel()` call — a plain `session = nil`
        // drops our own reference but URLSession itself keeps its strong reference to `self` as
        // delegate alive until actually invalidated.
        session?.invalidateAndCancel()
        session = nil
        bufferQueue.sync { buffer.removeAll() }
    }
}

extension NtfyInboxTransport: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bufferQueue.sync {
            buffer.append(data)
            // SSE frames are newline-delimited; drain every complete line currently in the
            // buffer, leaving any trailing partial line for the next chunk. Collecting every line
            // first and doing a single trailing-removal after the loop, rather than
            // `removeSubrange` from the front on every line, avoids repeatedly shifting the same
            // remaining bytes down — `Data.removeSubrange` from the start is O(remaining length)
            // each call, so doing it once per line in this loop was O(lines × remaining length)
            // for one chunk instead of O(total length) once.
            var lines: [Data] = []
            var searchStart = buffer.startIndex
            while let newlineRange = buffer.range(of: Data([0x0A]), in: searchStart..<buffer.endIndex) { // "\n"
                lines.append(buffer.subdata(in: searchStart..<newlineRange.lowerBound))
                searchStart = newlineRange.upperBound
            }
            guard searchStart > buffer.startIndex else { return }
            buffer.removeSubrange(buffer.startIndex..<searchStart)
            for lineData in lines {
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                handle(line: line)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Connection dropped (network loss, sleep, ntfy.sh hiccup) or was cancelled by `stop()`.
        // Deliberately no retry-on-a-timer here — clearing `self.task` just lets the next
        // lifecycle-triggered call to `start()` (unlock, wake, becomeActive, or the next launch)
        // reconnect, matching every other idempotent-restart service in this app.
        inboxDebugLog.notice("didCompleteWithError: \(error?.localizedDescription ?? "nil", privacy: .public)")
        self.task = nil
        // Same reasoning as `start()`/`stop()`'s own `invalidateAndCancel()` calls — a bare
        // `session = nil` here would drop our reference but leave `URLSession` holding its own
        // strong reference to `self` as delegate alive indefinitely, since this was the one place
        // that nilled `session` without invalidating it first.
        self.session?.invalidateAndCancel()
        self.session = nil
    }

    private func handle(line: String) {
        guard line.hasPrefix("data:") else { return }
        // `.whitespacesAndNewlines`, not `.whitespaces` — lines are split on bare `\n` above, so a
        // CRLF-terminated line would leave a trailing `\r` that `.whitespaces` alone doesn't strip
        // (`\r`/`\n` are in `CharacterSet.newlines`, not `.whitespaces`).
        let jsonText = line.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              // ntfy also sends "open" (on connect) and "keepalive" (periodic) events over the same
              // stream — neither carries a "message" field, so this naturally filters them out
              // without needing to check the "event" field explicitly.
              let message = object["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let link = message.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in
            self?.onLinkReceived?(link)
        }
    }
}
