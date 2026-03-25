// FASTQMetadataSection.swift - Inspector section for FASTQ sample metadata editing
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

// MARK: - FASTQMetadataSectionViewModel

/// View model for FASTQ sample metadata editing in the Inspector.
///
/// Manages loading, editing, and saving PHA4GE-aligned metadata for
/// individual `.lungfishfastq` bundles. Follows the pattern established
/// by `SampleSectionViewModel`.
@Observable
@MainActor
public final class FASTQMetadataSectionViewModel {

    /// The loaded metadata, if any.
    var metadata: FASTQSampleMetadata?

    /// The bundle URL currently displayed.
    var bundleURL: URL?

    /// Whether the section is expanded.
    var isExpanded: Bool = true

    /// Whether the user is currently editing.
    var isEditing: Bool = false

    /// Whether the "Recommended" disclosure group is expanded.
    var showRecommended: Bool = true

    /// Whether the "Optional" disclosure group is expanded.
    var showOptional: Bool = false

    /// Whether the "Custom Fields" disclosure group is expanded.
    var showCustomFields: Bool = false

    /// Whether metadata is available (controls section visibility).
    var hasMetadata: Bool { metadata != nil }

    // MARK: - Editing State

    /// Editable copy of metadata (used during edit mode).
    var editingMetadata: FASTQSampleMetadata?

    /// New custom field key being typed.
    var newCustomKey: String = ""

    /// New custom field value being typed.
    var newCustomValue: String = ""

    // MARK: - Callbacks

    /// Callback to persist metadata changes.
    var onSave: ((_ bundleURL: URL, _ metadata: FASTQSampleMetadata) -> Void)?

    // MARK: - Methods

    /// Loads metadata from a FASTQ bundle.
    func load(from bundleURL: URL) {
        self.bundleURL = bundleURL
        let sampleName = bundleURL.deletingPathExtension().lastPathComponent

        if let csvMeta = FASTQBundleCSVMetadata.load(from: bundleURL) {
            self.metadata = FASTQSampleMetadata(from: csvMeta, fallbackName: sampleName)
        } else {
            // No metadata yet; create a default
            self.metadata = FASTQSampleMetadata(sampleName: sampleName)
        }

        self.isEditing = false
        self.editingMetadata = nil
    }

    /// Clears the metadata display.
    func clear() {
        metadata = nil
        bundleURL = nil
        isEditing = false
        editingMetadata = nil
    }

    /// Begins editing the current metadata.
    func beginEditing() {
        guard let metadata else { return }
        editingMetadata = metadata
        isEditing = true
    }

    /// Saves the current edits.
    func save() {
        guard let bundleURL, var editingMetadata else { return }

        // Add pending custom field if non-empty
        if !newCustomKey.isEmpty {
            editingMetadata.customFields[newCustomKey] = newCustomValue
            newCustomKey = ""
            newCustomValue = ""
        }

        metadata = editingMetadata
        isEditing = false

        // Persist
        let legacyCSV = editingMetadata.toLegacyCSV()
        try? FASTQBundleCSVMetadata.save(legacyCSV, to: bundleURL)

        onSave?(bundleURL, editingMetadata)
        self.editingMetadata = nil
    }

    /// Cancels editing and reverts to the original metadata.
    func cancelEditing() {
        editingMetadata = nil
        isEditing = false
        newCustomKey = ""
        newCustomValue = ""
    }

    /// Adds a new custom field.
    func addCustomField() {
        guard !newCustomKey.isEmpty else { return }
        editingMetadata?.customFields[newCustomKey] = newCustomValue
        newCustomKey = ""
        newCustomValue = ""
    }

    /// Removes a custom field.
    func removeCustomField(_ key: String) {
        editingMetadata?.customFields.removeValue(forKey: key)
    }
}

// MARK: - FASTQMetadataSection View

/// SwiftUI section showing FASTQ sample metadata in the Inspector's Document tab.
///
/// Displays PHA4GE-aligned fields in disclosure groups: Required, Recommended,
/// Optional, and Custom Fields. Supports inline editing with Edit/Save/Cancel.
public struct FASTQMetadataSection: View {
    @Bindable var viewModel: FASTQMetadataSectionViewModel

    public var body: some View {
        if viewModel.hasMetadata {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    editToolbar
                    Divider()

                    if viewModel.isEditing, let _ = viewModel.editingMetadata {
                        editingContent
                    } else if let meta = viewModel.metadata {
                        readOnlyContent(meta)
                    }
                }
            } label: {
                Label("Sample Metadata", systemImage: "tag")
                    .font(.headline)
            }
        }
    }

    // MARK: - Edit Toolbar

    @ViewBuilder
    private var editToolbar: some View {
        HStack {
            if viewModel.isEditing {
                Button("Save") { viewModel.save() }
                    .controlSize(.small)
                Button("Cancel") { viewModel.cancelEditing() }
                    .controlSize(.small)
            } else {
                Button("Edit") { viewModel.beginEditing() }
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    // MARK: - Read-Only Content

    @ViewBuilder
    private func readOnlyContent(_ meta: FASTQSampleMetadata) -> some View {
        // Required field
        metadataRow("Sample Name", value: meta.sampleName)
        metadataRow("Sample Role", value: meta.sampleRole.displayLabel)

        // Recommended fields
        if hasRecommendedFields(meta) {
            DisclosureGroup("Recommended Fields", isExpanded: $viewModel.showRecommended) {
                VStack(alignment: .leading, spacing: 4) {
                    optionalRow("Sample Type", value: meta.sampleType)
                    optionalRow("Collection Date", value: meta.collectionDate)
                    optionalRow("Geographic Location", value: meta.geoLocName)
                    optionalRow("Host", value: meta.host)
                    optionalRow("Host Disease", value: meta.hostDisease)
                    optionalRow("Purpose", value: meta.purposeOfSequencing)
                    optionalRow("Instrument", value: meta.sequencingInstrument)
                    optionalRow("Library Strategy", value: meta.libraryStrategy)
                    optionalRow("Collected By", value: meta.sampleCollectedBy)
                    optionalRow("Organism", value: meta.organism)
                }
            }
            .font(.caption)
        }

        // Batch context fields
        if hasBatchFields(meta) {
            DisclosureGroup("Batch Context", isExpanded: $viewModel.showOptional) {
                VStack(alignment: .leading, spacing: 4) {
                    optionalRow("Patient ID", value: meta.patientId)
                    optionalRow("Run ID", value: meta.runId)
                    optionalRow("Batch ID", value: meta.batchId)
                    optionalRow("Plate Position", value: meta.platePosition)
                }
            }
            .font(.caption)
        }

        // Custom fields
        if !meta.customFields.isEmpty {
            DisclosureGroup("Custom Fields (\(meta.customFields.count))", isExpanded: $viewModel.showCustomFields) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(meta.customFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        metadataRow(key, value: value)
                    }
                }
            }
            .font(.caption)
        }
    }

    // MARK: - Editing Content

    @ViewBuilder
    private var editingContent: some View {
        if viewModel.editingMetadata != nil {
            // Required
            editableTextField("Sample Name", text: Binding(
                get: { viewModel.editingMetadata?.sampleName ?? "" },
                set: { viewModel.editingMetadata?.sampleName = $0 }
            ))

            Picker("Sample Role", selection: Binding(
                get: { viewModel.editingMetadata?.sampleRole ?? .testSample },
                set: { viewModel.editingMetadata?.sampleRole = $0 }
            )) {
                ForEach(SampleRole.allCases, id: \.self) { role in
                    Text(role.displayLabel).tag(role)
                }
            }
            .controlSize(.small)

            // Recommended
            DisclosureGroup("Recommended Fields", isExpanded: $viewModel.showRecommended) {
                VStack(alignment: .leading, spacing: 4) {
                    editableOptionalField("Sample Type", binding: editingBinding(\.sampleType))
                    editableOptionalField("Collection Date", binding: editingBinding(\.collectionDate))
                    editableOptionalField("Geographic Location", binding: editingBinding(\.geoLocName))
                    editableOptionalField("Host", binding: editingBinding(\.host))
                    editableOptionalField("Host Disease", binding: editingBinding(\.hostDisease))
                    editableOptionalField("Purpose", binding: editingBinding(\.purposeOfSequencing))
                    editableOptionalField("Instrument", binding: editingBinding(\.sequencingInstrument))
                    editableOptionalField("Library Strategy", binding: editingBinding(\.libraryStrategy))
                    editableOptionalField("Collected By", binding: editingBinding(\.sampleCollectedBy))
                    editableOptionalField("Organism", binding: editingBinding(\.organism))
                }
            }
            .font(.caption)

            // Batch context
            DisclosureGroup("Batch Context", isExpanded: $viewModel.showOptional) {
                VStack(alignment: .leading, spacing: 4) {
                    editableOptionalField("Patient ID", binding: editingBinding(\.patientId))
                    editableOptionalField("Run ID", binding: editingBinding(\.runId))
                    editableOptionalField("Batch ID", binding: editingBinding(\.batchId))
                    editableOptionalField("Plate Position", binding: editingBinding(\.platePosition))
                }
            }
            .font(.caption)

            // Custom fields
            DisclosureGroup("Custom Fields", isExpanded: $viewModel.showCustomFields) {
                VStack(alignment: .leading, spacing: 4) {
                    let sortedKeys = (viewModel.editingMetadata?.customFields ?? [:]).keys.sorted()
                    ForEach(sortedKeys, id: \.self) { key in
                        HStack {
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            TextField("Value", text: Binding(
                                get: { viewModel.editingMetadata?.customFields[key] ?? "" },
                                set: { viewModel.editingMetadata?.customFields[key] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            Button(role: .destructive) {
                                viewModel.removeCustomField(key)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                        }
                    }

                    // Add new custom field
                    HStack {
                        TextField("Key", text: $viewModel.newCustomKey)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 80)
                        TextField("Value", text: $viewModel.newCustomValue)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button {
                            viewModel.addCustomField()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .disabled(viewModel.newCustomKey.isEmpty)
                    }
                }
            }
            .font(.caption)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func optionalRow(_ label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            metadataRow(label, value: value)
        }
    }

    @ViewBuilder
    private func editableTextField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func editableOptionalField(_ label: String, binding: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            TextField(label, text: binding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    /// Creates a binding for an optional String property on editingMetadata.
    private func editingBinding(_ keyPath: WritableKeyPath<FASTQSampleMetadata, String?>) -> Binding<String> {
        Binding(
            get: { viewModel.editingMetadata?[keyPath: keyPath] ?? "" },
            set: { newValue in
                viewModel.editingMetadata?[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func hasRecommendedFields(_ meta: FASTQSampleMetadata) -> Bool {
        meta.sampleType != nil || meta.collectionDate != nil || meta.geoLocName != nil ||
        meta.host != nil || meta.hostDisease != nil || meta.purposeOfSequencing != nil ||
        meta.sequencingInstrument != nil || meta.libraryStrategy != nil ||
        meta.sampleCollectedBy != nil || meta.organism != nil
    }

    private func hasBatchFields(_ meta: FASTQSampleMetadata) -> Bool {
        meta.patientId != nil || meta.runId != nil || meta.batchId != nil || meta.platePosition != nil
    }
}
