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
    static func dismiss(_ id: String) -> String { "plugin-manager-rnaseq-reference-dismiss-\(id)" }
}

/// The RNA-seq reference rows, the last section of the Databases tab's list, drawn like the metagenomics database
/// rows (UX ruling 2026-11-27). The list is drawn even while the metagenomics catalog loads, so these rows always show
/// (ARCH trap 6). The rows have no Recommended badge, since the RAM recommendation sizes Kraken2 only (UX trap 6).
struct RNASeqReferenceSetsSection: View {
    @Bindable var model: RNASeqReferenceCatalogModel

    var body: some View {
        Section {
            ForEach(model.rows) { row in
                RNASeqReferenceRow(row: row, model: model)
                    .listRowBackground(Color.lungfishCardBackground)
            }
        } header: {
            Text("RNA-seq Reference Sets")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(Color.lungfishSecondaryText)
                .accessibilityIdentifier(RNASeqReferenceSetsAccessibilityID.section)
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .managedResourcesDidChange)) { _ in
            Task { await model.refresh() }
        }
    }
}

/// One reference row. It copies the frame of `DatabaseRow` (`PluginManagerView.swift`, the status icon, the name,
/// the size line, the description, one status line, the action, the error row and the progress), so the two kinds
/// of row look alike. Backlog row DATABASE-ROW-SHARED-LAYOUT extracts one shared layout for both.
private struct RNASeqReferenceRow: View {
    let row: RNASeqReferenceCatalogModel.Row
    @Bindable var model: RNASeqReferenceCatalogModel

    private var installing: Bool { model.installing.contains(row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.entry.title)
                        .font(.headline)
                    Text(model.sizeWords(row.entry))
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                        .help(RNASeqReferenceCatalogModel.sizeHelp)
                    Text(ReferenceSetCatalog.description)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                        .lineLimit(1)
                    if !installing, let status = model.statusLine(row) {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(Color.lungfishCreamsicleFallback)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                action
            }
            .padding(.vertical, 4)

            if let failure = model.failure[row.id] {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.lungfishCreamsicleFallback)
                        .frame(width: 8, height: 8)
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishCreamsicleFallback)
                        .lineLimit(2)
                        .help(failure)
                    Spacer()
                    Button("Dismiss") { model.failure[row.id] = nil }
                        .font(.caption)
                        .controlSize(.mini)
                        .accessibilityIdentifier(RNASeqReferenceSetsAccessibilityID.dismiss(row.id))
                }
                .padding(.leading, 34)
                .padding(.bottom, 2)
            }

            if installing {
                VStack(alignment: .leading, spacing: 2) {
                    if let fraction = model.fraction[row.id] {
                        ProgressView(value: fraction).tint(.lungfishCreamsicleFallback)
                    }
                    if let message = model.message[row.id] {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(Color.lungfishSecondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if installing {
            ProgressView()
                .controlSize(.small)
                .tint(.lungfishCreamsicleFallback)
                .frame(width: 20, height: 20)
        } else {
            switch row.state {
            case .ready:
                Circle().fill(Color.lungfishSageFallback).frame(width: 10, height: 10)
            case .setWithoutIndex:
                Circle().fill(Color.lungfishCreamsicleFallback).frame(width: 10, height: 10)
            case .notInstalled:
                Circle()
                    .stroke(Color.lungfishWarmGreyFallback.opacity(0.6), lineWidth: 1)
                    .frame(width: 10, height: 10)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if installing {
            Button(role: .cancel) {
                model.cancel(row.id)
            } label: { Text("Cancel") }
            .controlSize(.small)
            .help("Cancel this install")
        } else if row.state.isReady {
            Text(RNASeqReferenceCatalogModel.installedWords)
                .font(.caption)
                .foregroundStyle(Color.lungfishSageFallback)
                .fontWeight(.medium)
                .help(RNASeqReferenceCatalogModel.installedHelp)
                .accessibilityIdentifier(RNASeqReferenceSetsAccessibilityID.status(row.id))
        } else {
            Button {
                model.install(row.id)
            } label: { Text("Download") }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canDownload(row))
            .help(row.state == .notInstalled
                ? "Download and install this reference set" : "Add the missing salmon index and finish the install")
            .accessibilityIdentifier(RNASeqReferenceSetsAccessibilityID.download(row.id))
        }
    }
}
