// NaoMgsProvenanceView.swift — Pipeline metadata popover for NAO-MGS results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

/// SwiftUI view displaying NAO-MGS pipeline provenance metadata.
struct NaoMgsProvenanceView: View {
    let manifest: NaoMgsManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NAO-MGS Pipeline Info")
                .font(.headline)
            Divider()
            provenanceRow("Source", manifest.sourceFilePath)
            provenanceRow("Import Date", formatDate(manifest.importDate))
            provenanceRow("Format Version", manifest.formatVersion)
            provenanceRow("Hit Count", "\(manifest.hitCount)")
            provenanceRow("Taxon Count", "\(manifest.taxonCount)")
            if let top = manifest.topTaxon {
                provenanceRow("Top Taxon", top)
            }
            if let version = manifest.workflowVersion {
                provenanceRow("Workflow Version", version)
            }
            provenanceRow("Fetched Accessions", "\(manifest.fetchedAccessions.count)")
        }
        .padding(12)
        .frame(width: 320)
    }

    private func provenanceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
