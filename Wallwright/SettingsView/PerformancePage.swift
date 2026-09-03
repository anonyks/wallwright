//
//  PerformancePage.swift
//  Wallwright
//
//  Created by Haren on 2023/8/12.
//

import SwiftUI

struct PerformancePage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel

    @State private var usageSnapshot: SystemUsageMonitor.Snapshot?

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    if let usage = usageSnapshot {
                        Text("CPU")
                        Text(String(format: "%.1f%%", usage.cpuPercent)).foregroundStyle(.secondary)
                        Divider().frame(height: 12)
                        Text("Memory")
                        Text(String(format: "%.0f MB", usage.memoryMB)).foregroundStyle(.secondary)
                    } else {
                        Text("Unavailable").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        sampleUsage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .onAppear {
                    sampleUsage()
                }
            } header: {
                Label("Current System Usage", systemImage: "gauge.with.dots.needle.50percent")
            } footer: {
                Text("Sampled on demand — not tracked continuously in the background.")
            }
            Section {
                Picker("Other Application Focused:", selection: $viewModel.settings.otherApplicationFocused) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Mute").tag(GSPlayback.mute)
                    Text("Pause").tag(GSPlayback.pause)
                }

                Picker("Other Application Fullscreen:", selection: $viewModel.settings.otherApplicationFullscreen) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }

                Picker("Other Application Playing Audio:", selection: $viewModel.settings.otherApplicationPlayingAudio) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Mute").tag(GSPlayback.mute)
                    Text("Pause").tag(GSPlayback.pause)
                }

                Picker("Display asleep", selection: $viewModel.settings.displayAsleep) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }
                
                Picker("Laptop on battery", selection: $viewModel.settings.laptopOnBattery) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }

                Picker("Low power conditions", selection: $viewModel.settings.lowPowerConditions) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }
                .help("Thermal throttling or battery under 20%")
            } header: {
                Label("Playback", systemImage: "play.fill")
            }
        }
        .formStyle(.grouped)
    }

    /// `SystemUsageMonitor.sample()`'s CPU reading spans several seconds of wall-clock time, so
    /// calling it directly from `.onAppear`/a button action would block the main thread right as
    /// this page appeared or the refresh button was clicked. Dispatching it off-main and updating
    /// state on completion keeps the page itself responsive; `usageSnapshot` starting `nil` already
    /// reads as "Unavailable" while the first sample is still in flight, so no extra loading state
    /// needed. The short head start before the sample's own window begins mirrors StatusBar's menu
    /// — this page's own `.onAppear` layout/draw work would otherwise still be finishing up right as
    /// `getrusage` took its first snapshot, showing up as a small, misleading, self-inflicted spike.
    private func sampleUsage() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            let snapshot = SystemUsageMonitor.sample()
            DispatchQueue.main.async {
                usageSnapshot = snapshot
            }
        }
    }
}
