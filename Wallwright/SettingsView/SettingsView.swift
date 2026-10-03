//
//  SettingsView.swift
//  Wallwright
//
//  Created by Haren on 2023/6/5.
//

import Cocoa
import SwiftUI

protocol SettingsPage: View {
    var viewModel: GlobalSettingsViewModel { get set }
    
    init(globalSettings: GlobalSettingsViewModel)
}

extension AppDelegate {
    @objc func jumpToGeneral() {
        self.globalSettingsViewModel.selection = 0
    }

    @objc func jumpToPerformance() {
        self.globalSettingsViewModel.selection = 1
    }

    @objc func jumpToHotkeys() {
        self.globalSettingsViewModel.selection = 2
    }

    @objc func jumpToAbout() {
        self.globalSettingsViewModel.selection = 3
    }
}

struct SettingsView: View {
    @EnvironmentObject var viewModel: GlobalSettingsViewModel

    var body: some View {
        ZStack {
            // Same real desktop vibrancy as the main library window — see `WindowGlassBackground`'s
            // own doc comment. Only visible once `AppDelegate.setSettingsWindow` has made this
            // window non-opaque with a `.clear` background too. "Off" paints over the same clear
            // window rather than reconfiguring `isOpaque` at runtime — see `ContentView`'s identical
            // comment for why.
            if viewModel.settings.windowVibrancy {
                WindowGlassBackground()
                    .ignoresSafeArea()
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
            settingsContent
        }
    }

    private var settingsContent: some View {
        VStack {
            Group {
                switch viewModel.selection {
                case 0:
                    GeneralPage(globalSettings: viewModel)
                case 1:
                    PerformancePage(globalSettings: viewModel)
                case 2:
                    HotkeysPage(globalSettings: viewModel)
                case 3:
                    AboutUsView()
                default:
                    fatalError()
                }
            }
            .frame(minHeight: 400, maxHeight: 800)

            HStack {
                Spacer()
                Button {
                    AppDelegate.shared.settingsWindow.close()
                } label: {
                    Text("Close").frame(width: 60)
                }
                .buttonStyle(.glass)
            }
            .padding(20)
        }
        .frame(minWidth: 500)
    }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.hotkeys, SettingsToolbarIdentifiers.about]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.hotkeys, SettingsToolbarIdentifiers.about]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.hotkeys, SettingsToolbarIdentifiers.about]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case SettingsToolbarIdentifiers.performance:
            toolbarItem.action = #selector(jumpToPerformance)
            toolbarItem.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
            toolbarItem.label = String(localized: "Performance")

        case SettingsToolbarIdentifiers.general:
            toolbarItem.action = #selector(jumpToGeneral)
            toolbarItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            toolbarItem.label = String(localized: "General")

        case SettingsToolbarIdentifiers.hotkeys:
            toolbarItem.action = #selector(jumpToHotkeys)
            toolbarItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
            toolbarItem.label = String(localized: "Hotkeys")

        case SettingsToolbarIdentifiers.about:
            toolbarItem.action = #selector(jumpToAbout)
            toolbarItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            toolbarItem.label = String(localized: "About")

        default:
            fatalError()
        }
        
        toolbarItem.isBordered = false
        
        return toolbarItem
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject({ () -> GlobalSettingsViewModel in 
                let viewModel = GlobalSettingsViewModel()
                viewModel.selection = 3
                return viewModel
            }())
            .frame(width: 500, height: 600)
    }
}


