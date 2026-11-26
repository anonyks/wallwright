//
//  MainWindowController.swift
//  Wallwright
//
//  Created by Haren on 2023/8/8.
//

import Cocoa
import SwiftUI

/// A titled `NSWindow` that trades AppKit's default `constrainFrameRect` for a much looser one —
/// used for every real, user-facing window in the app (the main library window, Settings) that
/// still needs to stay reachable, unlike the fully-unconstrained `ClockOverlayWindow` (borderless,
/// nothing lost if it's dragged somewhere odd — see its own doc comment). AppKit's stock behavior
/// hard-stops a window's top edge right at the menu bar and keeps generous margins on every other
/// edge too — much tighter than the "drag it anywhere, like other apps" feel a floating utility or
/// media player usually has. This keeps that freedom while guaranteeing `minVisibleMargin` points
/// of the window stay on-screen on whichever edge it's pushed against, so the title bar can always
/// be grabbed back — a real window with close/minimize/zoom controls has no equivalent to the
/// clock overlay's "nothing to lose" if it goes fully off-screen.
class FreelyDraggableWindow: NSWindow {
    private static let minVisibleMargin: CGFloat = 30

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen else { return frameRect }
        var rect = frameRect
        let bounds = screen.frame
        let margin = Self.minVisibleMargin

        // Top: AppKit's own default clamps this hard at the menu bar (screen.visibleFrame.maxY) —
        // relaxed here to the screen's actual physical top, still keeping `margin` points of the
        // window (measured down from its top edge, where the title bar lives) reachable.
        if rect.maxY > bounds.maxY + margin {
            rect.origin.y = bounds.maxY + margin - rect.height
        }
        // Bottom: don't let the window drop so low its top (draggable) edge goes below the screen.
        if rect.minY < bounds.minY - rect.height + margin {
            rect.origin.y = bounds.minY - rect.height + margin
        }
        // Left/right: keep `margin` points horizontally reachable on whichever edge it's pushed
        // against — AppKit's default already allows most of a window off-screen here, but this
        // makes the bound explicit and consistent with the top/bottom handling above.
        if rect.minX > bounds.maxX - margin {
            rect.origin.x = bounds.maxX - margin
        }
        if rect.maxX < bounds.minX + margin {
            rect.origin.x = bounds.minX + margin - rect.width
        }
        return rect
    }
}

/// The library window. Its SwiftUI interface only exists while the window is in use (measured
/// about 90MB otherwise), so every way of putting the window on screen has to rebuild it first.
/// The window and its controller themselves always exist, so nothing that refers to them has to
/// care. An earlier version hooked `showWindow`, which this app never calls to show the window,
/// and left an empty title bar on screen.
final class LibraryWindow: FreelyDraggableWindow {
    var prepareToShow: (() -> Void)?

    override func makeKeyAndOrderFront(_ sender: Any?) {
        prepareToShow?()
        super.makeKeyAndOrderFront(sender)
    }

    override func orderFront(_ sender: Any?) {
        prepareToShow?()
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        prepareToShow?()
        super.orderFrontRegardless()
    }
}

class MainWindowController: NSWindowController, NSWindowDelegate {
    /// The window's size and position when its interface was released. A new interface would
    /// otherwise resize the window to its own preferred size.
    private var releasedFrame: NSRect?

    override var window: NSWindow! {
        get {
            return super.window
        }
        set {
            super.window = newValue
        }
    }

    override init(window: NSWindow?) {
        super.init(window: LibraryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false))
        self.window.delegate = self
        self.window.isReleasedWhenClosed = false
        self.window.title = "Wallwright \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")"
        self.window.titlebarAppearsTransparent = true
        // `isOpaque = false` + a `.clear` background are what actually let a `NSVisualEffectView`
        // in `.behindWindow` mode (see `WindowGlassBackground`, applied to `ContentView`'s root)
        // sample and blur the real desktop/other windows behind this one — without these two,
        // AppKit still paints its own solid `windowBackgroundColor` under everything, so the glass
        // controls throughout this app (`.glassEffect`) were only ever blurring that opaque gray,
        // never the actual desktop. `.fullSizeContentView` above lets content extend under the
        // (already-transparent) title bar so the glass fills the whole window, title bar included.
        self.window.isOpaque = false
        self.window.backgroundColor = .clear
        self.window.setFrameAutosaveName("MainWindow")
        // Deliberately left at AppKit's default (false) — the window already has a real title bar
        // (`.titled`, just transparent) that lets the user drag it from the top strip. Enabling
        // this made almost any click-drag in the content area (not just true empty background)
        // move the whole window instead — confirmed live: dragging the Clock Settings opacity
        // slider dragged the entire app window. SwiftUI controls like `Slider` don't always
        // reliably report to AppKit's `isMovableByWindowBackground` hit-testing that a click landed
        // on them rather than on "background," a known SwiftUI/AppKit integration gap.
        self.window.contentView = NSView()
        (self.window as? LibraryWindow)?.prepareToShow = { [weak self] in self?.installContentIfNeeded() }
    }

    private var hasContent: Bool { window.contentView is NSHostingView<AnyView> }

    /// Builds the library interface if it isn't there. Cheap to call when it already is.
    func installContentIfNeeded() {
        guard !hasContent else { return }
        window.contentView = NSHostingView(rootView: AnyView(ContentView(
                viewModel: AppDelegate.shared.contentViewModel,
                wallpaperViewModel: AppDelegate.shared.wallpaperViewModel
            ).environmentObject(AppDelegate.shared.globalSettingsViewModel)
        ))
        if let releasedFrame { window.setFrame(releasedFrame, display: false) }
    }

    /// A safety net for any way of showing the window that skips `LibraryWindow`'s overrides.
    func windowDidBecomeKey(_ notification: Notification) {
        installContentIfNeeded()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
    }

    /// Releases the library interface and evicts the shared thumbnail cache (library grid + every browse tab) once nothing can be
    /// looking at it — keeps the app's footprint down while it's just sitting in the menu bar,
    /// without touching per-source state (e.g. WallperViewModel's fetched sitemap) that would cost
    /// a real re-fetch over the network to rebuild on the next window open.
    func windowWillClose(_ notification: Notification) {
        ThumbnailImage.clearCache()
        // After the close finishes, and only if the window stayed closed. A sheet still attached
        // (an import review, say) keeps its interface so it isn't torn down mid-task.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasContent, !self.window.isVisible, self.window.attachedSheet == nil else { return }
            self.releasedFrame = self.window.frame
            self.window.contentView = NSView()
        }
    }

}
