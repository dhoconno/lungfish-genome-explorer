// ViewSwitchDeclaredLeaks+MappingResult.swift - The declared switches to and from the mapping result kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The mapping result kind joined the matrix in lane REFMAP, appended after the FASTA collection, so its pairs come at
// the end of the walk (ViewSwitchKinds.eulerCircuit) and no earlier line moved. A mapping result and a reference bundle
// share one class, so these pairs are the matrix's only read of a switch between them. Neither direction leaves a line.
// A `reference:` or `bamContext:` line declared here would be another bundle's reads on screen, an S1, so none may be.
// What stays is what a reference bundle leaves on the same switch: the Inspector's state and the route's chrome.

extension ViewSwitchDeclaredLeaks {
    static let fromTheMappingResultKind: [DeclaredViewSwitchLeak] = [
        leak("Mapping result", to: ["Kraken2", "EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k22-mapping/Analyses/minimap2-2026-01-15T16-00-00/MT192765.1.lungfishref",
            "+ inspector: mapping",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Mapping result", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k22-mapping/Analyses/minimap2-2026-01-15T16-00-00/MT192765.1.lungfishref",
            "+ inspector: mapping",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("Mapping result", to: ["NAO-MGS", "NVD"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k22-mapping/Analyses/minimap2-2026-01-15T16-00-00/MT192765.1.lungfishref",
        ]),
        leak("Mapping result", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k22-mapping/Analyses/minimap2-2026-01-15T16-00-00/MT192765.1.lungfishref",
            "+ inspector: mapping",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Mapping result", to: ["FASTQ"], "NET-ALIGNMENT-SECTION-STAYS", [
            "+ inspectorBlocks: document, alignmentBundle, fastqMetadata, fastqPBAAArtifacts",
            "- inspectorBlocks: document, fastqMetadata, fastqPBAAArtifacts",
        ]),
        leak("FASTA document", to: ["Mapping result"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Mapping result", to: ["Quick Look"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-ALIGNMENT-SECTION-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: Previewing: main.nf",
        ]),
        leak("Quick Look", to: ["Mapping result"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
    ]
}
