// CzIdProvenanceView.swift - Pipeline metadata popover for CZ-ID imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

struct CzIdProvenanceView: View {
    let manifest: CzIdImportManifest
    let bundleURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CZ-ID Pipeline Info")
                .font(.headline)
            Divider()
            provenanceRow("Sample", manifest.sampleName)
            if let projectId = manifest.projectId, !projectId.isEmpty {
                provenanceRow("Project", projectId)
            }
            provenanceRow("Format Version", manifest.schemaVersion)
            provenanceRow("Rows", "\(manifest.rowCount)")
            provenanceRow("Pipeline", manifest.pipelineVersion ?? "unknown")
            provenanceRow("NT Database", manifest.ntDatabaseVersion ?? "unknown")
            provenanceRow("NR Database", manifest.nrDatabaseVersion ?? "unknown")
            if let bundleURL {
                provenanceRow("Bundle", bundleURL.path)
            }
            if !manifest.sourceFiles.isEmpty {
                Divider()
                Text("Source Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(manifest.sourceFiles.enumerated()), id: \.offset) { _, source in
                    provenanceRow("File", source.path)
                }
            }
        }
        .padding(12)
        .frame(width: 360)
        .help("viewport.CzIdResultViewer")
    }

    private func provenanceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 95, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
