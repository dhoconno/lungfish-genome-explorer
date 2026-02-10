// AppearanceSection.swift - Track height inspector section
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// View model for the appearance section.
///
/// Manages track height settings with persistence support.
@Observable
@MainActor
public final class AppearanceSectionViewModel {
    // MARK: - Track Settings

    /// Track height in points (range: 5-100)
    public var trackHeight: Double

    /// Callback when settings are changed
    public var onSettingsChanged: (() -> Void)?

    /// Callback when reset to defaults is requested.
    /// This allows the parent view model to coordinate resetting all appearance settings.
    public var onResetToDefaults: (() -> Void)?

    // MARK: - Default Values

    public static let defaultTrackHeight: Double = 20  // Compact default for sequence tracks

    public init() {
        self.trackHeight = Self.defaultTrackHeight
    }

    /// Resets all appearance settings to their default values.
    public func resetToDefaults() {
        trackHeight = Self.defaultTrackHeight
        onSettingsChanged?()
    }
}

// MARK: - AppearanceSection

/// SwiftUI view for configuring track height.
///
/// Provides a slider for adjusting track height with a reset button.
public struct AppearanceSection: View {
    @Bindable var viewModel: AppearanceSectionViewModel
    @State private var isExpanded = true

    public init(viewModel: AppearanceSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                trackHeightSection

                Divider()
                    .padding(.vertical, 4)

                resetButton
            }
            .padding(.top, 8)
        } label: {
            Text("Sequence Style")
                .font(.headline)
        }
    }

    // MARK: - Track Height Section

    @ViewBuilder
    private var trackHeightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Track Height")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(viewModel.trackHeight)) pt")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Image(systemName: "minus")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(
                    value: $viewModel.trackHeight,
                    in: 5...100,
                    step: 1
                )
                .onChange(of: viewModel.trackHeight) { _, _ in
                    viewModel.onSettingsChanged?()
                }

                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Reset Button

    @ViewBuilder
    private var resetButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                // Use the coordinated reset callback if available,
                // otherwise fall back to resetting just this view model
                if let onResetToDefaults = viewModel.onResetToDefaults {
                    onResetToDefaults()
                } else {
                    viewModel.resetToDefaults()
                }
            }
        } label: {
            Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Preview

#if DEBUG
struct AppearanceSection_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                AppearanceSection(viewModel: AppearanceSectionViewModel())
            }
            .padding()
        }
        .frame(width: 280, height: 300)
    }
}
#endif
