// ViewSwitchDeclaredLeaks+RNASeq.swift - The declared switches to and from the RNA-seq result kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The RNA-seq result kind joined the matrix in lane RS-UI-KIND, appended after the mapping result, so its pairs come at
// the end of the walk (ViewSwitchKinds.eulerCircuit) and no earlier line moved. It is the matrix's first kind opened by
// the registered-bundle route (MainSplitViewController+SidebarKindRoute.swift), and it shows `genomics` alone and after
// every switch, since the surface sets the mode when a result is shown. Four of its 44 pairs differ from the kind alone.
// Each carries the lines and the backlog ids of the same pair for the kinds before it. The route keeps the document of
// a FASTA file, as the 12S, MSA and Tree routes do (NET-DOCUMENT-STAYS), and it keeps the Inspector's identity of the
// row so that a late notification of the row just left is refused, which the matrix cannot hand on to a FASTQ because it
// skips the sidebar's selection step (the Quick Look to FASTQ entry in ViewSwitchDeclaredLeaks+OtherKinds.swift says so).
// No line names another result's reads or numbers on screen.

extension ViewSwitchDeclaredLeaks {
    static let fromTheRNASeqKind: [DeclaredViewSwitchLeak] = [
        leak("FASTA document", to: ["RNA-seq"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("RNA-seq", to: ["Quick Look"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: Previewing: main.nf",
        ]),
        leak("Quick Look", to: ["RNA-seq"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("RNA-seq", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS", [
            "+ provenance: registeredBundle ../k23-rnaseq/RNASeq/two-sample.lungfishrnaseq",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
    ]
}
