//
//  HotkeysPage.swift
//  Wallwright
//

import SwiftUI

private struct HotkeyRow: View {
    let title: String
    @Binding var hotkey: Hotkey?
    let others: [(hotkey: Hotkey?, label: String)]

    private var conflictLabel: String? {
        guard let hotkey else { return nil }
        for other in others {
            if let otherHotkey = other.hotkey, hotkey.clashes(with: otherHotkey) {
                return other.label
            }
        }
        return ReservedShortcuts.conflict(character: hotkey.characters, modifiers: hotkey.nsModifierFlags)
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let conflictLabel {
                Label(String(format: String(localized: "Already used by \"%@\""), conflictLabel), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            HotkeyRecorderView(hotkey: $hotkey)
                .frame(width: 150, height: 22)
            Button {
                hotkey = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(hotkey == nil)
        }
    }
}

struct HotkeysPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            Section {
                HotkeyRow(
                    title: String(localized: "Play/Pause Wallpaper"),
                    hotkey: $viewModel.settings.pauseHotkey,
                    others: [
                        (viewModel.settings.muteHotkey, String(localized: "Mute/Unmute Wallpaper")),
                        (viewModel.settings.clockHotkey, String(localized: "Show/Hide Clock Overlay")),
                        (viewModel.settings.playlistNextHotkey, String(localized: "Next Wallpaper")),
                        (viewModel.settings.playlistPreviousHotkey, String(localized: "Previous Playlist Item")),
                    ]
                )
                // Explicit, stable ids on every row — without them, Form's row-reuse on macOS can
                // hand a row's HotkeyRecorderView another row's underlying NSView instance
                // (confirmed live: the mute field rendered the pause field's combo).
                .id("pauseHotkeyRow")
                HotkeyRow(
                    title: String(localized: "Mute/Unmute Wallpaper"),
                    hotkey: $viewModel.settings.muteHotkey,
                    others: [
                        (viewModel.settings.pauseHotkey, String(localized: "Play/Pause Wallpaper")),
                        (viewModel.settings.clockHotkey, String(localized: "Show/Hide Clock Overlay")),
                        (viewModel.settings.playlistNextHotkey, String(localized: "Next Wallpaper")),
                        (viewModel.settings.playlistPreviousHotkey, String(localized: "Previous Playlist Item")),
                    ]
                )
                .id("muteHotkeyRow")
                HotkeyRow(
                    title: String(localized: "Show/Hide Clock Overlay"),
                    hotkey: $viewModel.settings.clockHotkey,
                    others: [
                        (viewModel.settings.pauseHotkey, String(localized: "Play/Pause Wallpaper")),
                        (viewModel.settings.muteHotkey, String(localized: "Mute/Unmute Wallpaper")),
                        (viewModel.settings.playlistNextHotkey, String(localized: "Next Wallpaper")),
                        (viewModel.settings.playlistPreviousHotkey, String(localized: "Previous Playlist Item")),
                    ]
                )
                .id("clockHotkeyRow")
                // Advances the active playlist when one's running; otherwise cycles to the next
                // wallpaper in the library — same hotkey either way, so it's always useful. See
                // AppDelegate.skipToNextPlaylistItem() for the actual fallback logic. No plain
                // "previous" counterpart for the non-playlist case, only Next.
                HotkeyRow(
                    title: String(localized: "Next Wallpaper"),
                    hotkey: $viewModel.settings.playlistNextHotkey,
                    others: [
                        (viewModel.settings.pauseHotkey, String(localized: "Play/Pause Wallpaper")),
                        (viewModel.settings.muteHotkey, String(localized: "Mute/Unmute Wallpaper")),
                        (viewModel.settings.clockHotkey, String(localized: "Show/Hide Clock Overlay")),
                        (viewModel.settings.playlistPreviousHotkey, String(localized: "Previous Playlist Item")),
                    ]
                )
                .id("playlistNextHotkeyRow")
                HotkeyRow(
                    title: String(localized: "Previous Playlist Item"),
                    hotkey: $viewModel.settings.playlistPreviousHotkey,
                    others: [
                        (viewModel.settings.pauseHotkey, String(localized: "Play/Pause Wallpaper")),
                        (viewModel.settings.muteHotkey, String(localized: "Mute/Unmute Wallpaper")),
                        (viewModel.settings.clockHotkey, String(localized: "Show/Hide Clock Overlay")),
                        (viewModel.settings.playlistNextHotkey, String(localized: "Next Wallpaper")),
                    ]
                )
                .id("playlistPreviousHotkeyRow")
            } header: {
                Label("Hotkeys", systemImage: "keyboard")
            } footer: {
                Text("These work from anywhere — the app doesn't need to be frontmost. Click a field and press a key combo to change it; a combo needs at least one modifier key.")
            }
        }
        .formStyle(.grouped)
    }
}
