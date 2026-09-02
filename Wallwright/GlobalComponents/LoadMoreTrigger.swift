//
//  LoadMoreTrigger.swift
//  Wallwright
//
//  Shared by every browse tab (MotionBgs, MoeWalls, Wallper, DesktopHut, UhdPaper, AlphaCoders)
//  to auto-paginate on scroll instead of requiring a "Load More" click.
//

import SwiftUI

/// Attach to the LAST item in a lazy grid/list. Only that item participates in the lazy
/// container's real viewport-visibility tracking — a sibling view placed outside the lazy
/// container (e.g. a "Load More" button sitting after a LazyVGrid, both as direct ScrollView
/// children) is NOT lazy itself, so its own `onAppear` doesn't correspond to actual scroll
/// position at all: it can fire as soon as the tab loads, and never fires again once mounted.
/// Confirmed live (2026-08-27): a `.onAppear` wired directly to the button fired before the
/// button was ever visible on the first pass, then didn't fire again on a later real scroll to it.
///
/// Debounced via `visible` so a fast momentum-scroll flick past the bottom doesn't trigger a
/// load — only actually landing there (or continuing to scroll past it) for a beat does.
struct LoadMoreTrigger: ViewModifier {
    let isLast: Bool
    @Binding var visible: Bool
    let canLoad: Bool
    let load: () -> Void

    func body(content: Content) -> some View {
        if isLast {
            content
                .onAppear {
                    visible = true
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if visible, canLoad {
                            load()
                        }
                    }
                }
                .onDisappear { visible = false }
        } else {
            content
        }
    }
}
