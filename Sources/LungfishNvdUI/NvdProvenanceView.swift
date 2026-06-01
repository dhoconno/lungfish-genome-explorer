// NvdProvenanceView.swift — Pipeline metadata popover for NVD results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

/// SwiftUI view displaying NVD pipeline provenance metadata.
struct NvdProvenanceView: View {
    let manifest: NvdManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NVD Pipeline Info")
                .font(.headline)
            Divider()
            provenanceRow("Experiment", manifest.experiment)
            provenanceRow("Import Date", formatDate(manifest.importDate))
            provenanceRow("Format Version", manifest.formatVersion)
            provenanceRow("Samples", "\(manifest.sampleCount)")
            provenanceRow("Contigs", "\(manifest.contigCount)")
            provenanceRow("Hits", "\(manifest.hitCount)")
            if let dbVersion = manifest.blastDbVersion {
                provenanceRow("BLAST DB Version", dbVersion)
            }
            if let runId = manifest.snakemakeRunId {
                provenanceRow("Snakemake Run ID", runId)
            }
            provenanceRow("Source Directory", manifest.sourceDirectoryPath)
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
