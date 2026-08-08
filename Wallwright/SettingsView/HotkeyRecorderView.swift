//
//  HotkeyRecorderView.swift
//  Wallwright
//
//  A click-to-record control for capturing a Hotkey — click it, press a modifier+key combo, done.
//  Requires at least one modifier key so it never swallows a bare keystroke meant for a text field
//  elsewhere in the window.
//

import Cocoa
import SwiftUI

final class HotkeyCaptureView: NSView {
    var hotkey: Hotkey? {
        didSet { updateLabel() }
    }
    var onCapture: ((Hotkey) -> Void)?

    private var isRecording = false {
        didSet { updateLabel() }
    }
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlColor.cgColor

        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Escape
            isRecording = false
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }

        let captured = Hotkey(keyCode: event.keyCode, modifiers: modifiers.rawValue, characters: chars.uppercased())
        isRecording = false
        onCapture?(captured)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    private func updateLabel() {
        layer?.borderWidth = isRecording ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        if isRecording {
            label.stringValue = String(localized: "Press keys… (Esc to cancel)")
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = hotkey?.displayString ?? String(localized: "Click to record")
            label.textColor = hotkey == nil ? .secondaryLabelColor : .labelColor
        }
    }
}

struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var hotkey: Hotkey?

    func makeNSView(context: Context) -> HotkeyCaptureView {
        let view = HotkeyCaptureView(frame: .zero)
        view.hotkey = hotkey
        view.onCapture = { hotkey = $0 }
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureView, context: Context) {
        nsView.hotkey = hotkey
        nsView.onCapture = { hotkey = $0 }
    }
}
