// ClassifierExtractionSheet.swift — Extraction confirmation for non-Kraken2 classifiers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// Configuration for classifier-based read extraction.
struct ClassifierExtractionConfig {
    let selectedItems: [String]
    let sourceDescription: String
    let outputName: String
    let extractionMethod: ExtractionMethod

    enum ExtractionMethod {
        case samtoolsView(bamURL: URL, regions: [String])
        case databaseQuery(taxIds: [Int], sampleId: String)
    }
}

/// SwiftUI sheet confirming a read extraction from a classifier result.
struct ClassifierExtractionSheet: View {
    let selectedItems: [String]
    let sourceDescription: String
    @State private var outputName: String
    let onExtract: (String) -> Void
    let onCancel: () -> Void

    init(selectedItems: [String], sourceDescription: String, suggestedName: String, onExtract: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.selectedItems = selectedItems
        self.sourceDescription = sourceDescription
        self._outputName = State(initialValue: suggestedName)
        self.onExtract = onExtract
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extract FASTQ")
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Selected (\(selectedItems.count)):")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(selectedItems, id: \.self) { item in
                            Text(item)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            HStack {
                Text("Source:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sourceDescription)
                    .font(.system(size: 11))
            }

            HStack {
                Text("Output name:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $outputName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Extract") { onExtract(outputName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(outputName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
