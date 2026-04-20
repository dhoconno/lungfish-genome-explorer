// SampleMetadataSection.swift — Inspector section for sample metadata display/edit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// Inspector section displaying imported sample metadata with inline editing.
struct SampleMetadataSection: View {
    @Bindable var store: SampleMetadataStore
    @State private var isExpanded = true
    @State private var editingCell: (sampleId: String, column: String)?
    @State private var editText: String = ""

    var body: some View {
        DisclosureGroup("Sample Metadata", isExpanded: $isExpanded) {
            if store.records.isEmpty {
                Text("No metadata imported")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                metadataTable
            }

            if !store.unmatchedRecords.isEmpty {
                unmatchedSection
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var metadataTable: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    Text("Sample")
                        .frame(width: 100, alignment: .leading)
                        .font(.system(size: 10, weight: .semibold))
                    ForEach(store.columnNames, id: \.self) { col in
                        Text(col)
                            .frame(width: 90, alignment: .leading)
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

                Divider()

                // Data rows
                ForEach(Array(store.matchedSampleIds.sorted()), id: \.self) { sampleId in
                    HStack(spacing: 0) {
                        Text(sampleId)
                            .frame(width: 100, alignment: .leading)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ForEach(store.columnNames, id: \.self) { col in
                            editableCell(sampleId: sampleId, column: col)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func editableCell(sampleId: String, column: String) -> some View {
        let value = store.records[sampleId]?[column] ?? ""
        let isEditing = editingCell?.sampleId == sampleId && editingCell?.column == column
        let identifier = metadataCellIdentifier(sampleId: sampleId, column: column)

        return Group {
            if isEditing {
                TextField("", text: $editText, onCommit: {
                    store.applyEdit(sampleId: sampleId, column: column, newValue: editText)
                    editingCell = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .frame(width: 90, alignment: .leading)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("\(sampleId) \(column) editor")
            } else {
                Button {
                    editText = value
                    editingCell = (sampleId, column)
                } label: {
                    Text(value)
                        .font(.system(size: 10))
                        .frame(width: 90, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("\(sampleId) \(column)")
                .help("Edit \(column) for \(sampleId)")
            }
        }
    }

    private func metadataCellIdentifier(sampleId: String, column: String) -> String {
        let safeSampleId = sampleId.lowercased().replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        let safeColumn = column.lowercased().replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        return "sample-metadata-\(safeSampleId)-\(safeColumn)"
    }

    private var unmatchedSection: some View {
        DisclosureGroup("Unmatched Samples (\(store.unmatchedRecords.count))") {
            ForEach(Array(store.unmatchedRecords.keys.sorted()), id: \.self) { sampleId in
                Text(sampleId)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
