// AnnotationSection.swift - Annotation display settings and filtering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// View model for the annotation section.
///
/// Manages annotation display settings like height, visibility, and filtering.
@MainActor
public class AnnotationSectionViewModel: ObservableObject {
    // MARK: - Default Values

    /// Default annotation track height in points
    public static let defaultAnnotationHeight: Double = 16

    /// Default spacing between annotation rows
    public static let defaultAnnotationSpacing: Double = 2

    /// Default visibility setting for annotations
    public static let defaultShowAnnotations: Bool = true

    // MARK: - Published Properties

    /// Annotation track height in points
    @Published public var annotationHeight: Double = defaultAnnotationHeight

    /// Spacing between annotation rows
    @Published public var annotationSpacing: Double = defaultAnnotationSpacing

    /// Whether to show annotations
    @Published public var showAnnotations: Bool = defaultShowAnnotations

    /// Types to show (nil = show all)
    @Published public var visibleTypes: Set<AnnotationType> = Set(AnnotationType.allCases)

    /// Search filter text
    @Published public var filterText: String = ""

    /// Callback when settings change
    public var onSettingsChanged: (() -> Void)?

    /// Callback when filter changes
    public var onFilterChanged: ((Set<AnnotationType>, String) -> Void)?

    public init() {}

    /// Toggles visibility of an annotation type
    public func toggleType(_ type: AnnotationType) {
        if visibleTypes.contains(type) {
            visibleTypes.remove(type)
        } else {
            visibleTypes.insert(type)
        }
        onFilterChanged?(visibleTypes, filterText)
    }

    /// Shows all annotation types
    public func showAllTypes() {
        visibleTypes = Set(AnnotationType.allCases)
        onFilterChanged?(visibleTypes, filterText)
    }

    /// Hides all annotation types
    public func hideAllTypes() {
        visibleTypes = []
        onFilterChanged?(visibleTypes, filterText)
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
        onSettingsChanged?()
        onFilterChanged?(visibleTypes, filterText)
    }
}

// MARK: - AnnotationSection

/// SwiftUI view for configuring annotation display and filtering.
public struct AnnotationSection: View {
    @ObservedObject var viewModel: AnnotationSectionViewModel
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

                    filterSection
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Annotations", systemImage: "tag")
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
            viewModel.onSettingsChanged?()
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
                    viewModel.onSettingsChanged?()
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
                    viewModel.onSettingsChanged?()
                }
        }
    }

    // MARK: - Filter Section

    @ViewBuilder
    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filter")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search annotations...", text: $viewModel.filterText)
                    .textFieldStyle(.plain)
                    .onChange(of: viewModel.filterText) { _, newValue in
                        viewModel.onFilterChanged?(viewModel.visibleTypes, newValue)
                    }
                if !viewModel.filterText.isEmpty {
                    Button {
                        viewModel.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            // Type filter button
            DisclosureGroup(isExpanded: $showTypeFilter) {
                typeFilterGrid
            } label: {
                HStack {
                    Text("Visible Types")
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
                Button("All") {
                    viewModel.showAllTypes()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button("None") {
                    viewModel.hideAllTypes()
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
