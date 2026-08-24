//
//  FirstLaunchView.swift
//  Wallwright
//
//  Created by Haren on 2023/8/4.
//

import SwiftUI

struct FirstLaunchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var globalSettingsViewModel: GlobalSettingsViewModel
    
    @State var checked = false
    
    var body: some View {
        VStack {
            VStack(spacing: 5) {
                Text("What's New in Wallwright")
                    .font(.largeTitle)
                Divider()
            }
            .fixedSize()
            VStack {
                Group {
                    NewSection(title: "Import Wallpapers Your Way",
                               text: "Drag in a folder, a .zip package, or even a bare video file — Wallwright builds the wallpaper package for you automatically.",
                               systemImage: "square.and.arrow.down")
                    NewSection(title: "Similar UI Layout to Wallpaper Engine on Steam",
                               text: "You'll feel right at home using this dynamic desktop wallpaper tool — it shares a similar layout to its inspiration.",
                               systemImage: "macwindow.on.rectangle",
                               imageColor: .yellow)
                    NewSection(title: "Super High Performance",
                               text: "We bring you a smoother app animation experience, powered by the lightweight, modern SwiftUI framework.",
                               systemImage: "speedometer",
                               imageColor: .red)
                    NewSection(title: "We Take Care of Your Laptop's Battery Life",
                               text: "When you're not plugged into power, we reduce power consumption as much as possible — without just stopping playback outright.",
                               systemImage: "battery.75",
                               imageColor: .green)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical)
                .padding(.horizontal, 50)
            }
            Button {
                UserDefaults.standard.set(!checked, forKey: "IsFirstLaunch")
                dismiss()
            } label: {
                Text("OK")
                    .frame(width: 100)
            }
            .buttonStyle(.glassProminent)
            HStack {
                Toggle("Never show this again until next update", isOn: $checked)
                Spacer()
            }
        }
        .textSelection(.enabled)
        .padding()
        .frame(width: 600)
    }
}

extension FirstLaunchView {
    struct NewSection: View {
        var title: LocalizedStringKey
        var text: LocalizedStringKey
        var textColor: Color = .primary
        var systemImage: String
        var imageColor: Color = .accentColor
        
        var body: some View {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 50, height: 50)
                    .font(.largeTitle)
                    .foregroundStyle(imageColor)
                VStack(alignment: .leading) {
                    Text(title)
                        .foregroundStyle(textColor)
                        .font(.title2)
                        .bold()
                    Text(text)
                        .foregroundStyle(textColor)
                }
                .multilineTextAlignment(.leading)
                Spacer()
            }
        }
    }
}

struct FirstLaunchView_Previews: PreviewProvider {
    static var previews: some View {
        FirstLaunchView()
    }
}
