// AnnotationSection.swift - Annotation display settings and filtering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// View model for the annotation section.
///
/// Manages annotation display settings like height, visibility, and filtering.
@Observable
@MainActor
public final class AnnotationSectionViewModel {
    // MARK: - Default Values

    /// Default annotation track height in points
    public static let defaultAnnotationHeight: Double = 16

    /// Default spacing between annotation rows
    public static let defaultAnnotationSpacing: Double = 2

    /// Default visibility setting for annotations
    public static let defaultShowAnnotations: Bool = true

    // MARK: - Observable Properties

    /// Annotation track height in points
    public var annotationHeight: Double = 16

    /// Spacing between annotation rows
    public var annotationSpacing: Double = 2

    /// Whether to show annotations
    public var showAnnotations: Bool = true

    /// Types to show (nil = show all)
    public var visibleTypes: Set<AnnotationType> = Set(AnnotationType.allCases)

    /// Search filter text
    public var filterText: String = ""

    /// Callback when settings change
    public var onSettingsChanged: (() -> Void)?

    /// Callback when filter changes
    public var onFilterChanged: ((Set<AnnotationType>, String) -> Void)?

    public init() {}

    /// Notifies listeners that annotation display settings changed.
    ///
    /// Falls back to posting a global notification when the inspector controller
    /// callback is not attached (e.g., during panel lifecycle transitions).
    public func notifySettingsChanged() {
        NSLog(
            "AnnotationSectionViewModel.notifySettingsChanged: show=%@ height=%.1f spacing=%.1f callback=%@",
            showAnnotations ? "true" : "false",
            annotationHeight,
            annotationSpacing,
            onSettingsChanged == nil ? "nil" : "set"
        )
        if let onSettingsChanged {
            onSettingsChanged()
            return
        }

        NotificationCenter.default.post(
            name: .annotationSettingsChanged,
            object: self,
            userInfo: [
                "showAnnotations": showAnnotations,
                "annotationHeight": annotationHeight,
                "annotationSpacing": annotationSpacing
            ]
        )
    }

    /// Notifies listeners that annotation type/text filters changed.
    ///
    /// Falls back to posting a global notification when the inspector controller
    /// callback is not attached (e.g., during panel lifecycle transitions).
    public func notifyFilterChanged() {
        NSLog(
            "AnnotationSectionViewModel.notifyFilterChanged: visibleTypes=%ld filter='%@' callback=%@",
            visibleTypes.count,
            filterText,
            onFilterChanged == nil ? "nil" : "set"
        )
        if let onFilterChanged {
            onFilterChanged(visibleTypes, filterText)
            return
        }

        NotificationCenter.default.post(
            name: .annotationFilterChanged,
            object: self,
            userInfo: [
                "visibleTypes": visibleTypes,
                "filterText": filterText
            ]
        )
    }

    /// Toggles visibility of an annotation type
    public func toggleType(_ type: AnnotationType) {
        NSLog("AnnotationSectionViewModel.toggleType: type=%@", type.rawValue)
        if visibleTypes.contains(type) {
            visibleTypes.remove(type)
        } else {
            visibleTypes.insert(type)
        }
        notifyFilterChanged()
    }

    /// Shows all annotation types
    public func showAllTypes() {
        NSLog("AnnotationSectionViewModel.showAllTypes")
        visibleTypes = Set(AnnotationType.allCases)
        notifyFilterChanged()
    }

    /// Hides all annotation types
    public func hideAllTypes() {
        NSLog("AnnotationSectionViewModel.hideAllTypes")
        visibleTypes = []
        notifyFilterChanged()
    }

    /// Resets all annotation settings to their default values.
    ///
    /// Resets height, spacing, visibility, type filters, and search text.
    public func resetToDefaults() {
        annotationHeight = Self.defaultAnnotationHeight
        annotationSpacing = Self.defaultAnnotationSpacing
        showAnnotations = Self.defaultShowAnnotations
        visibleTypes = Set(AnnotationType.allCases)
        filterText = ""
        notifySettingsChanged()
        notifyFilterChanged()
    }
}

// MARK: - AnnotationSection

/// SwiftUI view for configuring annotation display and filtering.
public struct AnnotationSection: View {
    @Bindable var viewModel: AnnotationSectionViewModel
    @State private var isExpanded = true
    @State private var showTypeFilter = false

    public init(viewModel: AnnotationSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                visibilityToggle

                if viewModel.showAnnotations {
                    displaySettings

                    Divider()
                        .padding(.vertical, 4)

                    typeFilterSection
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Annotation Style", systemImage: "tag")
                .font(.headline)
        }
    }

    // MARK: - Visibility Toggle

    @ViewBuilder
    private var visibilityToggle: some View {
        Toggle(isOn: $viewModel.showAnnotations) {
            Text("Show Annotations")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onChange(of: viewModel.showAnnotations) { _, _ in
            viewModel.notifySettingsChanged()
        }
    }

    // MARK: - Display Settings

    @ViewBuilder
    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Annotation height
            HStack {
                Text("Height")
                    .font(.callout)
                Spacer()
                Text("\(Int(viewModel.annotationHeight)) pt")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $viewModel.annotationHeight, in: 8...32, step: 2)
                .onChange(of: viewModel.annotationHeight) { _, _ in
                    viewModel.notifySettingsChanged()
                }

            // Row spacing
            HStack {
                Text("Spacing")
                    .font(.callout)
                Spacer()
                Text("\(Int(viewModel.annotationSpacing)) pt")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $viewModel.annotationSpacing, in: 0...10, step: 1)
                .onChange(of: viewModel.annotationSpacing) { _, _ in
                    viewModel.notifySettingsChanged()
                }
        }
    }

    // MARK: - Type Filter Section

    @ViewBuilder
    private var typeFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visible Types")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            DisclosureGroup(isExpanded: $showTypeFilter) {
                typeFilterGrid
            } label: {
                HStack {
                    Text("Type Visibility")
                        .font(.callout)
                    Spacer()
                    Text("\(viewModel.visibleTypes.count)/\(AnnotationType.allCases.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Type Filter Grid

    @ViewBuilder
    private var typeFilterGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Quick actions
            HStack {
                Button {
                    viewModel.showAllTypes()
                } label: {
                    Label("All", systemImage: "eye")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button {
                    viewModel.hideAllTypes()
                } label: {
                    Label("None", systemImage: "eye.slash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            // Common types grid
            let commonTypes: [AnnotationType] = [.gene, .cds, .exon, .mRNA, .promoter, .primer, .snp, .region]

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 4) {
                ForEach(commonTypes, id: \.self) { type in
                    typeFilterChip(type)
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func typeFilterChip(_ type: AnnotationType) -> some View {
        let isSelected = viewModel.visibleTypes.contains(type)

        Button {
            viewModel.toggleType(type)
        } label: {
            Text(type.displayName)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                .foregroundColor(isSelected ? .accentColor : .primary)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#if DEBUG
struct AnnotationSection_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                AnnotationSection(viewModel: AnnotationSectionViewModel())
            }
            .padding()
        }
        .frame(width: 280, height: 500)
    }
}
#endif
