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
        VStack(spacing: 50) {
            HStack {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                }
                Divider().frame(maxHeight: 100)
                VStack(alignment: .leading) {
                    Text("Wallwright").bold().font(.title)
                    Text("Live Wallpapers for Mac").font(.footnote)
                }
            }
            VStack(spacing: 12) {
                Text("Version \(version)")

                Divider().frame(width: 200)

                Text("Contributors")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    creditRow("Haren Chen", handle: "haren724", role: "Original architecture")
                    creditRow("MrWindDog", handle: nil, role: "Original architecture")
                    creditRow("Chen Chia Yang", handle: "Unayung", role: "Scene rendering, multi-display support")
                    creditRow("1ris_W", handle: "Erica-Iris", role: "Chinese localization")
                    creditRow("Klaus Zhu", handle: "klauszhu1105", role: "App icons")
                    creditRow("baysonfox", handle: "baysonfox", role: "Repo maintenance, localization")
                    creditRow("Toby Shi", handle: "Toby-Shi-cloud", role: "Original web wallpaper support")
                    creditRow("Keria", handle: nil, role: "Internal refactoring")
                    creditRow("Raunak Gupta", handle: "Raunik2", role: "Lock-screen/Aerial registration, clock overlay, battery plumbing (from LivePaper, MIT)")
                }
                .font(.caption)
            }
        }
        .frame(width: 420, height: 420)
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
