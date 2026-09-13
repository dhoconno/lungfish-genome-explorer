// LungfishInspectorStyle.swift - Shared SwiftUI Inspector typography and controls
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishKit

@MainActor
enum LungfishInspectorStyle {
    static var sectionTitleFont: Font { ContentTypographyModel.shared.font(for: .emphasizedBody) }
    static var controlFont: Font { ContentTypographyModel.shared.font(for: .body) }

    static func segmentedControlFont(isSelected: Bool) -> Font {
        controlFont.weight(isSelected ? .semibold : .regular)
    }
}

struct LungfishInspectorSegmentedButtonGrid<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let accessibilityLabel: String
    let label: (Option) -> String
    var minimumLabelScale: CGFloat = 1

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
                    optionLabel(option)
                }
                .buttonStyle(.plain)
                .help(label(option))
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func optionLabel(_ option: Option) -> some View {
        let minimumHeight = max(
            28,
            ContentTypographyModel.shared.resolvedNSFont(for: .body).pointSize * 2
        )
        return Text(label(option))
            .font(LungfishInspectorStyle.segmentedControlFont(isSelected: selection == option))
            .lineLimit(minimumLabelScale < 1 ? 1 : 2)
            .truncationMode(.tail)
            .minimumScaleFactor(minimumLabelScale)
            .allowsTightening(minimumLabelScale < 1)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .padding(.horizontal, 4)
            .background(background(for: option))
            .foregroundStyle(selection == option ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
