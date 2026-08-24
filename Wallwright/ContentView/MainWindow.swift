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
        self.window.contentView = NSHostingView(rootView: ContentView(
                viewModel: AppDelegate.shared.contentViewModel,
                wallpaperViewModel: AppDelegate.shared.wallpaperViewModel
            ).environmentObject(AppDelegate.shared.globalSettingsViewModel)
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
    }
    
}
