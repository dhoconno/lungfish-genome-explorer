// RNASeqSingleCellImportSheet.swift - The sheet of the Import Center's single-cell RNA-seq card
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.4 lane RS-GLUE. The card asks for Cell Ranger `outs/` folders or STARsolo run folders. This sheet asks for the
// name, a sample sheet, the genomes of a reference of two or more and, optionally, a reference set with one BAM for each
// sample. The values become `lungfish-cli import rnaseq` options in `RNASeqImportSheetModel`. The sheet counts nothing.

import SwiftUI

struct RNASeqSingleCellImportSheet: View {
    @Bindable var model: RNASeqImportSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Single-cell Counts")
                .font(.headline)
            Text(model.inputSummary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("rnaseq-import-inputs")
            Text(RNASeqImportWords.externalInputs)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                RNASeqImportNameRow(model: model)
                RNASeqImportSampleSheetRow(model: model)
                genomesRow
                RNASeqImportChooserRow(
                    title: "Reference set:",
                    help: "Optional. A reference set folder whose not-host sequences are counted in each cell and in the ambient pool. "
                        + "It needs one sorted, indexed BAM for each sample.",
                    value: model.referenceSet,
                    identifier: "rnaseq-import-reference-set",
                    choose: {
                        RNASeqImportPanels.choose(message: "Choose the reference set folder", directories: true) { url in
                            if let url { model.referenceSet = url }
                        }
                    },
                    clear: {
                        model.referenceSet = nil
                        model.notHostBAMs = [:]
                    }
                )
                if model.referenceSet != nil {
                    ForEach(Array(model.sampleIDs.enumerated()), id: \.offset) { index, sample in
                        RNASeqImportChooserRow(
                            title: "BAM of \(sample):",
                            help: nil,
                            value: model.notHostBAMs[index],
                            identifier: "rnaseq-import-bam-\(index)",
                            choose: {
                                RNASeqImportPanels.choose(message: "Choose the sorted, indexed BAM of \(sample)", directories: false) { url in
                                    if let url { model.notHostBAMs[index] = url }
                                }
                            },
                            clear: { model.notHostBAMs[index] = nil }
                        )
                    }
                }
            }
            .disabled(model.phase == .running)
            RNASeqImportFooter(model: model)
        }
        .padding(20)
        .frame(width: 580)
    }

    private var genomesRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Genomes:")
                    .frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
                TextField("hg19, mm10", text: $model.genomesText)
                    .accessibilityIdentifier("rnaseq-import-genomes")
            }
            Text("Optional. For a reference of two or more genomes, name each by the prefix of its gene ids, such as hg19 and mm10. "
                + "Leave this empty for a reference of one genome.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, RNASeqImportLayout.labelWidth + 8)
        }
    }
}
