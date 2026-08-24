//
//  Menu.swift
//  Wallwright
//
//  Created by Haren on 2023/8/8.
//

import Cocoa

extension AppDelegate {
    func setMainMenu() {
        // 主菜单
        let appMenu = NSMenuItem()
        appMenu.submenu = NSMenu(title: "Wallwright")
        appMenu.submenu?.items = [
            // 在此处添加子菜单项
            .init(title: String(localized: "About Wallwright"), action: #selector(self.showAboutUs), keyEquivalent: ""),
            .separator(),
            .init(title: String(localized: "Settings..."), action: #selector(openSettingsWindow), keyEquivalent: ","),
            .separator(),
            .init(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
            .separator(),
            .init(title: String(localized: "Hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            {
                let item = NSMenuItem(title: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
                item.keyEquivalentModifierMask = [.command, .option]
                return item
            }()
        ]

        // 导入子菜单
        // Just one entry: the panel this opens already supports selecting multiple folders,
        // zips, or video/image files at once (see `allowsMultipleSelection` in
        // `openImportFromFolderPanel`), so a separate "Wallpapers in Folders" item would be
        // redundant even if it were wired up.
        let importMenu = NSMenuItem(title: String(localized: "Import"), action: nil, keyEquivalent: "")
        importMenu.submenu = NSMenu()
        importMenu.submenu?.items = [
            .init(title: String(localized: "Wallpaper from Folder"), action: #selector(openImportFromFolderPanel), keyEquivalent: "i")
        ]

        // 文件菜单
        let fileMenu = NSMenuItem()
        fileMenu.submenu = NSMenu(title: String(localized: "File"))
        fileMenu.submenu?.items = [
            // 在此处添加子菜单项
            importMenu,
            .separator(),
            .init(title: String(localized: "Close Window"), action: #selector(AppDelegate.shared.mainWindowController.window.performClose), keyEquivalent: "w")
        ]

        // Edit menu — Cut/Copy/Paste/Undo/Redo/Select All. A prior version of this file removed
        // this entirely on the theory that text fields "already get standard Cut/Copy/Paste for
        // free from the system." Confirmed live (2026-08-22) that's wrong: ⌘V/⌘C/⌘X only reach the
        // focused field's responder chain if the main menu has an item registered for the standard
        // `paste:`/`copy:`/`cut:` selectors with that key equivalent — without one, those shortcuts
        // silently do nothing anywhere in the app (right-click → Paste still worked throughout,
        // since that calls the responder directly, bypassing key-equivalent menu matching
        // entirely — which is exactly why this went unnoticed for a while). The dictation/emoji
        // extras that motivated removing the menu are suppressed via the two `UserDefaults` keys
        // below instead — Apple's own documented mechanism for exactly this — so ⌘V works without
        // bringing those back.
        UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")

        let editMenu = NSMenuItem()
        editMenu.submenu = NSMenu(title: String(localized: "Edit"))
        editMenu.submenu?.items = [
            .init(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"),
            {
                let item = NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
                item.keyEquivalentModifierMask = [.command, .shift]
                return item
            }(),
            .separator(),
            .init(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            .init(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            .init(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            .init(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]

        // View, Window, and Help menus stay removed. View's items (filter toggle, full screen,
        // play/pause, mute) duplicated controls already available in the UI, the status bar menu,
        // or the window's own full-screen button. Window's only item duplicated "Show Wallwright"
        // in the status bar menu. Help had nothing in it once the developer-only Debug tools were
        // moved behind a `#if DEBUG` build flag.

        // Main Menu
        let mainMenu = NSMenu()
        mainMenu.items = [
            appMenu,
            fileMenu,
            editMenu
        ]

        NSApplication.shared.mainMenu = mainMenu
    }

}

extension NSMenuItem {
    public convenience init(title: String, systemImage: String, action: Selector?, keyEquivalent: String) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)

    }
}
