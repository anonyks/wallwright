//
//  ClockColorPicker.swift
//  Wallwright
//
//  A horizontally-scrollable row of tappable color swatches for the clock overlay's text color —
//  shared between the Settings → General page and the in-app Clock Overlay quick-access sheet.
//  Gradients (including the user-built one) come first, solids after — see `GSClockColor`'s
//  declaration order, which `allCases` follows.
//

import SwiftUI

struct ClockColorPicker: View {
    @Binding var settings: GlobalSettings

    @State private var isCustomGradientPopoverPresented = false

    var body: some View {
        HStack {
            Text("Color")
            Spacer()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(GSClockColor.allCases) { option in
                        swatch(for: option)
                    }
                }
                // A couple points of vertical padding so the selection ring isn't clipped by the
                // ScrollView's own bounds.
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func swatch(for option: GSClockColor) -> some View {
        // A real Button, not a `.onTapGesture` — same class of gap as the wallpaper grid cards had:
        // a tap gesture on a plain shape has no focus or VoiceOver semantics, so this swatch was
        // unreachable via Tab/Full Keyboard Access despite already carrying an `.accessibilityLabel`
        // that could never actually be read in context.
        let button = Button {
            settings.clockColor = option
            if option == .custom {
                isCustomGradientPopoverPresented = true
            }
        } label: {
            Circle()
                .fill(swatchFill(for: option))
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(.secondary.opacity(0.35), lineWidth: 1))
                .overlay(
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(-2)
                        .opacity(settings.clockColor == option ? 1 : 0)
                )
                .overlay(alignment: .bottomTrailing) {
                    if option == .custom {
                        Image(systemName: "pencil.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .secondary)
                            .font(.system(size: 11))
                            .offset(x: 3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.rawValue)

        // Only the custom swatch actually needs a popover, but this used to attach one to every
        // swatch in the ForEach (gated on `option == .custom` inside the binding itself), so N
        // separate popover declarations existed at once sharing overlapping state. That's very
        // likely why clicking outside the popover didn't reliably close it, confirmed live
        // (2026-08-24) as a real bug report. A single popover declared only where it's actually
        // used behaves correctly.
        if option == .custom {
            button.popover(isPresented: $isCustomGradientPopoverPresented) {
                customGradientEditor
            }
        } else {
            button
        }
    }

    private var customGradientEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Gradient")
                .font(.headline)

            Picker("Direction", selection: $settings.clockCustomGradientHorizontal) {
                Text("Vertical").tag(false)
                Text("Horizontal").tag(true)
            }
            .pickerStyle(.segmented)

            ColorPicker("Start", selection: gsColorBinding(\.clockCustomGradientStart), supportsOpacity: false)
            ColorPicker("End", selection: gsColorBinding(\.clockCustomGradientEnd), supportsOpacity: false)
        }
        .padding()
        .frame(width: 240)
    }

    /// `ColorPicker` binds to SwiftUI `Color`, but the underlying setting is the Codable `GSColor`
    /// — converts on the way in/out rather than storing a second, redundant `Color` copy anywhere.
    private func gsColorBinding(_ keyPath: WritableKeyPath<GlobalSettings, GSColor>) -> Binding<Color> {
        Binding(
            get: { settings[keyPath: keyPath].color },
            set: { settings[keyPath: keyPath] = GSColor($0) }
        )
    }

    private func swatchFill(for option: GSClockColor) -> AnyShapeStyle {
        if option == .custom {
            let (startPoint, endPoint): (UnitPoint, UnitPoint) = settings.clockCustomGradientHorizontal ? (.leading, .trailing) : (.top, .bottom)
            return AnyShapeStyle(LinearGradient(
                colors: [settings.clockCustomGradientStart.color, settings.clockCustomGradientEnd.color],
                startPoint: startPoint, endPoint: endPoint
            ))
        }
        if let (start, end) = option.gradientColors {
            let (startPoint, endPoint): (UnitPoint, UnitPoint) = option.gradientIsHorizontal ? (.leading, .trailing) : (.top, .bottom)
            return AnyShapeStyle(LinearGradient(colors: [Color(nsColor: start), Color(nsColor: end)], startPoint: startPoint, endPoint: endPoint))
        }
        return AnyShapeStyle(option.color)
    }
}
