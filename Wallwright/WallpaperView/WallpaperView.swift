//
//  WallpaperView.swift
//  Wallwright
//
//  Created by Haren on 2023/6/5.
//

import Cocoa
import SwiftUI

struct WallpaperView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    let screenId: String

    var body: some View {
        let wallpaper = viewModel.wallpaper(for: screenId)
        switch wallpaper.project.type.lowercased() {
        case "video":
            // Explicit fill is required here: unlike a plain NSView, AVPlayerView (inside
            // VideoWallpaperView) reports an intrinsic content size tied to the video's own
            // dimensions — without this, SwiftUI sizes it to the video's native aspect ratio and
            // centers it, leaving a margin on all four sides that shows whatever's behind the window.
            VideoWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case "image":
            StaticImageWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
        default:
            EmptyView()
        }
    }
}
