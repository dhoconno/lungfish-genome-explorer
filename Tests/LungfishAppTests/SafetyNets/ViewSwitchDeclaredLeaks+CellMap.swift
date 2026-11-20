// ViewSwitchDeclaredLeaks+CellMap.swift - The declared switches to and from the cell-map kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The cell map joined the matrix in Phase 5.5 lane CM-VIEW, appended after the RNA-seq result, so its pairs come at the
// end of the walk (ViewSwitchKinds.eulerCircuit) and no earlier line moved. It opens through the registered-bundle
// route as the RNA-seq result does, in the same viewer, so its pairs differ from the kind alone as the RNA-seq kind's
// do, each with the backlog ids of the same pair for the RNA-seq kind. No line names another result's numbers on screen.

extension ViewSwitchDeclaredLeaks {
    static let fromTheCellMapKind: [DeclaredViewSwitchLeak] = [
        leak("FASTA document", to: ["Cell map"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Cell map", to: ["Quick Look"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: Previewing: main.nf",
        ]),
        leak("Quick Look", to: ["Cell map"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Cell map", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS", [
            "+ provenance: registeredBundle ../k24-cellmap/RNASeq/Smoke cell map.lungfishrnaseq",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
    ]
}
