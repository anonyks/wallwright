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

        // Edit, View, Window, and Help menus were removed. Edit's standard Cut/Copy/Paste/Undo
        // items triggered macOS's automatic Edit-menu extras (Start Dictation, Emoji & Symbols,
        // and an AutoFill submenu offering Contact/Passwords/Credit Card autofill) — none of
        // which make sense for an app with no real text-document editing, just a couple of search
        // and title fields that already get standard Cut/Copy/Paste for free from the system
        // without needing this menu to declare it. View's items (filter toggle, full screen,
        // play/pause, mute) duplicated controls already available in the UI, the status bar menu,
        // or the window's own full-screen button. Window's only item duplicated "Show Wallwright"
        // in the status bar menu. Help had nothing in it once the developer-only Debug tools were
        // moved behind a `#if DEBUG` build flag.

        // Main Menu
        let mainMenu = NSMenu()
        mainMenu.items = [
            appMenu,
            fileMenu
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
