//
//  ExplorerTopBar.swift
//  Wallwright
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct ExplorerTopBar: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @FocusState private var isSearchFocused: Bool

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
                        .focused($isSearchFocused)
                        // Only claims Escape while there's actually something to clear — an empty
                        // search field returning `.ignored` lets it bubble up to whatever else
                        // (a popup sheet) already handles Escape, same as before this existed.
                        .onKeyPress(.escape) {
                            guard !viewModel.searchText.isEmpty else { return .ignored }
                            viewModel.searchText = ""
                            return .handled
                        }
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

                // `settings.autoRefresh` used to gate this — always true in practice (never
                // exposed as a toggle anywhere in Settings UI), so the button was effectively
                // always shown anyway; the condition was dead weight, not a real manual/automatic
                // distinction.
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
        .background {
            // Standard macOS "focus search" shortcut — invisible, zero-size; only exists to carry
            // the keyboard shortcut binding, not to be seen or clicked.
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
    }
}
