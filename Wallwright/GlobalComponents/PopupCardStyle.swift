//
//  PopupCardStyle.swift
//  Wallwright
//
//  The `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))` card background was
//  duplicated identically across every popup's content (DisplaySettings, ClockSettings,
//  PlaylistSettings×2) — one shared modifier means retuning the shared look later is a one-line
//  change instead of hunting down every call site and keeping them in sync by hand.
//

import SwiftUI

extension View {
    /// The rounded glass-card background used for each popup's scrollable content area.
    func popupCardStyle() -> some View {
        self
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            // Same reasoning as the outer popup shell's own hairline (see ContentView) — a glass
            // fill with no edge definition at all reads as a soft blur, not a distinct card resting
            // on top of the panel behind it.
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            }
    }
}
