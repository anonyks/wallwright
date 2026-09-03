//
//  ClockOverlay.swift
//  Wallwright
//
//  An optional day/date/time overlay drawn above the desktop wallpaper, configured from
//  Settings → General → Appearance ("Show Clock Overlay" + format/position/size/seconds/24h).
//
//  Adapted from LivePaper (MIT License, Copyright (c) 2026 Raunak Gupta)
//  https://github.com/Raunik2/LivePaper
//
//  Bundled fonts (Wallwright/Resources/Fonts): Anurati (Emmeran Richard) and Electroharmonix,
//  sourced from the Mond and Summit Rainmeter skins respectively; Quicksand (Andrew Paglinawan,
//  SIL Open Font License 1.1); Hero Bold, also from the Summit skin. Anurati/Electroharmonix/Hero
//  ship without a clear redistribution license — bundled at the project owner's explicit choice,
//  not because rights were confirmed.
//
//  The "Summit" format (GSClockFormat.summit) ports that skin's whole layout, not just its
//  fonts — greeting + time-of-day word, a large day glyph in Electroharmonix, and short divider
//  lines above/below — read directly from the skin's own Time.ini rather than guessed from a
//  screenshot: greeting/date/time all use Hero Bold; only the day glyph uses Electroharmonix; the
//  time-of-day word (morning/afternoon/evening/night) is computed from the current hour using the
//  exact same 24-bucket mapping Time.ini's Language.inc defines.

import AppKit
import Combine

/// Registers every font bundled in Resources/Fonts so they're available to NSFont(name:) lookups —
/// call once at launch.
func registerBundledClockFonts() {
    guard let fontsDir = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return }
    guard let files = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) else { return }
    for url in files where ["otf", "ttf"].contains(url.pathExtension.lowercased()) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

/// Resolves a chosen clock font, falling back to the system font if unavailable (System selected,
/// or registration failed for some reason).
private func clockFont(_ choice: GSClockFormat, size: CGFloat, fallbackWeight: NSFont.Weight = .thin) -> NSFont {
    if let postscriptName = choice.postscriptName,
       let font = NSFont(name: postscriptName, size: size) {
        return font
    }
    return NSFont.systemFont(ofSize: size, weight: fallbackWeight)
}

final class ClockOverlayView: NSView {
    private var timer: Timer?
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var settingsCancellable: AnyCancellable?
    private var clockShowSecondsCancellable: AnyCancellable?

    /// Handled manually (mouseDown/mouseDragged + setFrameOrigin) instead of via
    /// `isMovableByWindowBackground` — that built-in mechanism routes through
    /// `NSWindow.constrainFrameRect(_:to:)`, which by default won't let a window's top edge go
    /// above the menu bar (normally so its title bar stays reachable, irrelevant for a borderless
    /// overlay with nothing to reach). `setFrameOrigin` skips that constraint entirely, so this is
    /// the only way to let the clock be dragged as high as the user actually wants.
    override func mouseDown(with event: NSEvent) {
        guard AppDelegate.shared.globalSettingsViewModel.settings.clockDraggable, let window else { return }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startMouse = dragStartMouseLocation, let startOrigin = dragStartWindowOrigin else { return }
        let current = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: startOrigin.x + (current.x - startMouse.x), y: startOrigin.y + (current.y - startMouse.y)))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
    }

    private var clockColor: GSClockColor {
        AppDelegate.shared.globalSettingsViewModel.settings.clockColor
    }

    /// Resolves through `GlobalSettings` (not `clockColor` alone) since `.custom`'s actual colors
    /// live there — see `GlobalSettings.resolvedClockGradient`.
    private var resolvedGradient: (start: NSColor, end: NSColor, horizontal: Bool)? {
        AppDelegate.shared.globalSettingsViewModel.settings.resolvedClockGradient
    }

    private var clockOpacity: CGFloat {
        CGFloat(AppDelegate.shared.globalSettingsViewModel.settings.clockOpacity)
    }

    /// The gradient cases still need a real foregroundColor for the attributed string (opaque,
    /// so the gradient mask trick below has full alpha to key off of) — white works for either
    /// gradient direction since only its alpha channel ends up mattering. The base 0.95 is
    /// existing baseline translucency, further scaled by the user's own opacity setting.
    private var textColor: NSColor {
        clockColor.isGradient
            ? NSColor.white.withAlphaComponent(0.95 * clockOpacity)
            : clockColor.nsColor.withAlphaComponent(0.95 * clockOpacity)
    }

    /// Draws `string` normally for a solid color, or — for a gradient color — draws it first to
    /// establish an alpha mask, then paints the gradient into that region with `.sourceIn`
    /// blending so only the glyph pixels pick up gradient color. `.sourceIn` is scoped to
    /// `gradient.draw(in:)`'s own rect, so it can't touch anything already drawn outside it.
    private func drawText(_ string: NSAttributedString, at point: NSPoint, size: NSSize) {
        guard let (start, end, horizontal) = resolvedGradient, let context = NSGraphicsContext.current?.cgContext else {
            string.draw(at: point)
            return
        }
        context.saveGState()
        string.draw(at: point)
        context.setBlendMode(.sourceIn)
        // angle: 0 = axis points along +x (`start` left, `end` right); 270 = axis points along
        // -y (`start` top, `end` bottom, in reading order) — horizontal vs vertical is just
        // which of those two axes, and left-right/top-bottom vs the reverse is which color is
        // `start` vs `end`.
        let angle: CGFloat = horizontal ? 0 : 270
        NSGradient(starting: start, ending: end)?.draw(in: NSRect(origin: point, size: size), angle: angle)
        context.restoreGState()
    }

    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE"; return f }()
    private static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMMM, yyyy"; return f }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        // Without this, a layer-backed view's content changes can get an implicit cross-fade
        // animation between the old and new frame — invisible at the default 30s refresh, but
        // very visible with seconds enabled (1s refresh): every redraw briefly shows the old and
        // new digits overlapping mid-fade, reading as garbled/doubled text.
        layer?.actions = ["contents": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        restartTimer()

        let settingsPublisher = AppDelegate.shared.globalSettingsViewModel.$settings
        // Redraws immediately on any settings change (color, font, size, alignment, ...) instead
        // of waiting for the next periodic timer tick — up to 30s away, invisible for a
        // set-once-and-forget setting, but reads as flat-out broken for anything picked
        // interactively, like the custom gradient's color wells.
        settingsCancellable = settingsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
        // Only restarts the timer (which changes its own interval) when the one field that
        // actually determines that interval changes — not on every unrelated settings mutation
        // elsewhere in the app, which `settingsCancellable` above already reacts to for redrawing.
        clockShowSecondsCancellable = settingsPublisher
            .map(\.clockShowSeconds)
            .removeDuplicates()
            .dropFirst() // the constructor's own restartTimer() call above already covers the initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartTimer() }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit {
        timer?.invalidate()
        settingsCancellable?.cancel()
        clockShowSecondsCancellable?.cancel()
    }

    /// Seconds need a 1s refresh; otherwise 30s is plenty and cheaper.
    private func restartTimer() {
        timer?.invalidate()
        let settings = AppDelegate.shared.globalSettingsViewModel.settings
        let interval: TimeInterval = settings.clockShowSeconds ? 1.0 : 30.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        timer?.tolerance = interval * 0.2
    }

    private var textShadow: NSShadow {
        let s = NSShadow()
        // Scaled by the same opacity as the text itself — otherwise a mostly-faded clock would
        // keep a fully-opaque shadow behind it, reading as a smudge rather than a faint clock.
        s.shadowColor = NSColor(white: 0, alpha: 0.5 * clockOpacity)
        s.shadowOffset = NSSize(width: 0, height: -1)
        s.shadowBlurRadius = 6
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }
        let settings = AppDelegate.shared.globalSettingsViewModel.settings
        if settings.clockDayFont == .summit {
            drawSummitFormat(settings: settings)
            return
        }
        let now = Date()
        let dayFontSize = CGFloat(settings.clockDayFontSize)
        let dateFontSize = CGFloat(settings.clockDateFontSize)
        let timeFontSize = CGFloat(settings.clockTimeFontSize)

        let dayAttrs: [NSAttributedString.Key: Any] = [
            .font: clockFont(settings.clockDayFont, size: dayFontSize), .foregroundColor: textColor,
            .kern: (dayFontSize * 0.225) as NSNumber, .shadow: textShadow,
        ]
        let dayString = NSAttributedString(string: Self.dayFormatter.string(from: now).uppercased(), attributes: dayAttrs)
        let daySize = dayString.size()

        // Date/time are always the plain system font — only the day line's font is configurable.
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: dateFontSize, weight: .semibold), .foregroundColor: textColor,
            .kern: 3.5 as NSNumber, .shadow: textShadow,
        ]
        let dateString = NSAttributedString(string: Self.dateFormatter.string(from: now).uppercased(), attributes: dateAttrs)

        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: timeFontSize, weight: .semibold), .foregroundColor: textColor,
            .kern: 3.5 as NSNumber, .shadow: textShadow,
        ]

        let timeFormatter = DateFormatter()
        // Without a fixed locale, DateFormatter silently overrides a literal "HH" pattern back to
        // the system's 12/24-hour preference — this is what actually makes the toggle take effect.
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = settings.clockUse24HourTime
            ? (settings.clockShowSeconds ? "HH:mm:ss" : "HH:mm")
            : (settings.clockShowSeconds ? "h:mm:ss a" : "h:mm a")
        let timeString = NSAttributedString(string: "- " + timeFormatter.string(from: now).uppercased() + " -", attributes: timeAttrs)

        let dateSize = dateString.size()
        let timeSize = timeString.size()

        let gap1: CGFloat = dayFontSize * 0.225, gap2: CGFloat = dayFontSize * 0.2
        let totalHeight = daySize.height + gap1 + dateFontSize * 1.4 + gap2 + timeFontSize * 1.4

        // Where the block sits on screen is entirely up to dragging the window itself now — this
        // only decides how the lines line up with each other inside it. Anchored to the widest
        // line's own footprint (centered on the window), not the window's actual edges — the
        // window is sized off a rough per-font heuristic that's usually much bigger than the
        // real text, so anchoring to its edges would make switching alignment visibly relocate
        // the whole block instead of just reflowing lines relative to each other. The widest line
        // itself always lands in the exact same place regardless of which alignment is picked
        // (it has no slack inside its own reference box); only the narrower lines shift.
        let widestWidth = max(daySize.width, dateSize.width, timeSize.width)
        let virtualMinX = bounds.midX - widestWidth / 2
        let virtualMaxX = bounds.midX + widestWidth / 2
        func x(for width: CGFloat) -> CGFloat {
            switch settings.clockTextAlignment {
            case .left: return virtualMinX
            case .center: return bounds.midX - width / 2
            case .right: return virtualMaxX - width
            }
        }

        var y: CGFloat = bounds.midY + totalHeight / 2 - daySize.height

        drawText(dayString, at: NSPoint(x: x(for: daySize.width), y: y), size: daySize)

        y -= gap1 + dateSize.height
        drawText(dateString, at: NSPoint(x: x(for: dateSize.width), y: y), size: dateSize)

        y -= gap2 + timeSize.height
        drawText(timeString, at: NSPoint(x: x(for: timeSize.width), y: y), size: timeSize)
    }

    private static let summitDateFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMMM"; return f }()
    // Summit's Language.inc substitutes each full weekday name for its 3-letter form
    // ("Friday":"Fri", etc.) — "EEE" is that same abbreviation, not the "EEEE" full name the
    // default format's dayFormatter uses.
    private static let summitDayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()

    /// Same 24-hour bucket mapping as the skin's own Language.inc: 07–11 morning, 12–17
    /// afternoon, 18–20 evening, everything else night.
    private func summitTimeOfDayWord(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 7...11: return "morning"
        case 12...17: return "afternoon"
        case 18...20: return "evening"
        default: return "night"
        }
    }

    private func drawSummitLine(centerX: CGFloat, centerY: CGFloat, length: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let lineColor = clockColor.isGradient ? NSColor.white : clockColor.nsColor
        context.setFillColor(lineColor.withAlphaComponent(0.85 * clockOpacity).cgColor)
        context.fill(NSRect(x: centerX - 0.75, y: centerY - length / 2, width: 1.5, height: length))
        context.restoreGState()
    }

    /// Ported from the Summit Rainmeter skin's Time.ini: a short divider line, "GOOD"/time-of-day
    /// greeting, a large day glyph in Electroharmonix, date, time, and a matching divider line
    /// below — all sized off the same three sliders the default format uses (day/date/time), so
    /// switching formats doesn't strand the size controls.
    private func drawSummitFormat(settings: GlobalSettings) {
        let now = Date()
        let dayFontSize = CGFloat(settings.clockDayFontSize)
        // Greeting/date/time share one "body" size in the original skin — reusing the date slider
        // for it keeps every line legible together without adding a fourth, format-only control.
        let bodyFontSize = CGFloat(settings.clockDateFontSize)
        let timeFontSize = CGFloat(settings.clockTimeFontSize)

        let bodyFont = clockFont(.summit, size: bodyFontSize, fallbackWeight: .semibold)
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: textColor,
            .kern: (bodyFontSize * 0.18) as NSNumber, .shadow: textShadow,
        ]
        let dayAttrs: [NSAttributedString.Key: Any] = [
            .font: clockFont(.electroharmonix, size: dayFontSize), .foregroundColor: textColor, .shadow: textShadow,
        ]

        let greetingString = NSAttributedString(string: "GOOD", attributes: bodyAttrs)
        let timeOfDayString = NSAttributedString(string: summitTimeOfDayWord(for: now).uppercased(), attributes: bodyAttrs)
        let dayString = NSAttributedString(string: Self.summitDayFormatter.string(from: now).uppercased(), attributes: dayAttrs)
        let dateString = NSAttributedString(string: Self.summitDateFormatter.string(from: now).uppercased(), attributes: bodyAttrs)

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = settings.clockUse24HourTime
            ? (settings.clockShowSeconds ? "HH:mm:ss" : "HH:mm")
            : (settings.clockShowSeconds ? "h:mm:ss a" : "h:mm a")
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: clockFont(.summit, size: timeFontSize, fallbackWeight: .semibold), .foregroundColor: textColor,
            .kern: (timeFontSize * 0.2) as NSNumber, .shadow: textShadow,
        ]
        let timeString = NSAttributedString(string: timeFormatter.string(from: now).uppercased(), attributes: timeAttrs)

        let greetingSize = greetingString.size()
        let timeOfDaySize = timeOfDayString.size()
        let daySize = dayString.size()
        let dateSize = dateString.size()
        let timeSize = timeString.size()

        let lineLength: CGFloat = CGFloat(settings.clockSummitLineLength)
        let gapSmall: CGFloat = bodyFontSize * 0.45
        let gapAroundDay: CGFloat = dayFontSize * 0.15

        let totalHeight = lineLength + gapSmall
            + greetingSize.height + gapSmall * 0.35
            + timeOfDaySize.height + gapAroundDay
            + daySize.height + gapAroundDay
            + dateSize.height + gapSmall * 0.35
            + timeSize.height + gapSmall
            + lineLength

        // Summit's whole block — lines, greeting, day glyph, date, time — reads as one unit in
        // the original skin, so every element here shares one horizontal axis rather than each
        // line re-deriving its own edge. That shared axis is centered on the window and sized to
        // the widest element's own footprint (not the window's actual edges, which are sized off
        // a rough per-font heuristic much bigger than the real content) — so the widest element
        // lands in the same place no matter which alignment is picked, and only the narrower
        // lines shift, instead of switching alignment visibly relocating the whole block.
        let widestWidth = max(greetingSize.width, timeOfDaySize.width, daySize.width, dateSize.width, timeSize.width)
        let virtualMinX = bounds.midX - widestWidth / 2
        let virtualMaxX = bounds.midX + widestWidth / 2
        func x(for width: CGFloat) -> CGFloat {
            switch settings.clockTextAlignment {
            case .left: return virtualMinX
            case .center: return bounds.midX - width / 2
            case .right: return virtualMaxX - width
            }
        }
        let lineCenterX = x(for: lineLength) + lineLength / 2

        var y: CGFloat = bounds.midY + totalHeight / 2 - lineLength

        drawSummitLine(centerX: lineCenterX, centerY: y - lineLength / 2, length: lineLength)
        y -= lineLength + gapSmall

        y -= greetingSize.height
        drawText(greetingString, at: NSPoint(x: x(for: greetingSize.width), y: y), size: greetingSize)

        y -= gapSmall * 0.35 + timeOfDaySize.height
        drawText(timeOfDayString, at: NSPoint(x: x(for: timeOfDaySize.width), y: y), size: timeOfDaySize)

        y -= gapAroundDay + daySize.height
        drawText(dayString, at: NSPoint(x: x(for: daySize.width), y: y), size: daySize)

        y -= gapAroundDay + dateSize.height
        drawText(dateString, at: NSPoint(x: x(for: dateSize.width), y: y), size: dateSize)

        y -= gapSmall * 0.35 + timeSize.height
        drawText(timeString, at: NSPoint(x: x(for: timeSize.width), y: y), size: timeSize)

        y -= gapSmall
        drawSummitLine(centerX: lineCenterX, centerY: y - lineLength / 2, length: lineLength)
    }
}

/// Non-interactive (unless `clockDraggable` is on) window that sits just above the wallpaper
/// window on the same screen. Sized to scale with the three clock font sizes and positioned per
/// `clockTextAlignment` — the view draws its content anchored within this box, so the box itself
/// just needs to be big enough. Where the box itself sits on screen is entirely up to dragging it
/// (`clockCustomOrigins`); before the first drag on a given screen it just starts centered there.
final class ClockOverlayWindow: NSWindow {
    private let screenId: String
    private var pendingOriginSaveWorkItem: DispatchWorkItem?

    init(screen: NSScreen) {
        let settings = AppDelegate.shared.globalSettingsViewModel.settings
        let screenId = WallpaperViewModel.screenId(for: screen)
        let dayFontSize = CGFloat(settings.clockDayFontSize)
        let dateFontSize = CGFloat(settings.clockDateFontSize)
        let timeFontSize = CGFloat(settings.clockTimeFontSize)
        // Width scales off whichever line is biggest — day is usually the widest word at the
        // reference proportions, but date/time can now be sized independently past it.
        let width: CGFloat = max(dayFontSize, dateFontSize, timeFontSize) * 11.25
        // Mirrors draw()'s totalHeight math (day line + gaps + date/time lines), plus a flat
        // safety margin since this can't measure the actual rendered text before draw() runs.
        // Summit draws THREE lines at dateFontSize (greeting, time-of-day word, and the date
        // itself — not just one), plus the day glyph, plus two independently-sized divider
        // lines, so dateFontSize's coefficient has to cover all three or the bottom of the
        // content silently clips past the window's bottom edge as sizes grow (the divider line
        // and/or date/time text just don't get drawn — nothing crashes, they're clipped).
        let height: CGFloat = settings.clockDayFont == .summit
            ? dayFontSize * 1.6 + dateFontSize * 5.6 + timeFontSize * 1.3 + 40 + CGFloat(settings.clockSummitLineLength) * 2
            : dayFontSize * 1.425 + dateFontSize * 1.4 + timeFontSize * 1.4 + 40
        let frame = screen.frame
        // Default to this screen's center until the user drags the overlay somewhere else —
        // there's no longer a preset "position" to fall back to.
        let defaultOrigin = NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
        let finalOrigin = settings.clockCustomOrigins?[screenId] ?? defaultOrigin

        self.screenId = screenId
        super.init(
            contentRect: NSRect(origin: finalOrigin, size: NSSize(width: width, height: height)),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        // Draggable mode needs to sit above regular app windows to actually receive clicks —
        // desktop level is normally correct (stays under everything) but would make dragging
        // silently never work since real windows in front of it would eat the mouseDown first.
        level = settings.clockDraggable
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = !settings.clockDraggable
        // Deliberately false — dragging is handled manually in ClockOverlayView instead, since
        // this built-in mechanism is the thing that enforces the menu-bar drag ceiling.
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // See WallpaperWindow's identical setting in AppDelegate.swift — same class of desktop-
        // level overlay window, same reason to opt out of macOS's window state-restoration system.
        isRestorable = false
        contentView = ClockOverlayView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMoveHandler),
            name: NSWindow.didMoveNotification, object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingOriginSaveWorkItem?.cancel()
    }

    /// AppKit posts this repeatedly through a live drag, not just once at the end — debounced so
    /// dragging doesn't hammer the settings file with a write on every frame of mouse movement.
    @objc private func windowDidMoveHandler() {
        guard AppDelegate.shared.globalSettingsViewModel.settings.clockDraggable else { return }
        pendingOriginSaveWorkItem?.cancel()
        let capturedOrigin = frame.origin
        let capturedScreenId = screenId
        let workItem = DispatchWorkItem {
            var origins = AppDelegate.shared.globalSettingsViewModel.settings.clockCustomOrigins ?? [:]
            origins[capturedScreenId] = capturedOrigin
            AppDelegate.shared.globalSettingsViewModel.settings.clockCustomOrigins = origins
        }
        pendingOriginSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit's default window-drag behavior keeps a window's top edge from going above the menu
    /// bar, so its title bar always stays reachable — this window has no title bar and nothing to
    /// reach, so that constraint just stops the user from dragging it as high as they want.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
