//
//  BrowseSourceSession.swift
//  Wallwright
//
//  A single shared session for the browse-tab sources' listing/detail requests, with a much
//  shorter timeout than URLSession.shared's 60s default. These calls sit behind a visible loading
//  spinner in a tab the user is actively looking at (unlike the Inbox's background classification,
//  which had the same missing-timeout gap but hidden — see InboxClassifier/YtDlpService/
//  VideoTranscoder's own fixes), so this is lower severity, but a slow or dead source still has no
//  reason to leave that spinner spinning for up to a full minute before failing.
//

import Foundation

extension URLSession {
    static let browseSource: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
}
