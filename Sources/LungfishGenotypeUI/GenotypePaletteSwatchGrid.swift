// GenotypePaletteSwatchGrid.swift - Color swatches that VoiceOver and AX clients can name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import SwiftUI

extension AnnotationColor {
    /// A plain-language name for the color, such as "Light Blue" or "Dark
    /// Gray", so a swatch is never identified by its color alone.
    var descriptiveName: String {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let chroma = maximum - minimum

        if chroma < 0.08 {
            switch lightness {
            case ..<0.12: return "Black"
            case ..<0.35: return "Dark Gray"
            case ..<0.65: return "Gray"
            case ..<0.92: return "Light Gray"
            default: return "White"
            }
        }

        var hue: Double
        if maximum == red {
            hue = (green - blue) / chroma
        } else if maximum == green {
            hue = 2 + (blue - red) / chroma
        } else {
            hue = 4 + (red - green) / chroma
        }
        hue = (hue * 60).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }

        let base: String
        switch hue {
        case ..<15: base = "Red"
        case ..<40: base = lightness < 0.45 ? "Brown" : "Orange"
        case ..<65: base = "Yellow"
        case ..<165: base = "Green"
        case ..<195: base = "Teal"
        case ..<255: base = "Blue"
        case ..<285: base = "Purple"
        case ..<335: base = "Pink"
        default: base = "Red"
        }
        if lightness < 0.28 { return "Dark \(base)" }
        if lightness > 0.72 { return "Light \(base)" }
        return base
    }
}

/// One swatch of a ``GenotypePaletteSwatchGrid``.
struct GenotypePaletteSwatch: Identifiable, Equatable {
    /// Short position name within its palette, such as "M3" or "General 4".
    let name: String
    let color: AnnotationColor

    var id: String { name }

    /// The accessibility label: position and color name together.
    var accessibilityLabel: String { "\(name), \(color.descriptiveName)" }
}

/// A grid of color swatch buttons.
///
/// Built as an eager `Grid` so every swatch is in the accessibility tree
/// (a lazy grid hides the cells it has not built). Each swatch is labelled
/// with its position and color name and carries its hex value, and the
/// selected swatch reports the selected state and draws a heavy outline, so
/// neither state nor identity rests on color alone.
struct GenotypePaletteSwatchGrid: View {
    let swatches: [GenotypePaletteSwatch]
    var columns: Int = 8
    var selected: AnnotationColor?
    var swatchSize: CGFloat = 14
    var spacing: CGFloat = 5
    var isDisabled = false
    let apply: (AnnotationColor) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { swatch in
                        swatchButton(swatch)
                    }
                }
            }
        }
    }

    private var rows: [[GenotypePaletteSwatch]] {
        let width = max(1, columns)
        return stride(from: 0, to: swatches.count, by: width).map {
            Array(swatches[$0..<min($0 + width, swatches.count)])
        }
    }

    private func swatchButton(_ swatch: GenotypePaletteSwatch) -> some View {
        let isSelected = selected == swatch.color
        return Button {
            apply(swatch.color)
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: swatch.color.red, green: swatch.color.green, blue: swatch.color.blue, opacity: swatch.color.alpha))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isSelected ? Color.primary : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                )
                .frame(width: swatchSize, height: swatchSize)
                .padding((26 - swatchSize) / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help("\(swatch.accessibilityLabel) \(swatch.color.hexString)")
        .accessibilityLabel(swatch.accessibilityLabel)
        .accessibilityValue(swatch.color.hexString)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("genotype-swatch-\(swatch.name)")
    }
}
