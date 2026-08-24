//
//  FilterResults.swift
//  Wallwright
//
//  Created by Haren on 2023/6/29.
//

import SwiftUI

struct FilterSection<Content>: View where Content: View {
    private let content: Content
    private let alignment: HorizontalAlignment
    private var spacing: CGFloat?
    private let titleKey: LocalizedStringKey

    @State private var isExpanded: Bool = true

    init(_ titleKey: LocalizedStringKey, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.alignment = alignment
        self.spacing = spacing
        self.titleKey = titleKey
    }

    var body: some View {
        VStack(alignment: self.alignment, spacing: self.spacing) {
            Button {
                // Same curve as the chevron's own rotation below — these used to run on two
                // different animations (a flat default here, an untuned `.spring()` there) for one
                // click, which reads as a visible mismatch between the disclosure and its label.
                withAnimation(AppMotion.popupTransition) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    // Small-caps caption, not subheadline — matches the quick-switcher's section
                    // labels (Go to/Import/Actions), which serve the exact same "grouping label"
                    // role. Two different header treatments for the same role, in the same app, was
                    // the kind of thing that reads as merely assembled rather than designed.
                    Text(self.titleKey)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(isExpanded ? .zero : .degrees(-90.0))
                        .animation(AppMotion.popupTransition, value: isExpanded)
                }
            }
            .buttonStyle(.plain)
            if isExpanded {
                content
            }
        }
    }
}

struct FilterResults: View {
    @ObservedObject var viewModel: FilterResultsViewModel

    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        Text("Filters")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            viewModel.reset()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(viewModel.selectedTagFilters.isEmpty && !viewModel.audioOnlyFilter && !viewModel.staticOnlyFilter)
                        .help("Reset Filters")
                    }

                    FilterSection("Audio", alignment: .leading, spacing: 4) {
                        audioFilterRow
                    }

                    FilterSection("Type", alignment: .leading, spacing: 4) {
                        staticFilterRow
                    }

                    FilterSection("Tags", alignment: .leading, spacing: 4) {
                        if viewModel.availableTags.isEmpty {
                            Text("No tags yet")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(viewModel.availableTags, id: \.self) { tag in
                                    tagRow(tag)
                                }
                            }
                        }
                    }
                }
                .padding(.trailing)
            }
            .lineLimit(1)
        }
        Divider()
    }

    private var audioFilterRow: some View {
        let isSelected = viewModel.audioOnlyFilter
        return Button {
            viewModel.audioOnlyFilter.toggle()
        } label: {
            HStack {
                Image(systemName: "music.note")
                    .font(.callout)
                Text("Has Audio")
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .glassEffect(isSelected ? .regular.tint(.accentColor) : .identity, in: RoundedRectangle(cornerRadius: 8))
    }

    private var staticFilterRow: some View {
        let isSelected = viewModel.staticOnlyFilter
        return Button {
            viewModel.staticOnlyFilter.toggle()
        } label: {
            HStack {
                Image(systemName: "photo")
                    .font(.callout)
                Text("Static Only")
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .glassEffect(isSelected ? .regular.tint(.accentColor) : .identity, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tagRow(_ tag: String) -> some View {
        let isSelected = viewModel.selectedTagFilters.contains(tag)
        return Button {
            if isSelected {
                viewModel.selectedTagFilters.remove(tag)
            } else {
                viewModel.selectedTagFilters.insert(tag)
            }
        } label: {
            HStack {
                Text(tag)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .glassEffect(isSelected ? .regular.tint(.accentColor) : .identity, in: RoundedRectangle(cornerRadius: 8))
    }
}
