// ViewSwitchDeclaredLeaks+OtherKinds.swift - Declared view-switch leaks from the bundle, analysis and file kinds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Read at the base by lane NET of 3.1. See ViewSwitchDeclaredLeaks.swift for the
// meaning of the lines. A failing walk prints entries ready to paste here.

extension ViewSwitchDeclaredLeaks {
    static let fromOtherKinds: [DeclaredViewSwitchLeak] = [
        leak("FASTA document", to: ["Quick Look"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: Previewing: main.nf",
        ]),
        leak("Status only", to: ["Kraken2", "EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: primerScheme=QIASeqDIRECT-SARS2",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Reference", to: ["FASTQ"], "NET-ALIGNMENT-SECTION-STAYS", [
            "+ inspectorBlocks: document, alignmentBundle, fastqMetadata, fastqPBAAArtifacts",
            "- inspectorBlocks: document, fastqMetadata, fastqPBAAArtifacts",
        ]),
        leak("Status only", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: primerScheme=QIASeqDIRECT-SARS2",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("Tree", to: ["FASTA document"], "INSPECTOR-STALE", [
            "+ inspectorTab: genomics selection of [document, selection, view, derive, provenance]",
            "+ inspectorBlocks: selection, variant",
            "- inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "- inspectorBlocks: document",
        ]),
        leak("FASTA document", to: ["Kraken2", "EsViritu", "NAO-MGS", "NVD", "CZ ID", "12S", "Reference", "Assembly", "Genotype", "MSA", "Tree"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Assembly", to: ["MSA", "Tree", "NVD"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("FASTQ", to: ["Tree", "TaxTriage"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Tree", to: ["Quick Look"], "INSPECTOR-STALE, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspectorTab: preview selection of [document, selection]",
            "+ inspectorBlocks: selection, variant",
            "- status: Previewing: main.nf",
            "- inspectorTab: preview document of [document, selection]",
            "- inspectorBlocks: document",
        ]),
        leak("Quick Look", to: ["TaxTriage"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("FASTA document", to: ["TaxTriage"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Reference", to: ["MSA"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("MSA", to: ["Quick Look"], "NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: Previewing: main.nf",
        ]),
        leak("Quick Look", to: ["NAO-MGS", "Assembly", "Genotype", "MHC reference"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Tree", to: ["Status only"], "INSPECTOR-STALE", [
            "+ inspectorTab: empty selection of [document, selection]",
            "+ inspectorBlocks: selection, variant",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
        ]),
        leak("Status only", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: primerScheme=QIASeqDIRECT-SARS2",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Tree", to: ["TaxTriage"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("MHC reference", to: ["Kraken2"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("MHC reference", to: ["EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Genotype", to: ["Kraken2", "EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: genotype=../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("MHC reference", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("Reference", to: ["Quick Look"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-ALIGNMENT-SECTION-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "- status: Previewing: main.nf",
        ]),
        leak("FASTQ", to: ["Kraken2"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: fastqStatistics",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Genotype", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: genotype=../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("Assembly", to: ["Kraken2"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("MSA", to: ["CZ ID"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Genotype", to: ["NAO-MGS", "NVD", "Reference"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Assembly", to: ["EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("FASTA document", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ provenance: sequence ../k17-fasta/Inputs/MT192765.1.fasta",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        // The matrix skips the sidebar's selection step, which sets the Inspector's identity before a row shows, and SF1
        // keeps that identity on the preview. In the app the sidebar sets it first, so the FASTQ shows its own blocks.
        // The packaged walk checks Quick Look then FASTQ.
        leak("Quick Look", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS", [
            "+ provenance: unknown ../k18-quicklook/Inputs/main.nf",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("Reference", to: ["Kraken2", "EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Tree", to: ["Reference"], "INSPECTOR-STALE", [
            "+ inspectorTab: mapping selection of [document, selection, view, derive, provenance]",
            "+ inspectorBlocks: selection, variant",
            "- inspectorTab: mapping document of [document, selection, view, derive, provenance]",
            "- inspectorBlocks: document, alignmentBundle",
        ]),
        leak("Assembly", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("FASTQ", to: ["NAO-MGS", "NVD"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: fastqStatistics",
        ]),
        leak("MHC reference", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Reference", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("FASTA document", to: ["MHC reference"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("MHC reference", to: ["12S"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Genotype", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: genotype=../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Reference", to: ["NAO-MGS"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, naoMgs, seeTheViewer, panelLayout, sampleFilter=5",
            "- inspectorBlocks: naoMgs, seeTheViewer, panelLayout, sampleFilter=5",
        ]),
        leak("FASTQ", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: fastqStatistics",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("MSA", to: ["Assembly"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Tree", to: ["Genotype"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Reference", to: ["NVD"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, nvd, seeTheViewer, panelLayout, sampleFilter=3",
            "- inspectorBlocks: nvd, seeTheViewer, panelLayout, sampleFilter=3",
        ]),
        leak("Assembly", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("MSA", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS", [
            "+ provenance: multipleSequenceAlignmentBundle ../k13-msa/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("Reference", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
    ]
}
