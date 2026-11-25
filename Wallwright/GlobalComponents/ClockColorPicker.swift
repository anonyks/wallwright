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
    @State private var isDynamicMatchPopoverPresented = false

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
            } else if option == .dynamicWallpaperMatch {
                isDynamicMatchPopoverPresented = true
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
                    } else if option == .dynamicWallpaperMatch {
                        Image(systemName: "photo.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .secondary)
                            .font(.system(size: 11))
                            .offset(x: 3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option == .dynamicWallpaperMatch ? "Match Wallpaper" : option.rawValue)
        .help(option == .dynamicWallpaperMatch ? "Follows the current wallpaper's own extracted accent colors" : "")

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
        } else if option == .dynamicWallpaperMatch {
            button.popover(isPresented: $isDynamicMatchPopoverPresented) {
                dynamicMatchEditor
            }
        } else {
            button
        }
    }

    private var dynamicMatchEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Match Wallpaper")
                .font(.headline)
            Text("Auto-extracted from the current wallpaper. Adjust to save a tweak just for this wallpaper.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let wallpaperId = PaletteExporter.current?.wallpaperId {
                ColorPicker("Start", selection: dynamicMatchColorBinding(wallpaperId: wallpaperId, isStart: true), supportsOpacity: false)
                ColorPicker("End", selection: dynamicMatchColorBinding(wallpaperId: wallpaperId, isStart: false), supportsOpacity: false)

                if settings.clockDynamicMatchOverrides?[wallpaperId] != nil {
                    Button("Reset to Auto") {
                        settings.clockDynamicMatchOverrides?.removeValue(forKey: wallpaperId)
                    }
                    .font(.caption)
                }
            } else {
                Text("No wallpaper colors extracted yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 240)
    }

    /// Reads/writes `settings.clockDynamicMatchOverrides[wallpaperId]` — seeding a brand new
    /// entry from the live `PaletteExporter.current` extraction (accent/vibrant) on the first
    /// edit, so adjusting only one of the two wells doesn't leave the other defaulting to black.
    private func dynamicMatchColorBinding(wallpaperId: String, isStart: Bool) -> Binding<Color> {
        Binding(
            get: {
                if let override = settings.clockDynamicMatchOverrides?[wallpaperId] {
                    return (isStart ? override.start : override.end).color
                }
                guard let palette = PaletteExporter.current else { return .white }
                return Color(nsColor: isStart ? palette.accent : palette.vibrant)
            },
            set: { newColor in
                var overrides = settings.clockDynamicMatchOverrides ?? [:]
                var entry = overrides[wallpaperId] ?? seedOverride(wallpaperId: wallpaperId)
                if isStart { entry.start = GSColor(newColor) } else { entry.end = GSColor(newColor) }
                overrides[wallpaperId] = entry
                settings.clockDynamicMatchOverrides = overrides
            }
        )
    }

    private func seedOverride(wallpaperId: String) -> GSWallpaperGradientOverride {
        guard let palette = PaletteExporter.current, palette.wallpaperId == wallpaperId else {
            return GSWallpaperGradientOverride(start: .black, end: .black, horizontal: false)
        }
        return GSWallpaperGradientOverride(
            start: GSColor(Color(nsColor: palette.accent)), end: GSColor(Color(nsColor: palette.vibrant)), horizontal: false
        )
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
        if option == .dynamicWallpaperMatch {
            // Same resolution order as `resolvedClockGradient` itself: a saved per-wallpaper
            // tweak first, then the live extraction, then a neutral gray-to-white placeholder
            // (distinct from any fixed preset) before the first extraction completes.
            if let wallpaperId = PaletteExporter.current?.wallpaperId,
               let override = settings.clockDynamicMatchOverrides?[wallpaperId] {
                return AnyShapeStyle(LinearGradient(colors: [override.start.color, override.end.color], startPoint: .leading, endPoint: .trailing))
            }
            guard let palette = PaletteExporter.current else {
                return AnyShapeStyle(LinearGradient(colors: [.gray, .white], startPoint: .leading, endPoint: .trailing))
            }
            return AnyShapeStyle(LinearGradient(
                colors: [Color(nsColor: palette.accent), Color(nsColor: palette.vibrant)],
                startPoint: .leading, endPoint: .trailing
            ))
        }
        if let (start, end) = option.gradientColors {
            let (startPoint, endPoint): (UnitPoint, UnitPoint) = option.gradientIsHorizontal ? (.leading, .trailing) : (.top, .bottom)
            return AnyShapeStyle(LinearGradient(colors: [Color(nsColor: start), Color(nsColor: end)], startPoint: startPoint, endPoint: endPoint))
        }
        return AnyShapeStyle(option.color)
    }
}
