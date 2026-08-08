//
//  GlobalHotkeyManager.swift
//  Wallwright
//
//  Registers the user-configurable hotkeys (pause/unpause, mute/unmute, clock overlay) so they fire no matter
//  which app is frontmost — the whole point of a wallpaper hotkey is that you're never actually
//  looking at Wallwright when you press it. Uses the old Carbon RegisterEventHotKey API rather than
//  an NSEvent global monitor: it's still fully functional on modern macOS and, unlike a global
//  monitor, needs no Accessibility/Input Monitoring permission — one less permission prompt after
//  the TCC pain already hit this session.
//

import Carbon.HIToolbox
import Cocoa

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private static let signature: OSType = 0x574C_5752 // 'WLWR'
    private enum ID: UInt32 { case pause = 1, mute = 2, clock = 3, playlistNext = 4, playlistPrevious = 5 }

    private var pauseRef: EventHotKeyRef?
    private var muteRef: EventHotKeyRef?
    private var clockRef: EventHotKeyRef?
    private var playlistNextRef: EventHotKeyRef?
    private var playlistPreviousRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func updatePauseHotkey(_ hotkey: Hotkey?) {
        if let pauseRef { UnregisterEventHotKey(pauseRef) }
        pauseRef = register(hotkey, id: .pause)
    }

    func updateMuteHotkey(_ hotkey: Hotkey?) {
        if let muteRef { UnregisterEventHotKey(muteRef) }
        muteRef = register(hotkey, id: .mute)
    }

    func updateClockHotkey(_ hotkey: Hotkey?) {
        if let clockRef { UnregisterEventHotKey(clockRef) }
        clockRef = register(hotkey, id: .clock)
    }

    func updatePlaylistNextHotkey(_ hotkey: Hotkey?) {
        if let playlistNextRef { UnregisterEventHotKey(playlistNextRef) }
        playlistNextRef = register(hotkey, id: .playlistNext)
    }

    func updatePlaylistPreviousHotkey(_ hotkey: Hotkey?) {
        if let playlistPreviousRef { UnregisterEventHotKey(playlistPreviousRef) }
        playlistPreviousRef = register(hotkey, id: .playlistPrevious)
    }

    private func register(_ hotkey: Hotkey?, id: ID) -> EventHotKeyRef? {
        guard let hotkey else { return nil }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            print("GlobalHotkeyManager: failed to register hotkey for \(id): OSStatus \(status)")
            return nil
        }
        return ref
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            DispatchQueue.main.async {
                GlobalHotkeyManager.shared.handle(id: hotKeyID.id)
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    private func handle(id: UInt32) {
        switch ID(rawValue: id) {
        case .pause: AppDelegate.shared.togglePause()
        case .mute: AppDelegate.shared.toggleMute()
        case .clock: AppDelegate.shared.toggleClockOverlay()
        case .playlistNext: AppDelegate.shared.skipToNextPlaylistItem()
        case .playlistPrevious: AppDelegate.shared.skipToPreviousPlaylistItem()
        case nil: break
        }
    }
}
