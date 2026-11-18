// ImportCenterViewModel+RNASeqLinuxCards.swift - The Import Center's cards for RNA-seq on a Linux machine (Phase 5.4 lane EX-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import UniformTypeIdentifiers

extension ImportCenterViewModel {
    /// The plan sheets and the adopt of RNA-seq counts on a Linux machine, on the Sequencing Reads tab, beside the FASTQ
    /// cards of the same route. The two plan cards open their sheet at once, since a plan needs no project and no input
    /// chosen first. The adopt card asks for the returned folder and then opens its sheet. A card shows three lines of its
    /// description, so each is two short sentences and the sheet carries the rest.
    static let rnaSeqLinuxCards: [ImportCardInfo] = [
        ImportCardInfo(
            id: "rnaseq-bulk-plan",
            title: "RNA-seq Plan for a Linux Machine",
            description: "Write the files that count bulk RNA-seq reads with salmon or STAR on a Linux machine or cluster. Nothing is imported.",
            sfSymbol: "doc.badge.gearshape",
            fileHint: "FASTQ bundles, or reads already in the staging folder",
            tab: .sequencingReads,
            importKind: .wizardSheet(action: .rnaseqBulkPlan)
        ),
        ImportCardInfo(
            id: "rnaseq-tenx-plan",
            title: "Single-cell Plan for a Linux Machine",
            description: "Write the files that count 10x libraries with STARsolo on a Linux machine or cluster. Nothing is imported.",
            sfSymbol: "circle.grid.3x3.fill",
            fileHint: "reads already in the staging folder, as a staged-reads list and a sample sheet",
            tab: .sequencingReads,
            importKind: .wizardSheet(action: .rnaseqTenXPlan)
        ),
        ImportCardInfo(
            id: "rnaseq-linux-run-result",
            title: "RNA-seq Linux Run Result",
            description: "Import the counts a run on a Linux machine returned, from a plan folder or a batch folder, as one RNA-seq result.",
            sfSymbol: "arrow.down.doc.fill",
            fileHint: "a returned plan folder, or a returned batch folder",
            tab: .sequencingReads,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [.folder],
                    canChooseFiles: false,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false
                ),
                action: .rnaseqLinuxRunResult
            )
        ),
    ]
}
