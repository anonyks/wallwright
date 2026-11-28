//
//  DownloadProgressView.swift
//  Wallwright
//
//  A browse card's download progress, shared by every source.
//

import SwiftUI

/// One download's progress, in an object of its own so that only the bar showing it redraws as it
/// moves. Held in a source model's published state, each step rebuilt that source's whole grid,
/// which made scrolling during a download stutter.
@MainActor
final class DownloadProgress: ObservableObject {
    /// Nil when the server gave no length.
    @Published private(set) var fraction: Double?

    func update(_ fraction: Double?) {
        self.fraction = fraction
    }
}

/// By identity: moving progress leaves a source's `downloadState` unchanged.
extension DownloadProgress: Equatable {
    nonisolated static func == (lhs: DownloadProgress, rhs: DownloadProgress) -> Bool { lhs === rhs }
}

struct DownloadProgressView: View {
    @ObservedObject var progress: DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
