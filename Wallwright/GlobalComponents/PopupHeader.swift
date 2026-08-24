//
//  PopupHeader.swift
//  Wallwright
//
//  The centered-title + top-right close button was duplicated identically across DisplaySettings,
//  ClockSettings, PlaylistSettings, and EditWallpaperSheet, while the three import sheets
//  (YouTube/Steam/Direct URL) used a smaller, left-aligned title with no close button at all —
//  same popup shell, two different visual weights. One shared header fixes both: every popup now
//  reads at the same size, and every popup gets the same dismiss affordance, not just click-outside.
//

import SwiftUI

struct PopupHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.largeTitle.bold())
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
    }
}

extension View {
    /// The glass-pill treatment already used for every toolbar search field (ExplorerTopBar, every
    /// browse tab, the quick-switcher) — height 30, 9pt radius. No baked-in icon, since not every
    /// field using this is a search field (a URL/username field doesn't want a magnifying glass).
    func glassFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9))
    }
}
