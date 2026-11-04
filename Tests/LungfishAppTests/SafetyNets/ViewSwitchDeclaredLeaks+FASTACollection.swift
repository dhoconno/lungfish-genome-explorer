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
        leak("FASTA collection", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ provenance: sequence ../k21-fastacollection/Inputs/clusters.fasta",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Quick Look", to: ["FASTA collection"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("FASTA collection", to: ["PDF"], "NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ provenance: sequence ../k21-fastacollection/Inputs/clusters.fasta",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
    ]
}
