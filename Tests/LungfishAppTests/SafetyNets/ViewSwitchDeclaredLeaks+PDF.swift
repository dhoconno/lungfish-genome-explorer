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
        leak("Tree", to: ["PDF"], "NET-PROVENANCE-STAYS", [
            "+ inspectorTab: preview selection of [document, selection]",
            "+ inspectorBlocks: selection, variant",
            "- inspectorTab: preview document of [document, selection]",
            "- inspectorBlocks: document",
        ]),
        leak("FASTA document", to: ["PDF"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: figure.pdf (1 page)",
        ]),
        // The same harness step as Quick Look to FASTQ. In the app the sidebar sets the Inspector's identity first.
        // The packaged walk checks PDF then FASTQ.
        leak("PDF", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS", [
            "+ provenance: document ../k20-pdf/Inputs/figure.pdf",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("PDF", to: ["Quick Look"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: Previewing: main.nf",
        ]),
        leak("Quick Look", to: ["PDF"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: figure.pdf (1 page)",
        ]),
    ]
}
