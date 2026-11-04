// TaxTriageProvenanceView.swift - SwiftUI popover with the provenance of a TaxTriage run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishWorkflow
import SwiftUI

// MARK: - TaxTriageProvenanceView

/// SwiftUI popover showing TaxTriage pipeline provenance metadata.
struct TaxTriageProvenanceView: View {
    let result: TaxTriageResult
    let config: TaxTriageConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TaxTriage Pipeline Provenance")
                .font(.headline)

            Divider()

            ForEach(TaxTriageProvenanceRows.runRows(result: result, config: config)) { provenanceRow($0.label, value: $0.value) }

            Divider()

            ForEach(TaxTriageProvenanceRows.settingRows(config: config)) { provenanceRow($0.label, value: $0.value) }

            if let dbPath = config.kraken2DatabasePath {
                provenanceRow("Database", value: dbPath.lastPathComponent)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }

    private func provenanceRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
