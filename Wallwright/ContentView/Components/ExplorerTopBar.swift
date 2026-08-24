//
//  ExplorerTopBar.swift
//  Wallwright
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct ExplorerTopBar: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel

    @EnvironmentObject var globalSettingsViewModel: GlobalSettingsViewModel

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: 200, height: 30)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9))

                Button {
                    viewModel.isFilterReveal.toggle()
                } label: {
                    Image(systemName: viewModel.isFilterReveal ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .tint(viewModel.isFilterReveal ? Color.accentColor : nil)
                .help("Filter Results")
                .accessibilityLabel("Filter Results")

                if globalSettingsViewModel.settings.autoRefresh {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                }

                Spacer(minLength: 10)

                HStack(spacing: 6) {
                    Button {
                        viewModel.sortingSequence = viewModel.sortingSequence == .decrease ? .increase : .decrease
                    } label: {
                        Image(systemName: viewModel.sortingSequence == .increase ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                            .font(.caption2)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(viewModel.sortingSequence == .increase ? "Ascending" : "Descending")
                    .accessibilityLabel(viewModel.sortingSequence == .increase ? "Ascending" : "Descending")

                    Picker("Sort By", selection: $viewModel.sortingBy) {
                        ForEach(WEWallpaperSortingMethod.allCases) { method in
                            Text(method.rawValue).tag(method.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}
