// AnnotationSection.swift - Annotation display settings and filtering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "AnnotationSection")

/// View model for the annotation section.
///
/// Manages annotation display settings like height, visibility, and filtering.
@Observable
@MainActor
public final class AnnotationSectionViewModel {
    // MARK: - Default Values

    /// Default annotation track height in points
    public static var defaultAnnotationHeight: Double { AppSettings.shared.defaultAnnotationHeight }

    /// Default spacing between annotation rows
    public static var defaultAnnotationSpacing: Double { AppSettings.shared.defaultAnnotationSpacing }

    /// Default visibility setting for annotations
    public static let defaultShowAnnotations: Bool = true

    // MARK: - Observable Properties

    /// Annotation track height in points
    public var annotationHeight: Double = AppSettings.shared.defaultAnnotationHeight

    /// Spacing between annotation rows
    public var annotationSpacing: Double = AppSettings.shared.defaultAnnotationSpacing

    /// Whether to show annotations
    public var showAnnotations: Bool = true

    /// Types to show (nil = show all)
    public var visibleTypes: Set<AnnotationType> = Set(AnnotationType.allCases)

    /// Search filter text
    public var filterText: String = ""

    // MARK: - Variant Properties

    /// Whether to show variants
    public var showVariants: Bool = true

    /// Visible variant types (e.g. "SNP", "INS", "DEL", "MNP", "COMPLEX")
    public var visibleVariantTypes: Set<String> = []

    /// Search filter for variant IDs
    public var variantFilterText: String = ""

    /// All known variant types (populated when bundle loads)
    public var availableVariantTypes: [String] = []

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
        logger.debug("notifySettingsChanged: show=\(self.showAnnotations, privacy: .public) height=\(self.annotationHeight, privacy: .public) spacing=\(self.annotationSpacing, privacy: .public) callback=\(self.onSettingsChanged == nil ? "nil" : "set", privacy: .public)")
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
        logger.debug("notifyFilterChanged: visibleTypes=\(self.visibleTypes.count, privacy: .public) filter='\(self.filterText, privacy: .public)' callback=\(self.onFilterChanged == nil ? "nil" : "set", privacy: .public)")
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
        logger.debug("toggleType: type=\(type.rawValue, privacy: .public)")
        if visibleTypes.contains(type) {
            visibleTypes.remove(type)
        } else {
            visibleTypes.insert(type)
        }
        notifyFilterChanged()
    }

    /// Shows all annotation types
    public func showAllTypes() {
        logger.debug("showAllTypes")
        visibleTypes = Set(AnnotationType.allCases)
        notifyFilterChanged()
    }

    /// Hides all annotation types
    public func hideAllTypes() {
        logger.debug("hideAllTypes")
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
        showVariants = true
        visibleVariantTypes = Set(availableVariantTypes)
        variantFilterText = ""
        notifySettingsChanged()
        notifyFilterChanged()
        notifyVariantFilterChanged()
    }

    // MARK: - Variant Notifications

    /// Notifies listeners that variant filter settings changed.
    public func notifyVariantFilterChanged() {
        NotificationCenter.default.post(
            name: .variantFilterChanged,
            object: self,
            userInfo: [
                NotificationUserInfoKey.showVariants: showVariants,
                NotificationUserInfoKey.visibleVariantTypes: visibleVariantTypes,
                NotificationUserInfoKey.variantFilterText: variantFilterText
            ]
        )
    }

    /// Toggles visibility of a variant type
    public func toggleVariantType(_ type: String) {
        if visibleVariantTypes.contains(type) {
            visibleVariantTypes.remove(type)
        } else {
            visibleVariantTypes.insert(type)
        }
        notifyVariantFilterChanged()
    }

    /// Shows all variant types
    public func showAllVariantTypes() {
        visibleVariantTypes = Set(availableVariantTypes)
        notifyVariantFilterChanged()
    }

    /// Hides all variant types
    public func hideAllVariantTypes() {
        visibleVariantTypes = []
        notifyVariantFilterChanged()
    }

    /// Updates available variant types and initializes visibility for first load.
    ///
    /// Keeps existing visibility choices when possible, while ensuring
    /// newly discovered variant types are visible by default.
    public func setAvailableVariantTypes(_ types: [String]) {
        let normalized = types.sorted()
        let newTypeSet = Set(normalized)
        availableVariantTypes = normalized

        if visibleVariantTypes.isEmpty {
            visibleVariantTypes = newTypeSet
        } else {
            visibleVariantTypes.formUnion(newTypeSet)
        }
        notifyVariantFilterChanged()
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

                if !viewModel.availableVariantTypes.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    variantFilterSection
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Annotation Style")
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

    // MARK: - Variant Filter Section

    @ViewBuilder
    private var variantFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $viewModel.showVariants) {
                Text("Show Variants")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: viewModel.showVariants) { _, _ in
                viewModel.notifyVariantFilterChanged()
            }

            if viewModel.showVariants {
                HStack {
                    Button {
                        viewModel.showAllVariantTypes()
                    } label: {
                        Label("All", systemImage: "eye")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    Button {
                        viewModel.hideAllVariantTypes()
                    } label: {
                        Label("None", systemImage: "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 4) {
                    ForEach(viewModel.availableVariantTypes, id: \.self) { vtype in
                        variantTypeChip(vtype)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func variantTypeChip(_ vtype: String) -> some View {
        let isSelected = viewModel.visibleVariantTypes.contains(vtype)

        Button {
            viewModel.toggleVariantType(vtype)
        } label: {
            Text(vtype)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isSelected ? Color.orange.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                .foregroundColor(isSelected ? .orange : .primary)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.orange : Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
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
