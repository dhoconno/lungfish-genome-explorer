// LungfishInspectorStyle.swift - Shared SwiftUI Inspector typography and controls
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

enum LungfishInspectorStyle {
    static let sectionTitleFont: Font = .caption.weight(.semibold)
    static let controlFont: Font = .caption

    static func segmentedControlFont(isSelected: Bool) -> Font {
        .caption.weight(isSelected ? .semibold : .regular)
    }
}

struct LungfishInspectorSegmentedButtonGrid<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let accessibilityLabel: String
    let label: (Option) -> String

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 6),
            count: max(1, min(options.count, 2))
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(LungfishInspectorStyle.segmentedControlFont(isSelected: selection == option))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .padding(.horizontal, 4)
                        .background(background(for: option))
                        .foregroundStyle(selection == option ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(label(option))
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func background(for option: Option) -> some View {
        if selection == option {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlColor))
        }
    }
}
