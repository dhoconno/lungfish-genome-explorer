// AppearanceSettingsTab.swift - Appearance preferences tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// Appearance preferences: nucleotide colors, annotation type colors, dimensions.
struct AppearanceSettingsTab: View {

    @State private var settings = AppSettings.shared

    // Local color state for nucleotide bases (derived from hex strings)
    @State private var colorA: Color = .green
    @State private var colorT: Color = .red
    @State private var colorG: Color = .yellow
    @State private var colorC: Color = .blue
    @State private var colorN: Color = .gray
    @State private var colorU: Color = .red

    // Local color state for annotation types
    @State private var annotationColors: [String: Color] = [:]

    private let annotationTypeOrder = [
        "gene", "CDS", "exon", "mRNA", "transcript",
        "misc_feature", "region", "primer", "restriction_site",
    ]

    var body: some View {
        Form {
            Section("Content Text Size") {
                Picker(
                    "Content text size:",
                    selection: contentTextSizeSelection
                ) {
                    Text("System").tag(0)
                    ForEach(
                        Array(ContentTextSizePreference.supportedPercentages.enumerated()),
                        id: \.offset
                    ) { index, percentage in
                        Text("\(percentage)%").tag(index + 1)
                    }
                }
                .accessibilityLabel("Content text size")
                .accessibilityIdentifier(SettingsAccessibilityID.contentTextSizePicker)

                Text("Adjusts primary list, table, and detail text throughout Lungfish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Nucleotide Colors") {
                HStack(spacing: 16) {
                    baseColorPicker("A", color: $colorA)
                    baseColorPicker("T", color: $colorT)
                    baseColorPicker("G", color: $colorG)
                    baseColorPicker("C", color: $colorC)
                    baseColorPicker("N", color: $colorN)
                    baseColorPicker("U", color: $colorU)
                }
                .padding(.vertical, 4)
            }

            Section("Annotation Type Colors") {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 8) {
                    ForEach(annotationTypeOrder, id: \.self) { type in
                        annotationColorPicker(type)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Variant Theme") {
                Picker("Color theme:", selection: $settings.variantColorThemeName) {
                    Text("Modern").tag("Modern")
                    Text("IGV Classic").tag("IGV Classic")
                    Text("High Contrast").tag("High Contrast")
                }
                .pickerStyle(.segmented)
            }

            Section("Dimensions") {
                HStack {
                    Text("Annotation height:")
                    Slider(value: $settings.defaultAnnotationHeight, in: 8...32, step: 1)
                    Text("\(Int(settings.defaultAnnotationHeight)) px")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Row spacing:")
                    Slider(value: $settings.defaultAnnotationSpacing, in: 0...8, step: 1)
                    Text("\(Int(settings.defaultAnnotationSpacing)) px")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("Scrolling") {
                Picker("Horizontal:", selection: $settings.horizontalScrollDirection) {
                    ForEach(ScrollDirectionPreference.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Picker("Vertical:", selection: $settings.verticalScrollDirection) {
                    ForEach(ScrollDirectionPreference.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Text("System follows macOS trackpad/mouse settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    restoreAppearanceDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadColorsFromSettings() }
        .onChange(of: settings.variantColorThemeName) { _, _ in
            settings.save()
            NotificationCenter.default.post(name: .variantColorThemeDidChange, object: nil)
        }
        .onChange(of: settings.defaultAnnotationHeight) { _, _ in settings.save() }
        .onChange(of: settings.defaultAnnotationSpacing) { _, _ in settings.save() }
        .onChange(of: settings.horizontalScrollDirection) { _, _ in settings.save() }
        .onChange(of: settings.verticalScrollDirection) { _, _ in settings.save() }
    }

    // MARK: - Subviews

    private var contentTextSizeSelection: Binding<Int> {
        Binding(
            get: {
                switch settings.contentTextSizePreference.normalized {
                case .system:
                    return 0
                case .custom(let percentage):
                    return (ContentTextSizePreference.supportedPercentages.firstIndex(
                        of: percentage
                    ) ?? 0) + 1
                }
            },
            set: { selection in
                let preference: ContentTextSizePreference
                if selection == 0 {
                    preference = .system
                } else {
                    let index = selection - 1
                    guard ContentTextSizePreference.supportedPercentages.indices.contains(index) else {
                        return
                    }
                    preference = .custom(
                        ContentTextSizePreference.supportedPercentages[index]
                    )
                }
                guard settings.contentTextSizePreference.normalized != preference else {
                    return
                }
                settings.contentTextSizePreference = preference
                settings.save()
            }
        )
    }

    private func baseColorPicker(_ base: String, color: Binding<Color>) -> some View {
        VStack(spacing: 4) {
            Text(base)
                .font(.system(.body, design: .monospaced, weight: .bold))
            ColorPicker(
                "",
                selection: persistedBaseColorBinding(base, color: color),
                supportsOpacity: false
            )
                .labelsHidden()
        }
    }

    private func annotationColorPicker(_ type: String) -> some View {
        HStack(spacing: 6) {
            ColorPicker(
                "",
                selection: annotationColorBinding(for: type),
                supportsOpacity: false
            )
            .labelsHidden()
            Text(type)
                .font(.caption)
                .lineLimit(1)
        }
    }

    // MARK: - Color Sync

    private func loadColorsFromSettings() {
        let appearance = settings.sequenceAppearance
        colorA = Color(nsColor: AppSettings.color(from: appearance.baseColors["A"] ?? "#00A000"))
        colorT = Color(nsColor: AppSettings.color(from: appearance.baseColors["T"] ?? "#FF0000"))
        colorG = Color(nsColor: AppSettings.color(from: appearance.baseColors["G"] ?? "#FFD700"))
        colorC = Color(nsColor: AppSettings.color(from: appearance.baseColors["C"] ?? "#0000FF"))
        colorN = Color(nsColor: AppSettings.color(from: appearance.baseColors["N"] ?? "#808080"))
        colorU = Color(nsColor: AppSettings.color(from: appearance.baseColors["U"] ?? "#FF0000"))

        var colors: [String: Color] = [:]
        for type in annotationTypeOrder {
            let hex = settings.annotationTypeColorHexes[type]
                ?? AppSettings.defaultAnnotationTypeColorHexes[type]
                ?? "#808080"
            colors[type] = Color(nsColor: AppSettings.color(from: hex))
        }
        annotationColors = colors
    }

    private func syncBaseColor(_ base: String, from color: Color) {
        let nsColor = NSColor(color)
        let hex = AppSettings.hexString(from: nsColor)
        settings.sequenceAppearance.baseColors[base] = hex
        settings.save()
    }

    private func persistedBaseColorBinding(
        _ base: String,
        color: Binding<Color>
    ) -> Binding<Color> {
        Binding(
            get: { color.wrappedValue },
            set: { newColor in
                color.wrappedValue = newColor
                syncBaseColor(base, from: newColor)
            }
        )
    }

    private func restoreAppearanceDefaults() {
        Self.restoreAppearanceDefaults(
            settings: settings,
            reloadColors: loadColorsFromSettings
        )
    }

    @MainActor
    static func restoreAppearanceDefaults(
        settings: AppSettings,
        reloadColors: () -> Void
    ) {
        settings.resetSection(.appearance)
        settings.save()
        reloadColors()
    }

    private func annotationColorBinding(for type: String) -> Binding<Color> {
        Binding<Color>(
            get: {
                annotationColors[type] ?? .gray
            },
            set: { newColor in
                annotationColors[type] = newColor
                let nsColor = NSColor(newColor)
                let hex = AppSettings.hexString(from: nsColor)
                settings.annotationTypeColorHexes[type] = hex
                settings.save()
            }
        )
    }
}
