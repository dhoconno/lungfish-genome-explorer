// MHCReferenceBundleDocumentSection.swift - Bundle metadata display for .lungfishmhcref
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// A single haplotype-definition row shown in the MHC reference bundle inspector,
/// pairing the definition's display name (species) with its analyzed loci.
struct MHCReferenceBundleDefinitionRow: Equatable {
    let displayName: String
    let loci: String
}

/// A revealable source artifact (reference FASTA, provenance, bundle folder).
struct MHCReferenceBundleArtifactRow: Equatable {
    let label: String
    let fileURL: URL?
}

/// View-model state describing an MHC amplicon reference bundle (`.lungfishmhcref`).
///
/// This metadata-only document has no viewport; selecting the bundle in the sidebar
/// populates this state and the Bundle inspector tab renders it.
struct MHCReferenceBundleDocumentState: Equatable {
    let name: String
    let schemaVersion: Int
    let kind: String
    let referenceCount: Int
    let haplotypeDefinitionCount: Int
    let defaultDefinitionID: String?
    let createdAt: String
    let definitionRows: [MHCReferenceBundleDefinitionRow]
    let artifactRows: [MHCReferenceBundleArtifactRow]
    let bundleURL: URL?
    let provenancePath: String?

    /// Labeled rows rendered in the summary disclosure group.
    var contextRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Kind", kind),
            ("Schema Version", "\(schemaVersion)"),
            ("References", "\(referenceCount)"),
            ("Haplotype Sets", "\(haplotypeDefinitionCount)"),
        ]
        if let defaultDefinitionID, !defaultDefinitionID.isEmpty {
            rows.append(("Default Set", defaultDefinitionID))
        }
        if !createdAt.isEmpty {
            rows.append(("Created", createdAt))
        }
        return rows
    }

    static func == (
        lhs: MHCReferenceBundleDocumentState,
        rhs: MHCReferenceBundleDocumentState
    ) -> Bool {
        lhs.name == rhs.name &&
            lhs.schemaVersion == rhs.schemaVersion &&
            lhs.kind == rhs.kind &&
            lhs.referenceCount == rhs.referenceCount &&
            lhs.haplotypeDefinitionCount == rhs.haplotypeDefinitionCount &&
            lhs.defaultDefinitionID == rhs.defaultDefinitionID &&
            lhs.createdAt == rhs.createdAt &&
            lhs.definitionRows == rhs.definitionRows &&
            lhs.artifactRows == rhs.artifactRows &&
            lhs.bundleURL == rhs.bundleURL &&
            lhs.provenancePath == rhs.provenancePath
    }
}

/// SwiftUI view rendering an MHC amplicon reference bundle's metadata in the
/// Inspector Bundle tab, mirroring the Multiple Sequence Alignment document idiom.
struct MHCReferenceBundleDocumentSection: View {
    let state: MHCReferenceBundleDocumentState

    @State private var isSummaryExpanded = true
    @State private var isDefinitionsExpanded = true
    @State private var isArtifactsExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            summarySection

            Divider()

            definitionsSection

            Divider()

            artifactSection
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.name)
                .font(.headline)
                .lineLimit(2)
            Text("MHC reference bundle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(state.referenceCount) reference\(state.referenceCount == 1 ? "" : "s") • \(state.haplotypeDefinitionCount) haplotype set\(state.haplotypeDefinitionCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summarySection: some View {
        DisclosureGroup("Bundle Summary", isExpanded: $isSummaryExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(state.contextRows.enumerated()), id: \.offset) { _, row in
                    contextRow(label: row.0, value: row.1)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var definitionsSection: some View {
        DisclosureGroup("Haplotype Definitions", isExpanded: $isDefinitionsExpanded) {
            if state.definitionRows.isEmpty {
                emptyMessage("This bundle does not embed haplotype definitions.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.definitionRows.enumerated()), id: \.offset) { _, row in
                        contextRow(label: row.displayName, value: row.loci)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var artifactSection: some View {
        DisclosureGroup("Source Artifacts", isExpanded: $isArtifactsExpanded) {
            if state.artifactRows.isEmpty {
                emptyMessage("No bundle artifacts are available.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.artifactRows.enumerated()), id: \.offset) { _, row in
                        artifactRow(row)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private func contextRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func artifactRow(_ row: MHCReferenceBundleArtifactRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fileURL = row.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                Button(row.label) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(.link)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Reveal in Finder")
                pathCaption(fileURL.path)
            } else {
                Text(row.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pathCaption(row.fileURL?.path ?? "Missing")
            }
        }
    }

    private func pathCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}
