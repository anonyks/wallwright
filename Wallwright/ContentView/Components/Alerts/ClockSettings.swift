//
//  ClockSettings.swift
//  Wallwright
//
//  In-app quick access to the desktop clock overlay's position/size/format, mirroring the same
//  settings exposed in Settings → General (both read/write the same GlobalSettings, so either
//  place stays in sync with the other).
//

import SwiftUI

struct ClockSettings: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var globalSettingsViewModel: GlobalSettingsViewModel

    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self.globalSettingsViewModel = AppDelegate.shared.globalSettingsViewModel
    }

    var body: some View {
        VStack(spacing: 12) {
            // Kept outside the ScrollView below so it's always visible and reachable, no matter
            // how tall the settings content grows — previously the whole sheet was a fixed-size
            // VStack, so adding more rows (color, per-line sizes) pushed content past the bottom
            // edge with no way to scroll to it or even see the close button reliably.
            ZStack {
                Text("Clock Overlay")
                    .font(.largeTitle.bold())
                HStack {
                    Spacer()
                    Button {
                        viewModel.isClockSettingsReveal = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("An optional day/date/time overlay drawn over your desktop wallpaper.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(spacing: 12) {
                    Toggle("Show Clock Overlay", isOn: $globalSettingsViewModel.settings.showClockOverlay)
                        .toggleStyle(.switch)

                    if globalSettingsViewModel.settings.showClockOverlay {
                        Divider()

                        Picker("Format", selection: $globalSettingsViewModel.settings.clockDayFont) {
                            ForEach(GSClockFormat.allCases) { format in
                                Text(format.label).tag(format)
                            }
                        }

                        Picker("Alignment", selection: $globalSettingsViewModel.settings.clockTextAlignment) {
                            ForEach(GSClockTextAlignment.allCases) { alignment in
                                Text(alignment.label).tag(alignment)
                            }
                        }

                        ClockColorPicker(settings: $globalSettingsViewModel.settings)

                        HStack {
                            Text("Opacity")
                            Slider(value: $globalSettingsViewModel.settings.clockOpacity, in: 0...1, step: 0.05)
                            Text(globalSettingsViewModel.settings.clockOpacity, format: .percent.precision(.fractionLength(0)))
                                .frame(width: 44, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Toggle("Draggable", isOn: $globalSettingsViewModel.settings.clockDraggable)
                                .toggleStyle(.switch)
                            Spacer()
                            if let origins = globalSettingsViewModel.settings.clockCustomOrigins, !origins.isEmpty {
                                Button("Reset Position") {
                                    globalSettingsViewModel.settings.clockCustomOrigins = nil
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                        if globalSettingsViewModel.settings.clockDraggable {
                            Text("Drag the overlay on your desktop to move it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Day Size")
                            Slider(value: $globalSettingsViewModel.settings.clockDayFontSize, in: 24...200, step: 1)
                            TextField("", value: $globalSettingsViewModel.settings.clockDayFontSize, format: .number)
                                .frame(width: 56)
                        }
                        HStack {
                            Text("Date Size")
                            Slider(value: $globalSettingsViewModel.settings.clockDateFontSize, in: 8...100, step: 1)
                            TextField("", value: $globalSettingsViewModel.settings.clockDateFontSize, format: .number)
                                .frame(width: 56)
                        }
                        HStack {
                            Text("Time Size")
                            Slider(value: $globalSettingsViewModel.settings.clockTimeFontSize, in: 8...100, step: 1)
                            TextField("", value: $globalSettingsViewModel.settings.clockTimeFontSize, format: .number)
                                .frame(width: 56)
                        }

                        if globalSettingsViewModel.settings.clockDayFont == .summit {
                            HStack {
                                Text("Line Length")
                                Slider(value: $globalSettingsViewModel.settings.clockSummitLineLength, in: 10...200, step: 1)
                                TextField("", value: $globalSettingsViewModel.settings.clockSummitLineLength, format: .number)
                                    .frame(width: 56)
                            }
                        }

                        Toggle("Show Seconds", isOn: $globalSettingsViewModel.settings.clockShowSeconds)
                        Toggle("24-Hour Time", isOn: $globalSettingsViewModel.settings.clockUse24HourTime)
                    }
                }
                .padding()
                .popupCardStyle()
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
    }
}
