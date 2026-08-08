//
//  AppMotion.swift
//  Wallwright
//
//  Named animation constants instead of repeating the same tuned spring/ease values ad hoc at
//  every call site — one place to retune, and a guarantee every popup/transition that's supposed
//  to feel the same actually stays in sync.
//

import SwiftUI

enum AppMotion {
    /// The scrim + card popups (Display/Clock/Playlist/YouTube/Steam settings).
    static let popupTransition = Animation.spring(response: 0.3, dampingFraction: 0.85)
}
