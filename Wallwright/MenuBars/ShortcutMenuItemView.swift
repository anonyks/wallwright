//
//  ShortcutMenuItemView.swift
//  Wallwright
//
//  A custom NSMenuItem row that draws its configured-hotkey hint right-aligned on the same line,
//  the way AppKit renders a real keyEquivalent — but purely cosmetic. A live keyEquivalent can't
//  be used for these rows: Carbon global hotkeys fire at the OS level regardless of what's
//  focused, so a real NSMenuItem keyEquivalent for the same combo would double-fire whenever this
//  menu happened to be open when the user pressed it. `.subtitle` avoids that but stacks the hint
//  on its own line below the title, which is what this replaces.
//

import Cocoa

final class ShortcutMenuItemView: NSView {
    private let highlightView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    private weak var target: NSObject?
    private let action: Selector
    private let systemImage: String
    weak var menuItem: NSMenuItem?

    init(title: String, systemImage: String, shortcut: String, target: NSObject?, action: Selector) {
        self.target = target
        self.action = action
        self.systemImage = systemImage
        super.init(frame: .zero)
        // No fixed frame — self must participate in Auto Layout (not just its subviews) so its
        // width is solved from actual content instead of a hardcoded guess. A previous version
        // gave `self` a fixed 280pt-wide starting frame with autoresizing left on, which never
        // shrank for short rows like "Next"/"Pin" — every custom row ended up 280pt regardless of
        // content, which is why the menu was rendering far wider than it needed to.
        translatesAutoresizingMaskIntoConstraints = false

        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 4
        highlightView.alphaValue = 0

        iconView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(scale: .small)
        iconView.contentTintColor = .labelColor

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor

        shortcutLabel.stringValue = shortcut
        shortcutLabel.font = .menuFont(ofSize: 0)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right

        for view in [highlightView, iconView, titleLabel, shortcutLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),

            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
        ])
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setShortcut(_ text: String) {
        shortcutLabel.stringValue = text
    }

    /// `NSMenuItem.copy()` (used for the Dock menu — see `AppDelegate.applicationDockMenu`) shares
    /// this same view instance by reference with the copied item rather than deep-copying it, and
    /// a single NSView can't be in two menus' hierarchies at once. Whoever copies a menu item that
    /// owns one of these views needs to swap in a fresh instance built from this one instead of
    /// reusing it directly.
    func rebuildFreshView() -> ShortcutMenuItemView {
        ShortcutMenuItemView(title: titleLabel.stringValue, systemImage: systemImage, shortcut: shortcutLabel.stringValue, target: target, action: action)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        highlightView.alphaValue = 1
        titleLabel.textColor = .white
        shortcutLabel.textColor = .white
        iconView.contentTintColor = .white
    }

    override func mouseExited(with event: NSEvent) {
        highlightView.alphaValue = 0
        titleLabel.textColor = .labelColor
        shortcutLabel.textColor = .secondaryLabelColor
        iconView.contentTintColor = .labelColor
    }

    override func mouseUp(with event: NSEvent) {
        menuItem?.menu?.cancelTracking()
        guard let target else { return }
        _ = target.perform(action)
    }
}

extension NSMenuItem {
    /// Builds a menu item whose configured-hotkey hint is drawn right-aligned on the same row —
    /// see `ShortcutMenuItemView`'s doc comment for why this can't just be a real keyEquivalent.
    static func withShortcutHint(title: String, systemImage: String, shortcut: String, target: NSObject?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let view = ShortcutMenuItemView(title: title, systemImage: systemImage, shortcut: shortcut, target: target, action: action)
        view.menuItem = item
        item.view = view
        return item
    }
}
