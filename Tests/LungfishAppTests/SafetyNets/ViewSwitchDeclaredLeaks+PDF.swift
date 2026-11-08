// ViewSwitchDeclaredLeaks+PDF.swift - The declared switches to and from the PDF kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The PDF kind joined the matrix in lane QL. It is the same surface as the Quick Look kind, so a route that takes
// the viewer to a PDF leaves the Inspector, the mode and the document as it does on the way to Quick Look. The walk
// reaches these pairs after the first 19 kinds' circuit, so a stale document or Inspector reads as it does at the
// end of that circuit (ViewSwitchKinds.eulerCircuit).

extension ViewSwitchDeclaredLeaks {
    static let fromThePDFKind: [DeclaredViewSwitchLeak] = [
        leak("Reference", to: ["PDF"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: mapping",
            "+ inspectorTab: mapping document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, TranslateTool, Operations, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Assembly", to: ["PDF"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: assembly",
            "+ inspectorTab: assembly document of [document, view, provenance]",
            "+ toolbar: ToggleSidebar, Operations, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("FASTQ", to: ["PDF"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: fastq",
            "+ inspectorTab: fastq document of [document, provenance]",
            "+ inspectorBlocks: document, fastqMetadata, fastqPBAAArtifacts",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Genotype", to: ["PDF"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genotype",
            "+ inspectorTab: genotype document of [document, selection, annotations, view, provenance]",
            "+ toolbar: ToggleSidebar, Operations, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("MHC reference", to: ["PDF"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("MSA", to: ["PDF"], "NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Tree", to: ["PDF"], "NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ inspectorTab: genomics selection of [document, selection, view, derive, provenance]",
            "+ inspectorBlocks: selection, variant",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("FASTA document", to: ["PDF"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: figure.pdf (1 page)",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        // The same harness step as Quick Look to FASTQ. In the app the sidebar sets the Inspector's identity first.
        // The packaged walk checks PDF then FASTQ.
        leak("PDF", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS", [
            "+ provenance: document ../k20-pdf/Inputs/figure.pdf",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("PDF", to: ["Quick Look"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Quick Look", to: ["PDF"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: figure.pdf (1 page)",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
    ]
}
