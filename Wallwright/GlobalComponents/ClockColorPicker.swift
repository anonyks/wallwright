//
//  ClockColorPicker.swift
//  Wallwright
//
//  A horizontally-scrollable row of tappable color swatches for the clock overlay's text color —
//  shared between the Settings → General page and the in-app Clock Overlay quick-access sheet.
//  Gradients (including Custom, which follows the wallpaper by default) come first, solids after
//  — see `GSClockColor`'s declaration order, which `allCases` follows.
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
        .help(option == .custom ? "Follows the current wallpaper's own colors — tap to fine-tune or pick your own" : "")

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
            Text("Custom")
                .font(.headline)
            Text("Follows the current wallpaper's own colors. Adjust to save a tweak just for this wallpaper.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let wallpaperId = PaletteExporter.current?.wallpaperId {
                Picker("Direction", selection: customGradientDirectionBinding(wallpaperId: wallpaperId)) {
                    Text("Horizontal").tag(true)
                    Text("Vertical").tag(false)
                }
                .pickerStyle(.segmented)

                ColorPicker("Start", selection: customGradientColorBinding(wallpaperId: wallpaperId, isStart: true), supportsOpacity: false)
                ColorPicker("End", selection: customGradientColorBinding(wallpaperId: wallpaperId, isStart: false), supportsOpacity: false)

                if settings.clockCustomGradientOverrides?[wallpaperId] != nil {
                    Button("Reset to Auto") {
                        settings.clockCustomGradientOverrides?.removeValue(forKey: wallpaperId)
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

    /// Reads/writes `settings.clockCustomGradientOverrides[wallpaperId]` — seeding a brand new
    /// entry from the same WCAG-guarded colors actually being rendered right now (see
    /// `GlobalSettings.wcagGuardedDynamicGradient`, not the raw accent/vibrant extraction) on the
    /// first edit, so adjusting only one of the two wells doesn't leave the other defaulting to
    /// black, and the editor opens showing what's already on screen rather than something else.
    private func customGradientColorBinding(wallpaperId: String, isStart: Bool) -> Binding<Color> {
        Binding(
            get: {
                if let override = settings.clockCustomGradientOverrides?[wallpaperId] {
                    return (isStart ? override.start : override.end).color
                }
                guard let palette = PaletteExporter.current else { return .white }
                let guarded = GlobalSettings.wcagGuardedDynamicGradient(for: palette)
                return Color(nsColor: isStart ? guarded.start : guarded.end)
            },
            set: { newColor in
                var overrides = settings.clockCustomGradientOverrides ?? [:]
                var entry = overrides[wallpaperId] ?? seedOverride(wallpaperId: wallpaperId)
                if isStart { entry.start = GSColor(newColor) } else { entry.end = GSColor(newColor) }
                overrides[wallpaperId] = entry
                settings.clockCustomGradientOverrides = overrides
            }
        )
    }

    /// Same read/seed/write pattern as `customGradientColorBinding`, for the override's
    /// `horizontal` flag instead of its colors — lets direction be tweaked and saved per
    /// wallpaper too, not just left at whatever the live gradient's own default is.
    private func customGradientDirectionBinding(wallpaperId: String) -> Binding<Bool> {
        Binding(
            get: {
                if let override = settings.clockCustomGradientOverrides?[wallpaperId] {
                    return override.horizontal
                }
                guard let palette = PaletteExporter.current else { return true }
                return GlobalSettings.wcagGuardedDynamicGradient(for: palette).horizontal
            },
            set: { newValue in
                var overrides = settings.clockCustomGradientOverrides ?? [:]
                var entry = overrides[wallpaperId] ?? seedOverride(wallpaperId: wallpaperId)
                entry.horizontal = newValue
                overrides[wallpaperId] = entry
                settings.clockCustomGradientOverrides = overrides
            }
        )
    }

    /// Carries over the live gradient's own direction (not a hardcoded value) — `.custom`'s live
    /// wallpaper match always resolves horizontal (see `wcagGuardedDynamicGradient`'s own doc
    /// comment on why), so a freshly-created override should keep that, not silently flip back to
    /// vertical the moment the user touches either color well.
    private func seedOverride(wallpaperId: String) -> GSWallpaperGradientOverride {
        guard let palette = PaletteExporter.current, palette.wallpaperId == wallpaperId else {
            return GSWallpaperGradientOverride(start: .black, end: .black, horizontal: false)
        }
        let guarded = GlobalSettings.wcagGuardedDynamicGradient(for: palette)
        return GSWallpaperGradientOverride(
            start: GSColor(Color(nsColor: guarded.start)), end: GSColor(Color(nsColor: guarded.end)), horizontal: guarded.horizontal
        )
    }

    private func swatchFill(for option: GSClockColor) -> AnyShapeStyle {
        if option == .custom {
            // Same resolution order as `resolvedClockGradient` itself: a saved per-wallpaper
            // tweak first, then the live WCAG-guarded extraction, then a neutral gray-to-white
            // placeholder (distinct from any fixed preset) before the first extraction completes.
            if let wallpaperId = PaletteExporter.current?.wallpaperId,
               let override = settings.clockCustomGradientOverrides?[wallpaperId] {
                return AnyShapeStyle(LinearGradient(colors: [override.start.color, override.end.color], startPoint: .leading, endPoint: .trailing))
            }
            guard let palette = PaletteExporter.current else {
                return AnyShapeStyle(LinearGradient(colors: [.gray, .white], startPoint: .leading, endPoint: .trailing))
            }
            let guarded = GlobalSettings.wcagGuardedDynamicGradient(for: palette)
            return AnyShapeStyle(LinearGradient(
                colors: [Color(nsColor: guarded.start), Color(nsColor: guarded.end)],
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
