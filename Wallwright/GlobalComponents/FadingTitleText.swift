//
//  FadingTitleText.swift
//  Wallwright
//
//  Single-line title that fades out its trailing edge instead of hard-truncating with "…" — the
//  text renders at its natural (un-truncated) width via `fixedSize`, then gets clipped to whatever
//  width the container actually gives it. Short titles are unaffected (nothing to clip, the fade
//  region just sits over empty space); long titles fade smoothly over their last 40%.
//
//  Originally only used in WallpaperPreview's sidebar; moved here (and made internal instead of
//  private) so ExplorerItem's grid cards can share the exact same treatment instead of their own
//  separate hard `.lineLimit(2)` truncation.
//

import SwiftUI

struct FadingTitleText: View {
    let text: String

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.6),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }
}
