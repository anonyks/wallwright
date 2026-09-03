//
//  MainWindowController.swift
//  Wallwright
//
//  Created by Haren on 2023/8/8.
//

import Cocoa
import SwiftUI

class MainWindowController: NSWindowController, NSWindowDelegate {
    override var window: NSWindow! {
        get {
            return super.window
        }
        set {
            super.window = newValue
        }
    }
    
    override init(window: NSWindow?) {
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false))
        self.window.delegate = self
        self.window.isReleasedWhenClosed = false
        self.window.title = "Wallwright \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String)"
        self.window.titlebarAppearsTransparent = true
        self.window.setFrameAutosaveName("MainWindow")
        // Deliberately left at AppKit's default (false) — the window already has a real title bar
        // (`.titled`, just transparent) that lets the user drag it from the top strip. Enabling
        // this made almost any click-drag in the content area (not just true empty background)
        // move the whole window instead — confirmed live: dragging the Clock Settings opacity
        // slider dragged the entire app window. SwiftUI controls like `Slider` don't always
        // reliably report to AppKit's `isMovableByWindowBackground` hit-testing that a click landed
        // on them rather than on "background," a known SwiftUI/AppKit integration gap.
        self.window.contentView = Self.makeContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }

    private static func makeContentView() -> NSHostingView<some View> {
        NSHostingView(rootView: ContentView(
            viewModel: AppDelegate.shared.contentViewModel,
            wallpaperViewModel: AppDelegate.shared.wallpaperViewModel
        ).environmentObject(AppDelegate.shared.globalSettingsViewModel))
    }

    /// Every real call site that shows this window (first-launch reveal, applicationShouldHandleReopen,
    /// the menu bar's "Show Wallwright") should go through this instead of poking `.window` directly.
    /// Confirmed live: `windowWillClose` clearing the shared thumbnail cache alone didn't actually
    /// free anything — `isReleasedWhenClosed = false` (deliberate, for a fast reopen with no rebuild
    /// cost) means closing the window only ever hides it, so the still-alive `NSHostingView` and
    /// every `NSImageView` grid cell it ever materialized while scrolling kept its OWN direct strong
    /// reference to its decoded image, completely independent of what the shared cache does — real
    /// memory sat well above 400MB with the window fully closed. Rebuilding `contentView` from
    /// scratch here (paired with `windowWillClose` releasing it) actually deallocates that whole
    /// view tree, at the cost of the window resetting to a fresh state (search text, scroll
    /// position) on reopen rather than resuming exactly where it was — a reasonable tradeoff for an
    /// app that's meant to sit in the menu bar most of the time, not a cosmetic regression to chase.
    func present() {
        if window.contentView == nil {
            window.contentView = Self.makeContentView()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Evicts the shared thumbnail cache (library grid + every browse tab) and releases this
    /// window's own view tree — see `present()`'s doc comment for why both are needed. `present()`
    /// rebuilds `contentView` the next time this window is actually shown again.
    func windowWillClose(_ notification: Notification) {
        ThumbnailImage.clearCache()
        window.contentView = nil
    }

}
