// AppearanceSection.swift - Base colors and track height inspector section
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// View model for the appearance section.
///
/// Manages base colors and track height settings with persistence support.
@MainActor
public class AppearanceSectionViewModel: ObservableObject {
    // MARK: - Base Colors

    /// Color for Adenine (A) bases
    @Published public var colorA: Color

    /// Color for Thymine (T) bases
    @Published public var colorT: Color

    /// Color for Guanine (G) bases
    @Published public var colorG: Color

    /// Color for Cytosine (C) bases
    @Published public var colorC: Color

    /// Color for unknown/ambiguous (N) bases
    @Published public var colorN: Color

    // MARK: - Track Settings

    /// Track height in points (range: 20-80)
    @Published public var trackHeight: Double

    /// Callback when settings are changed
    public var onSettingsChanged: (() -> Void)?

    /// Callback when reset to defaults is requested.
    /// This allows the parent view model to coordinate resetting all appearance settings.
    public var onResetToDefaults: (() -> Void)?

    // MARK: - Default Values

    /// Default colors following standard bioinformatics conventions
    public static let defaultColorA = Color(red: 0.35, green: 0.70, blue: 0.35)  // Green
    public static let defaultColorT = Color(red: 0.90, green: 0.35, blue: 0.35)  // Red
    public static let defaultColorG = Color(red: 0.95, green: 0.75, blue: 0.25)  // Yellow/Gold
    public static let defaultColorC = Color(red: 0.35, green: 0.55, blue: 0.85)  // Blue
    public static let defaultColorN = Color(red: 0.60, green: 0.60, blue: 0.60)  // Gray
    public static let defaultTrackHeight: Double = 28  // Reduced for more compact display

    public init() {
        self.colorA = Self.defaultColorA
        self.colorT = Self.defaultColorT
        self.colorG = Self.defaultColorG
        self.colorC = Self.defaultColorC
        self.colorN = Self.defaultColorN
        self.trackHeight = Self.defaultTrackHeight
    }

    /// Resets all appearance settings to their default values.
    ///
    /// This method resets only the properties managed by this view model.
    /// For a full reset of all appearance settings (including quality overlay
    /// and annotation settings), use the `onResetToDefaults` callback.
    public func resetToDefaults() {
        colorA = Self.defaultColorA
        colorT = Self.defaultColorT
        colorG = Self.defaultColorG
        colorC = Self.defaultColorC
        colorN = Self.defaultColorN
        trackHeight = Self.defaultTrackHeight
        onSettingsChanged?()
    }

    /// Returns a dictionary of base colors for use in rendering.
    public var baseColors: [Character: Color] {
        [
            "A": colorA, "a": colorA,
            "T": colorT, "t": colorT,
            "G": colorG, "g": colorG,
            "C": colorC, "c": colorC,
            "N": colorN, "n": colorN,
            "U": colorT, "u": colorT  // Uracil uses same color as Thymine
        ]
    }
}

// MARK: - AppearanceSection

/// SwiftUI view for configuring base colors and track height.
///
/// Provides color pickers for each nucleotide base and a slider for
/// adjusting track height. Includes a reset button to restore defaults.
public struct AppearanceSection: View {
    @ObservedObject var viewModel: AppearanceSectionViewModel
    @State private var isExpanded = true

    public init(viewModel: AppearanceSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                baseColorsSection

                Divider()
                    .padding(.vertical, 4)

                trackHeightSection

                Divider()
                    .padding(.vertical, 4)

                resetButton
            }
            .padding(.top, 8)
        } label: {
            Label("Appearance", systemImage: "paintpalette")
                .font(.headline)
        }
    }

    // MARK: - Base Colors Section

    @ViewBuilder
    private var baseColorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Base Colors")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                baseColorRow(label: "A", sublabel: "Adenine", color: $viewModel.colorA)
                baseColorRow(label: "T", sublabel: "Thymine", color: $viewModel.colorT)
                baseColorRow(label: "G", sublabel: "Guanine", color: $viewModel.colorG)
                baseColorRow(label: "C", sublabel: "Cytosine", color: $viewModel.colorC)
                baseColorRow(label: "N", sublabel: "Unknown", color: $viewModel.colorN)
            }
        }
    }

    @ViewBuilder
    private func baseColorRow(label: String, sublabel: String, color: Binding<Color>) -> some View {
        HStack(spacing: 8) {
            // Base letter badge
            Text(label)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(color.wrappedValue)
                .foregroundColor(contrastingTextColor(for: color.wrappedValue))
                .cornerRadius(4)

            Text(sublabel)
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer()

            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: color.wrappedValue) { _, _ in
                    viewModel.onSettingsChanged?()
                }
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
                    in: 20...80,
                    step: 1
                )
                .onChange(of: viewModel.trackHeight) { _, _ in
                    viewModel.onSettingsChanged?()
                }

                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Visual preview of track height
            HStack(spacing: 2) {
                ForEach(["A", "T", "G", "C"], id: \.self) { base in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForBase(base))
                        .frame(width: 16, height: viewModel.trackHeight * 0.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
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

    // MARK: - Helper Functions

    private func colorForBase(_ base: String) -> Color {
        switch base {
        case "A": return viewModel.colorA
        case "T": return viewModel.colorT
        case "G": return viewModel.colorG
        case "C": return viewModel.colorC
        default: return viewModel.colorN
        }
    }

    /// Calculates a contrasting text color (black or white) for a given background color.
    private func contrastingTextColor(for color: Color) -> Color {
        // Convert to NSColor to get RGB components
        guard let cgColor = color.cgColor,
              let components = cgColor.components,
              components.count >= 3 else {
            return .white
        }

        let red = components[0]
        let green = components[1]
        let blue = components[2]

        // Calculate relative luminance using sRGB formula
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue

        return luminance > 0.5 ? .black : .white
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
        .frame(width: 280, height: 500)
    }
}
#endif
