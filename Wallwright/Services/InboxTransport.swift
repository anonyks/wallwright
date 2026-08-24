//
//  InboxTransport.swift
//  Wallwright
//
//  Abstracts *how* a shared URL arrives from a phone, so the rest of the Inbox feature
//  (InboxLinksStore, classification, routing, UI) never talks to a concrete backend directly.
//  ntfy (NtfyInboxTransport) is the only conformance actually built — this protocol exists purely
//  as insurance: if ntfy turns out unreliable in practice, swapping it for something else (a
//  Telegram bot long-poll loop, say) is a one-line change in ActiveInboxTransport below, not a
//  rewrite touching storage, classification, or UI.
//

import Foundation

protocol InboxTransport: AnyObject {
    /// Idempotent — safe to call repeatedly; only the first call (or the first call after a real
    /// disconnect) should do anything, same pattern as
    /// `BatteryMonitor.startIfNeeded()`/`FullscreenAppMonitor.startIfNeeded()` elsewhere in this app.
    func start()
    func stop()
    /// Called whenever a new URL string arrives, regardless of backend.
    var onLinkReceived: ((String) -> Void)? { get set }
}

/// The single active transport instance — every lifecycle call site (AppDelegate) and
/// InboxLinksStore itself talk only to this, never to `NtfyInboxTransport` directly, so changing
/// backends later is this one line.
enum ActiveInboxTransport {
    static let shared: InboxTransport = NtfyInboxTransport()
}
