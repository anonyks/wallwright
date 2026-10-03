//
//  AboutUsView.swift
//  Wallwright
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI

extension AppDelegate {
    @objc func showAboutUs() {
        let window = NSWindow()
        window.styleMask = [.closable, .titled]
        window.isReleasedWhenClosed = false
        window.title = ""
        window.contentView = NSHostingView(rootView: AboutUsView())
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct AboutUsView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                }
                Divider().frame(maxHeight: 100)
                VStack(alignment: .leading) {
                    Text("Wallwright").bold().font(.title)
                    Text("Live Wallpapers for Mac").font(.footnote)
                    Text("Version \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            HStack(spacing: 16) {
                Label("GPL-3.0", systemImage: "doc.text")
                Label("100% On-Device", systemImage: "lock.shield")
                Label("Zero Telemetry", systemImage: "hand.raised")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Link(destination: URL(string: "https://github.com/anonyks/wallwright")!) {
                    Label("Repository", systemImage: "safari")
                }
                Link(destination: URL(string: "https://github.com/anonyks/wallwright/releases")!) {
                    Label("Releases", systemImage: "sparkles")
                }
                Link(destination: URL(string: "https://github.com/anonyks/wallwright/issues")!) {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Divider().frame(width: 260)

            VStack(spacing: 12) {
                Text("Contributors")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Link("Unayung/wallpaper-engine-mac", destination: URL(string: "https://github.com/Unayung/wallpaper-engine-mac")!)
                        Text("Original architecture, scene rendering, and localization this project was forked from")
                            .foregroundStyle(.secondary)
                    }
                    creditRow("Raunak Gupta", handle: "Raunik2", role: "Lock-screen/Aerial registration, clock overlay, battery plumbing (from LivePaper, MIT)")
                }
                .font(.caption)
            }

            Text("Steam and Wallpaper Engine are registered trademarks of Valve Corporation. YouTube is a\ntrademark of Google LLC. Wallwright is not affiliated with Valve or Google.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
        .frame(width: 440, height: 460)
    }
}

extension AboutUsView {
    /// `handle` is nil for contributors with no discoverable GitHub account tied to their commits
    /// (verified via the GitHub API, not guessed) — shown as plain text instead of a broken link.
    private func creditRow(_ name: String, handle: String?, role: String) -> some View {
        HStack(spacing: 4) {
            Group {
                if let handle {
                    Link("@\(handle)", destination: URL(string: "https://github.com/\(handle)")!)
                } else {
                    Text(name)
                }
            }
            .frame(width: 120, alignment: .leading)
            Text(role)
                .foregroundStyle(.secondary)
        }
    }
}

struct AboutUsView_Previews: PreviewProvider {
    static var previews: some View {
        AboutUsView()
    }
}
