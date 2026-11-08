// ViewSwitchDeclaredLeaks+FASTACollection.swift - The declared switches to and from the FASTA collection kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTA collection kind joined the matrix in lane FASTA, appended after PDF, so its pairs come at the end of the
// walk (ViewSwitchKinds.eulerCircuit) and no earlier line moved. A route to the list sets the genomics mode and clears
// the Inspector as a FASTA document's does, so what stays is what the route leaves, not what the surface leaves.

extension ViewSwitchDeclaredLeaks {
    static let fromTheFASTACollectionKind: [DeclaredViewSwitchLeak] = [
        leak("FASTA collection", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS", [
            "+ provenance: sequence ../k21-fastacollection/Inputs/clusters.fasta",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("Tree", to: ["FASTA collection"], "INSPECTOR-STALE", [
            "+ inspectorTab: genomics selection of [document, selection, view, derive, provenance]",
            "+ inspectorBlocks: selection, variant",
            "- inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "- inspectorBlocks: document",
        ]),
        leak("FASTA document", to: ["FASTA collection"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("FASTA collection", to: ["Quick Look"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: Previewing: main.nf",
        ]),
        leak("Quick Look", to: ["FASTA collection"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
    ]
}
