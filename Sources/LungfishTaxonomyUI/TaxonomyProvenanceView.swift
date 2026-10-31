// TaxonomyProvenanceView.swift - Provenance disclosure view for classification results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

// MARK: - TaxonomyProvenanceView

/// A SwiftUI view displaying provenance metadata for a classification result.
///
/// Shows the tool version, database, preset, confidence, runtime, and input file
/// that produced the classification. Presented as a popover from the taxonomy
/// view controller's action bar.
///
/// ## Layout
///
/// ```
/// +------------------------------------+
/// | Classification Provenance          |
/// +------------------------------------+
/// | Tool:       Kraken2 2.1.3          |
/// | Database:   Standard-8             |
/// |             /path/to/db            |
/// | Confidence: 0.20                   |
/// | Hit Groups: 2                      |
/// | Threads:    4                      |
/// | Mem. Map:   No                     |
/// | Runtime:    5.2s                   |
/// | Input:      reads.fastq            |
/// +------------------------------------+
/// ```
struct TaxonomyProvenanceView: View {

    /// The classification result whose provenance to display.
    let result: ClassificationResult

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("Classification Provenance")
                    .font(.headline)
            }
            .padding(.bottom, 4)

            Divider()

            // Provenance rows
            provenanceRow(label: "Tool", value: "Kraken2 \(result.toolVersion)")
            provenanceRow(label: "Database", value: result.config.databaseName)
            provenanceRow(
                label: "",
                value: result.config.databasePath.path,
                isPath: true
            )
            provenanceRow(
                label: "Confidence",
                value: String(format: "%.2f", result.config.confidence)
            )
            provenanceRow(
                label: "Hit Groups",
                value: "\(result.config.minimumHitGroups)"
            )
            provenanceRow(label: "Threads", value: "\(result.config.threads)")
            provenanceRow(
                label: "Mem. Mapping",
                value: result.config.memoryMapping ? "Yes" : "No"
            )
            provenanceRow(
                label: "Runtime",
                value: String(format: "%.1fs", result.runtime)
            )

            if let inputFile = result.config.inputFiles.first {
                provenanceRow(
                    label: "Input",
                    value: inputFile.lastPathComponent
                )
            }

            if result.config.inputFiles.count > 1 {
                provenanceRow(
                    label: "",
                    value: "+ \(result.config.inputFiles.count - 1) more file(s)"
                )
            }

            if result.brackenURL != nil {
                provenanceRow(label: "Bracken", value: "Yes (profiling enabled)")
            }

            if let provenanceId = result.provenanceId {
                provenanceRow(
                    label: "Run ID",
                    value: provenanceId.uuidString.prefix(8).lowercased()
                )
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Row Builder

    /// Builds a single label-value row for the provenance display.
    ///
    /// - Parameters:
    ///   - label: The field label (e.g., "Tool"). Empty string for continuation lines.
    ///   - value: The field value.
    ///   - isPath: Whether to style the value as a file path (smaller, monospaced).
    private func provenanceRow(
        label: String,
        value: some StringProtocol,
        isPath: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if !label.isEmpty {
                Text(label + ":")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            } else {
                Spacer()
                    .frame(width: 88) // 80 + 8 spacing
            }

            if isPath {
                Text(String(value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text(String(value))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
        }
    }
}
