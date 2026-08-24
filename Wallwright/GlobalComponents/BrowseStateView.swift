//
//  BrowseStateView.swift
//  Wallwright
//
//  A centered icon + message, with an optional retry button, for a browse tab's
//  load-failed or no-results state.
//

import SwiftUI

struct BrowseStateView: View {
    let icon: String
    let message: String
    var retryTitle: String = "Retry"
    var retryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retryAction {
                Button(retryTitle, action: retryAction)
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
