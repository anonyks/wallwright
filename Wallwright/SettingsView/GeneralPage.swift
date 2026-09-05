//
//  GeneralPage.swift
//  Wallwright
//
//  Created by Haren on 2023/8/12.
//

import SwiftUI

struct GeneralPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @State private var isResetConfirming = false

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            // MARK: Automatic Startup
            Section {
                Toggle("Start with macOS", isOn: $viewModel.settings.autoStart)
            } header: {
                Label("Automatic Startup", systemImage: "star.fill")
            }
            // MARK: macOS
            Section {
                Toggle("Adjust Menu Bar Color", isOn: $viewModel.settings.adjustMenuBarTint)
            } header: {
                Label("macOS", systemImage: "apple.logo")
            }
            // MARK: Appearance
            // Clock overlay configuration lives entirely in its own quick-access popover (the
            // chevron next to the clock toggle in the tab bar) rather than duplicated here too —
            // same underlying settings either way, just one place to actually go looking for them.
            Section {
                Picker("Theme", selection: $viewModel.settings.appearance) {
                    Text("Light").tag(GSAppearance.light)
                    Text("Dark").tag(GSAppearance.dark)
                    Text("Auto").tag(GSAppearance.followSystem)
                }
            } header: {
                Label("Appearance", systemImage: "paintpalette.fill")
            }
            // MARK: Reset
            Section {
                HStack {
                    Text("Reset Config")
                    Spacer()
                    Button {
                        isResetConfirming = true
                    } label: {
                        Text("Reset").frame(width: 100)
                    }
                    .tint(Color.red)
                    .buttonStyle(.glassProminent)
                }
            } header: {
                Label("Reset", systemImage: "exclamationmark.triangle.fill")
            }
        }.formStyle(.grouped)
        // A single click on "Reset" used to wipe every setting instantly — all 5 configurable
        // global hotkeys, auto-start, clock overlay styling/position, every power-management
        // trigger, saved Steam credentials — with no way back. Same `.confirmationDialog` pattern
        // already used elsewhere in this app for other irreversible actions (e.g. removing a
        // wallpaper from the library).
        .confirmationDialog(
            "Reset all settings to default?",
            isPresented: $isResetConfirming,
            titleVisibility: .visible
        ) {
            Button("Reset Config", role: .destructive) {
                viewModel.settings = GlobalSettings()
            }
        } message: {
            Text("This clears every hotkey, the clock overlay's styling and position, power-management triggers, and saved Steam credentials. This can't be undone.")
        }
    }
}
