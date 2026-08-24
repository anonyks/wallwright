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
    @objc func jumpToPerformance() {
        self.globalSettingsViewModel.selection = 0
    }

    @objc func jumpToGeneral() {
        self.globalSettingsViewModel.selection = 1
    }

    @objc func jumpToAbout() {
        self.globalSettingsViewModel.selection = 2
    }

    @objc func jumpToHotkeys() {
        self.globalSettingsViewModel.selection = 3
    }
}

struct SettingsView: View {
    @EnvironmentObject var viewModel: GlobalSettingsViewModel

    var body: some View {
        VStack {
            Group {
                switch viewModel.selection {
                case 0:
                    PerformancePage(globalSettings: viewModel)
                case 1:
                    GeneralPage(globalSettings: viewModel)
                case 2:
                    AboutUsView()
                case 3:
                    HotkeysPage(globalSettings: viewModel)
                default:
                    fatalError()
                }
            }
            .frame(minHeight: 400, maxHeight: 800)
            
            
            HStack {
                if let savedSettings = GlobalSettingsViewModel.loadPersisted(), viewModel.settings != savedSettings {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.yellow)
                    Text("Edited")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.save()
                    AppDelegate.shared.settingsWindow.close()
                } label: {
                    Text("OK").frame(width: 50)
                }
                .buttonStyle(.glassProminent)
                Button {
                    /*here should be a call of viewModel.reset() but I move it to the delegate */
                    AppDelegate.shared.settingsWindow.close()
                } label: {
                    Text("Cancel").frame(width: 50)
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
        [SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.hotkeys, SettingsToolbarIdentifiers.about]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.hotkeys, SettingsToolbarIdentifiers.about]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [SettingsToolbarIdentifiers.performance, SettingsToolbarIdentifiers.general, SettingsToolbarIdentifiers.hotkeys, SettingsToolbarIdentifiers.about]
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
            toolbarItem.image = NSImage(systemSymbolName: "person.3", accessibilityDescription: nil)
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
                viewModel.selection = 2
                return viewModel
            }())
            .frame(width: 500, height: 600)
    }
}


