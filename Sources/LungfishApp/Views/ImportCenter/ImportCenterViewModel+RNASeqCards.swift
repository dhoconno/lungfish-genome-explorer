// ImportCenterViewModel+RNASeqCards.swift - The Import Center's two cards for `lungfish-cli import rnaseq`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ImportCenterViewModel {
    /// The Linux run cards and the RNA-seq cards, joined here so `allCards` adds one array to its literal. A second `+`
    /// on that literal is more than the compiler type-checks in reasonable time.
    static let cardsAfterTheFirstTabs: [ImportCardInfo] = linuxRunCards + rnaSeqCards + rnaSeqLinuxCards

    /// The two cards of RNA-seq counts another tool made, on the Sequencing Reads tab (Phase 5.4 lane RS-GLUE). Each asks
    /// for its inputs in an open panel and then opens a sheet (`RNASeqBulkImportSheet`, `RNASeqSingleCellImportSheet`)
    /// for the options of the command. Each card says where counting FASTQ files starts, since four of five testers looked
    /// for it here (focus group of 2026-11-26), and both sheets say in words what a project path means for the record, since a command that
    /// names an input outside the project does not replay (BACKLOG RNASEQ-IMPORT-EXTERNAL-NO-REPLAY).
    ///
    /// A card shows three lines of its description (`ImportCenterView`, `.lineLimit(3)`), about 190 characters at the
    /// least width of the window, so a description is two short sentences and the sheet carries the rest (RS-GLUE-UX B1).
    static let rnaSeqCards: [ImportCardInfo] = [
        ImportCardInfo(
            id: "rnaseq-counts",
            title: "Existing Bulk RNA-seq Counts",
            description: RNASeqImportWords.bulkCardDescription,
            sfSymbol: "chart.bar.xaxis",
            fileHint: "salmon quant folders, or one count table (.tsv, .csv, .txt), such as one of nf-core/rnaseq's merged tables",
            tab: .sequencingReads,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: nil,
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: true,
                    allowsOtherFileTypes: true
                ),
                action: .rnaseqCounts
            )
        ),
        ImportCardInfo(
            id: "rnaseq-single-cell",
            title: "Existing Single-cell Counts",
            description: RNASeqImportWords.singleCellCardDescription,
            sfSymbol: "circle.grid.3x3",
            fileHint: "Cell Ranger outs/ folders, or STARsolo run folders",
            tab: .sequencingReads,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: nil,
                    canChooseFiles: false,
                    canChooseDirectories: true,
                    allowsMultipleSelection: true,
                    allowsOtherFileTypes: true
                ),
                action: .rnaseqSingleCell
            )
        ),
    ]
}

/// The words the two cards and their sheets share.
enum RNASeqImportWords {
    /// The bulk card, with the way in for FASTQ files (UX ruling 2026-11-26).
    static let bulkCardDescription = "Import salmon quant folders or one gene-by-sample table that another tool made. "
        + "To count FASTQ files, import them as Sequencing Read Files, then use Tools > RNA-seq > Count Reads per Gene."

    static let singleCellCardDescription = "Import Cell Ranger outs folders or STARsolo run folders as one single-cell result. "
        + "To count 10x FASTQ files, use Single-cell Plan for a Linux Machine."

    /// What a person needs to know about inputs outside the project (BACKLOG RNASEQ-IMPORT-EXTERNAL-NO-REPLAY).
    static let externalInputs =
        "An input outside the project is recorded as <external>/<name>, so its command does not replay."

    /// What a person does after the command refuses (RS-GLUE-UX SF-3). The sheet shows it under the command's own words.
    static let afterARefusal =
        "Change what the message names, then choose Import again. To choose other inputs, choose Cancel and start again from the card."
}
