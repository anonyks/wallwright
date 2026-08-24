//
//  TopTabBar.swift
//  Wallwright
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct TopTabBar: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var globalSettingsViewModel = AppDelegate.shared.globalSettingsViewModel
    @ObservedObject var inboxLinksStore = AppDelegate.shared.inboxLinksStore
    @Namespace private var glassNamespace

    @State private var isVideoSourcesPopoverPresented = false
    @State private var isImageSourcesPopoverPresented = false

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    // Icon-only — the tab bar reads fine from the icon shape alone (grid vs. globe), and a
    // hover tooltip covers anyone unsure, so the text label was pure chrome weight with no
    // added clarity.
    private func tabButton(systemImage: String, tag: Int, help: String) -> some View {
        let isSelected = viewModel.topTabBarSelection == tag
        return Button {
            // No animation on the tab switch itself — confirmed live (2026-08-04) the animated
            // version and this one have identical underlying render cost, so this is a pure snappier
            // feel with no downside, not a workaround for anything specific.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewModel.topTabBarSelection = tag
            }
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(isSelected ? .semibold : .medium))
                .frame(width: 34, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .glassEffect(
            isSelected ? .regular.tint(.accentColor).interactive() : .identity,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .glassEffectID(tag, in: glassNamespace)
        .help(help)
        .accessibilityLabel(help)
    }

    /// True whenever the currently-shown top-level view is one this popover picks between — the
    /// icon reads as "selected" for MotionBgs/MoeWalls/Wallper/DesktopHut the same way Installed's
    /// tab button does, since all of them are still just tabs under the hood, only reached through
    /// one extra click now.
    private var isVideoSourcesActive: Bool { (1...4).contains(viewModel.topTabBarSelection) }

    /// Same idea as `isVideoSourcesActive`, for the image-sources tab range.
    private var isImageSourcesActive: Bool { (5...6).contains(viewModel.topTabBarSelection) }

    // Replaces what used to be a dedicated "MotionBgs" tab icon — as more sources (Wallper.app,
    // Moewalls, DesktopHut, UHDPaper, direct URLs, ...) get added, giving each its own permanent
    // toolbar icon stops scaling. Split into two icons — one for video sources, one for image
    // sources — since the two media types don't mix in one browsable list; each opens its own
    // small popover listing just its own sources, and each row just navigates to that source's own
    // existing screen (a direct-URL row opens the shared download-from-URL popup instead, which
    // already auto-detects video vs. image from the downloaded file and needs no duplication).
    //
    // YouTube and Steam Workshop deliberately stay as their own dedicated icons, not folded into
    // either popover — they're a different kind of action (an immediate one-off import flow, not a
    // browsable catalog of wallpapers to page through) and are common enough to warrant staying a
    // single click away.
    private var videoSourcesButton: some View {
        Button {
            // If exactly one source has an active download and we're not already looking at it,
            // jump straight there instead of re-asking which source — the picker only opens when
            // there's actually a choice to make (nothing downloading, or already on that tab).
            if let activeTag = viewModel.activeDownloadSourceTag, (1...4).contains(activeTag), viewModel.topTabBarSelection != activeTag {
                viewModel.topTabBarSelection = activeTag
            } else {
                isVideoSourcesPopoverPresented = true
            }
        } label: {
            Image(systemName: "video.fill")
                .font(.body.weight(isVideoSourcesActive ? .semibold : .medium))
                .frame(width: 34, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .foregroundStyle(isVideoSourcesActive ? Color.primary : .secondary)
        .glassEffect(
            isVideoSourcesActive ? .regular.tint(.accentColor).interactive() : .identity,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .glassEffectID(10, in: glassNamespace)
        .help("Video Wallpaper Sources")
        .accessibilityLabel("Video Wallpaper Sources")
        .popover(isPresented: $isVideoSourcesPopoverPresented, arrowEdge: .bottom) {
            videoSourcesPopoverContent
        }
    }

    private var imageSourcesButton: some View {
        Button {
            if let activeTag = viewModel.activeDownloadSourceTag, (5...6).contains(activeTag), viewModel.topTabBarSelection != activeTag {
                viewModel.topTabBarSelection = activeTag
            } else {
                isImageSourcesPopoverPresented = true
            }
        } label: {
            Image(systemName: "photo.stack.fill")
                .font(.body.weight(isImageSourcesActive ? .semibold : .medium))
                .frame(width: 34, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .foregroundStyle(isImageSourcesActive ? Color.primary : .secondary)
        .glassEffect(
            isImageSourcesActive ? .regular.tint(.accentColor).interactive() : .identity,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .glassEffectID(11, in: glassNamespace)
        .help("Image Wallpaper Sources")
        .accessibilityLabel("Image Wallpaper Sources")
        .popover(isPresented: $isImageSourcesPopoverPresented, arrowEdge: .bottom) {
            imageSourcesPopoverContent
        }
    }

    /// Links waiting on the user — ready to import (`.resolved`) or not yet acted on (`.pending`),
    /// as opposed to something already in flight (`.resolving`/`.downloading`/`.importing`) or
    /// finished either way (`.completed`/`.failed`, both surfaced in the tab itself, not here).
    private var inboxActionableCount: Int {
        inboxLinksStore.links.reduce(into: 0) { count, link in
            switch link.status {
            case .pending, .resolved: count += 1
            case .resolving, .downloading, .importing, .completed, .failed: break
            }
        }
    }

    private var inboxButton: some View {
        let isSelected = viewModel.topTabBarSelection == 7
        return Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewModel.topTabBarSelection = 7
            }
        } label: {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.body.weight(isSelected ? .semibold : .medium))
                .frame(width: 34, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topTrailing) {
                    if inboxActionableCount > 0 {
                        Text("\(inboxActionableCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.red, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .glassEffect(
            isSelected ? .regular.tint(.accentColor).interactive() : .identity,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .glassEffectID(12, in: glassNamespace)
        .help("Inbox")
        .accessibilityLabel("Inbox")
    }

    private func sourceRow(icon: String, title: String, dismissing isPresented: Binding<Bool>, action: @escaping () -> Void) -> some View {
        Button {
            isPresented.wrappedValue = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var videoSourcesPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            sourceRow(icon: "link", title: "Direct from URL", dismissing: $isVideoSourcesPopoverPresented) {
                viewModel.isDirectURLImportReveal = true
            }
            sourceRow(icon: "globe", title: "MotionBgs", dismissing: $isVideoSourcesPopoverPresented) {
                viewModel.topTabBarSelection = 1
            }
            sourceRow(icon: "sparkles", title: "MoeWalls", dismissing: $isVideoSourcesPopoverPresented) {
                viewModel.topTabBarSelection = 2
            }
            sourceRow(icon: "photo.artframe", title: "Wallper.app", dismissing: $isVideoSourcesPopoverPresented) {
                viewModel.topTabBarSelection = 3
            }
            sourceRow(icon: "square.grid.3x3.fill", title: "DesktopHut", dismissing: $isVideoSourcesPopoverPresented) {
                viewModel.topTabBarSelection = 4
            }
        }
        .padding(6)
        .frame(width: 220)
    }

    private var imageSourcesPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            sourceRow(icon: "link", title: "Direct from URL", dismissing: $isImageSourcesPopoverPresented) {
                viewModel.isDirectURLImportReveal = true
            }
            sourceRow(icon: "photo.on.rectangle.angled", title: "UHDPaper", dismissing: $isImageSourcesPopoverPresented) {
                viewModel.topTabBarSelection = 5
            }
            sourceRow(icon: "star.fill", title: "AlphaCoders", dismissing: $isImageSourcesPopoverPresented) {
                viewModel.topTabBarSelection = 6
            }
        }
        .padding(6)
        .frame(width: 220)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        tabButton(systemImage: "square.grid.2x2.fill", tag: 0, help: "Installed")
                        videoSourcesButton
                        imageSourcesButton
                        inboxButton

                        // Not a tab (doesn't touch topTabBarSelection, just opens a sheet), but
                        // grouped visually with Installed/MotionBgs as the 3rd item since it's
                        // another "bring content into the library" entry point, not a settings
                        // action like the Displays/Clock/Settings cluster on the right.
                        Button {
                            viewModel.isYouTubeImportReveal = true
                        } label: {
                            Image(systemName: "play.rectangle.fill")
                                .font(.body.weight(.medium))
                                .frame(width: 34, height: 26)
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .foregroundStyle(.secondary)
                        .glassEffect(.identity, in: RoundedRectangle(cornerRadius: 9))
                        .help("Import from YouTube")
                        .accessibilityLabel("Import from YouTube")

                        Button {
                            viewModel.isSteamWorkshopImportReveal = true
                        } label: {
                            // No bundled Steam logo (trademark, and this app is explicitly
                            // unaffiliated with Steam) — "gamecontroller" reads as "this is about
                            // a gaming platform" at a glance, unlike the generic "shippingbox" it
                            // replaced, which just read as "download a package" with no context.
                            Image(systemName: "gamecontroller.fill")
                                .font(.body.weight(.medium))
                                .frame(width: 34, height: 26)
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .foregroundStyle(.secondary)
                        .glassEffect(.identity, in: RoundedRectangle(cornerRadius: 9))
                        .help("Import from Steam Workshop")
                        .accessibilityLabel("Import from Steam Workshop")
                    }
                }
                .animation(.smooth(duration: 0.25), value: viewModel.topTabBarSelection)
                .fixedSize()
                .buttonStyle(.plain)

                Spacer(minLength: 10)

                // Clock's toggle + settings chevron are grouped tightly (2pt) inside the same
                // GlassEffectContainer as everything else, so Liquid Glass renders them as one
                // merged pill — a "split button" rather than an orphaned lone chevron floating
                // next to it, which is what this looked like before.
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        HStack(spacing: 2) {
                            if globalSettingsViewModel.settings.showClockOverlay {
                                Button {
                                    globalSettingsViewModel.settings.showClockOverlay = false
                                } label: {
                                    Image(systemName: "clock.fill")
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(.glassProminent)
                                .tint(Color.accentColor)
                                .help("Turn off clock overlay")
                                .accessibilityLabel("Turn off clock overlay")
                            } else {
                                Button {
                                    globalSettingsViewModel.settings.showClockOverlay = true
                                } label: {
                                    Image(systemName: "clock")
                                        .frame(width: 18, height: 18)
                                }
                                .help("Turn on clock overlay")
                                .accessibilityLabel("Turn on clock overlay")
                            }
                            Button {
                                viewModel.isClockSettingsReveal = true
                            } label: {
                                Image(systemName: "chevron.down")
                                    .frame(width: 14, height: 18)
                            }
                            .help("Clock overlay settings")
                            .accessibilityLabel("Clock overlay settings")
                        }

                        Button {
                            AppDelegate.shared.openSettingsWindow()
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .frame(width: 18, height: 18)
                        }
                        .help("Settings")
                        .accessibilityLabel("Settings")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                }
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
        }
    }
}
