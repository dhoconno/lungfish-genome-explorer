// RNASeqReferenceSetsSection.swift - "RNA-seq Reference Sets" in Plugin Manager > Databases (2026-11-26)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import LungfishWorkflow
import SwiftUI

enum RNASeqReferenceSetsAccessibilityID {
    static let section = "plugin-manager-rnaseq-reference-sets"
    static func download(_ id: String) -> String { "plugin-manager-rnaseq-reference-download-\(id)" }
    static func status(_ id: String) -> String { "plugin-manager-rnaseq-reference-status-\(id)" }
}

/// The RNA-seq reference rows, below the metagenomics databases and outside their list, so they show while that
/// catalog loads or is empty (ARCH trap 6). The row needs no RAM badge, since the Kraken2 recommendation does not
/// apply to it (UX trap 6).
struct RNASeqReferenceSetsSection: View {
    @Bindable var model: RNASeqReferenceCatalogModel

    /// The section draws the divider above it and the one the footer had, so the tab's file keeps its size.
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            rows
            Divider()
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RNA-seq Reference Sets")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(Color.lungfishSecondaryText)
            ForEach(model.rows) { row in
                rowView(row)
            }
            if let refusal = model.memoryRefusal ?? model.toolsRefusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lungfishCanvasBackground)
        .accessibilityIdentifier(RNASeqReferenceSetsAccessibilityID.section)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .managedResourcesDidChange)) { _ in
            Task { await model.refresh() }
        }
    }

    private func rowView(_ row: RNASeqReferenceCatalogModel.Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.entry.title).font(.body)
                Text(ReferenceSetCatalog.description)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                Text(model.needWords(row.entry))
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                if model.installing.contains(row.id) {
                    if let fraction = model.fraction[row.id] {
                        ProgressView(value: fraction).tint(.lungfishCreamsicleFallback)
                    }
                    if let message = model.message[row.id] {
                        Text(message).font(.caption).foregroundStyle(Color.lungfishSecondaryText).lineLimit(2)
                    }
                }
                if let failure = model.failure[row.id] {
                    Text(failure).font(.caption).foregroundStyle(Color.lungfishDangerFallback).lineLimit(2)
                        .help(failure)
                }
            }
            Spacer()
            action(row)
        }
        .padding(10)
        .background(Color.lungfishCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func action(_ row: RNASeqReferenceCatalogModel.Row) -> some View {
        if model.installing.contains(row.id) {
            Button(role: .cancel) {
                model.cancel(row.id)
            } label: { Text("Cancel") }
            .controlSize(.small)
            .help("Cancel this install. Finished downloads are kept for the next Download.")
        } else if row.state.isReady {
            Text("Ready to count")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color.lungfishSageFallback)
                .accessibilityIdentifier(RNASeqReferenceSetsAccessibilityID.status(row.id))
        } else {
            Button {
                model.install(row.id)
            } label: { Text("Download") }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(model.memoryRefusal(row.entry) != nil || model.toolsMissing)
            .help(row.state == .notInstalled
                ? (row.entry.servedIndex == nil
                    ? "Download the genome and genes, build the set and its salmon index"
                    : "Download the genome, genes and salmon index, and build the set")
                : (row.entry.servedIndex == nil
                    ? "The set is here without its salmon index. Download builds the index."
                    : "The set is here without its salmon index. Download gets the served index."))
            .accessibilityIdentifier(RNASeqReferenceSetsAccessibilityID.download(row.id))
        }
    }
}
