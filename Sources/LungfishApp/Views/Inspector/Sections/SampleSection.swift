// SampleSection.swift - Inspector section for sample display controls
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

// MARK: - SampleSectionViewModel

/// View model for the sample display controls inspector section.
///
/// Manages genotype row visibility, row height mode, and sample
/// sort/filter state. Changes are propagated via notification to the viewer.
@Observable
@MainActor
public final class SampleSectionViewModel {

    private static func makeDefaultDisplayState() -> SampleDisplayState {
        var state = SampleDisplayState()
        state.colorThemeName = AppSettings.shared.variantColorThemeName
        return state
    }

    // MARK: - Properties

    /// Current sample display state (row visibility, height, sort, filter).
    var displayState: SampleDisplayState = makeDefaultDisplayState()

    /// Total number of samples in the variant database.
    var sampleCount: Int = 0

    /// All sample names from the VCF.
    var sampleNames: [String] = []

    /// Available metadata field names for sorting/filtering.
    var metadataFields: [String] = []

    /// Per-sample metadata dictionaries.
    var sampleMetadata: [String: [String: String]] = [:]

    /// Source filenames keyed by sample name.
    var sourceFiles: [String: String] = [:]

    /// Whether variant data is available (controls section visibility).
    var hasVariantData: Bool = false

    /// Whether the section is expanded.
    var isExpanded: Bool = true

    /// The sample currently being edited (nil means none).
    var editingSample: String?

    /// Key-value pairs being edited for the current sample.
    var editingMetadata: [(key: String, value: String)] = []

    /// New key name being typed in the metadata editor.
    var newMetadataKey: String = ""

    /// New value being typed in the metadata editor.
    var newMetadataValue: String = ""

    /// Callback to persist metadata changes to the database.
    var onSaveMetadata: ((_ sampleName: String, _ metadata: [String: String]) -> Void)?

    /// Callback to import metadata from a file.
    var onImportMetadata: (() -> Void)?

    // MARK: - Callbacks

    /// Called when sample display state changes.
    var onDisplayStateChanged: ((SampleDisplayState) -> Void)?

    // MARK: - Computed Properties

    /// Number of currently visible samples.
    var visibleSampleCount: Int {
        sampleNames.filter { !displayState.hiddenSamples.contains($0) }.count
    }

    /// Whether any samples are hidden.
    var hasHiddenSamples: Bool {
        !displayState.hiddenSamples.isEmpty
    }

    // MARK: - Methods

    /// Updates the section with sample data from a variant database.
    func update(
        sampleCount: Int,
        sampleNames: [String],
        metadataFields: [String],
        sampleMetadata: [String: [String: String]] = [:],
        sourceFiles: [String: String] = [:]
    ) {
        self.sampleCount = sampleCount
        self.sampleNames = sampleNames
        self.metadataFields = metadataFields
        self.sampleMetadata = sampleMetadata
        self.sourceFiles = sourceFiles
        self.hasVariantData = sampleCount > 0
    }

    /// Clears all sample data (e.g., when bundle is unloaded).
    func clear() {
        sampleCount = 0
        sampleNames = []
        metadataFields = []
        sampleMetadata = [:]
        sourceFiles = [:]
        hasVariantData = false
        displayState = Self.makeDefaultDisplayState()
        editingSample = nil
    }

    /// Begins editing metadata for a sample.
    func beginEditingMetadata(for sampleName: String) {
        editingSample = sampleName
        let metadata = sampleMetadata[sampleName] ?? [:]
        editingMetadata = metadata.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: $0.value) }
        newMetadataKey = ""
        newMetadataValue = ""
    }

    /// Saves the current metadata edits.
    func saveMetadataEdits() {
        guard let sampleName = editingSample else { return }
        var metadata: [String: String] = [:]
        for pair in editingMetadata where !pair.key.isEmpty {
            metadata[pair.key] = pair.value
        }
        sampleMetadata[sampleName] = metadata
        onSaveMetadata?(sampleName, metadata)
        editingSample = nil

        // Update metadata fields
        var allFields = Set<String>()
        for (_, meta) in sampleMetadata {
            allFields.formUnion(meta.keys)
        }
        metadataFields = allFields.sorted()
    }

    /// Cancels metadata editing.
    func cancelMetadataEdits() {
        editingSample = nil
        editingMetadata = []
    }

    /// Adds a new key-value pair to the editing metadata.
    func addMetadataField() {
        guard !newMetadataKey.isEmpty else { return }
        editingMetadata.append((key: newMetadataKey, value: newMetadataValue))
        newMetadataKey = ""
        newMetadataValue = ""
    }

    /// Removes a metadata field at the given index.
    func removeMetadataField(at index: Int) {
        guard index < editingMetadata.count else { return }
        editingMetadata.remove(at: index)
    }

    /// Toggles genotype row visibility and notifies listeners.
    func toggleGenotypeRows() {
        displayState.showGenotypeRows.toggle()
        notifyStateChanged()
    }

    /// Sets the row height and notifies listeners.
    func setRowHeight(_ height: CGFloat) {
        displayState.rowHeight = max(2, min(30, height))
        notifyStateChanged()
    }

    /// Toggles the variant summary bar visibility and notifies listeners.
    func toggleSummaryBar() {
        displayState.showSummaryBar.toggle()
        notifyStateChanged()
    }

    /// Sets the color theme name and notifies listeners.
    func setColorTheme(_ themeName: String) {
        displayState.colorThemeName = themeName
        notifyStateChanged()
    }

    /// Sets the summary bar height and notifies listeners.
    func setSummaryBarHeight(_ height: CGFloat) {
        displayState.summaryBarHeight = max(10, min(60, height))
        notifyStateChanged()
    }

    /// Toggles visibility of a specific sample.
    func toggleSampleVisibility(_ name: String) {
        if displayState.hiddenSamples.contains(name) {
            displayState.hiddenSamples.remove(name)
        } else {
            displayState.hiddenSamples.insert(name)
        }
        notifyStateChanged()
    }

    /// Shows all samples.
    func showAllSamples() {
        displayState.hiddenSamples.removeAll()
        notifyStateChanged()
    }

    /// Hides all samples.
    func hideAllSamples() {
        displayState.hiddenSamples = Set(sampleNames)
        notifyStateChanged()
    }

    /// Adds a sort field.
    func addSortField(_ field: String, ascending: Bool = true) {
        // Remove existing sort on same field
        displayState.sortFields.removeAll { $0.field == field }
        displayState.sortFields.append(SortField(field: field, ascending: ascending))
        notifyStateChanged()
    }

    /// Removes a sort field.
    func removeSortField(at index: Int) {
        guard index < displayState.sortFields.count else { return }
        displayState.sortFields.remove(at: index)
        notifyStateChanged()
    }

    /// Clears all sort fields.
    func clearSortFields() {
        displayState.sortFields.removeAll()
        notifyStateChanged()
    }

    /// Adds a sample filter.
    func addFilter(field: String, op: FilterOp, value: String) {
        let filter = SampleFilter(field: field, op: op, value: value)
        displayState.filters.append(filter)
        notifyStateChanged()
    }

    /// Removes a filter at the given index.
    func removeFilter(at index: Int) {
        guard index < displayState.filters.count else { return }
        displayState.filters.remove(at: index)
        notifyStateChanged()
    }

    /// Clears all filters.
    func clearFilters() {
        displayState.filters.removeAll()
        notifyStateChanged()
    }

    /// Resets display state to defaults.
    func resetToDefaults() {
        displayState = Self.makeDefaultDisplayState()
        notifyStateChanged()
    }

    /// Notifies listeners of display state changes.
    private func notifyStateChanged() {
        if let onDisplayStateChanged {
            onDisplayStateChanged(displayState)
            return
        }

        NotificationCenter.default.post(
            name: .sampleDisplayStateChanged,
            object: self,
            userInfo: [
                NotificationUserInfoKey.sampleDisplayState: displayState
            ]
        )
    }
}

// MARK: - SampleSection View

/// SwiftUI section showing sample display controls when variant data is available.
///
/// Provides controls for genotype row visibility, row height mode,
/// sample visibility toggles, and sort/filter configuration.
public struct SampleSection: View {
    @Bindable var viewModel: SampleSectionViewModel

    public var body: some View {
        if viewModel.hasVariantData {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    sampleSummary
                    Divider()
                    genotypeRowControls
                }
            } label: {
                Label("Sample Display", systemImage: "person.3")
                    .font(.headline)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var sampleSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text("\(viewModel.sampleCount)")
                    .font(.system(.body, design: .monospaced))
            }
            if viewModel.hasHiddenSamples {
                HStack {
                    Text("Visible")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text("\(viewModel.visibleSampleCount) of \(viewModel.sampleCount)")
                        .font(.system(.body, design: .monospaced))
                }
            }

            Text("Use the Samples tab in the bottom drawer to manage visibility and metadata.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var genotypeRowControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.displayState.showGenotypeRows },
                set: { _ in viewModel.toggleGenotypeRows() }
            )) {
                Text("Show Genotype Rows")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if viewModel.displayState.showGenotypeRows {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Row Height")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(viewModel.displayState.rowHeight))px")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { viewModel.displayState.rowHeight },
                            set: { viewModel.setRowHeight($0) }
                        ),
                        in: 2...30,
                        step: 1
                    )
                    .controlSize(.small)
                }
            }

            Toggle(isOn: Binding(
                get: { viewModel.displayState.showSummaryBar },
                set: { _ in viewModel.toggleSummaryBar() }
            )) {
                Text("Show Summary Bar")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if viewModel.displayState.showSummaryBar {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bar Height")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(viewModel.displayState.summaryBarHeight))px")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { viewModel.displayState.summaryBarHeight },
                            set: { viewModel.setSummaryBarHeight($0) }
                        ),
                        in: 10...60,
                        step: 1
                    )
                    .controlSize(.small)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Color Theme")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { viewModel.displayState.colorThemeName },
                    set: { viewModel.setColorTheme($0) }
                )) {
                    ForEach(VariantColorTheme.allBuiltIn, id: \.name) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
        }
    }
}
