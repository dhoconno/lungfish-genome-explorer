// ViewSwitchDeclaredLeaks+ResultKinds.swift - Declared view-switch leaks from a fresh window and the classifier result kinds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Read at the base by lane NET of 3.1. See ViewSwitchDeclaredLeaks.swift for the
// meaning of the lines. A failing walk prints entries ready to paste here.

extension ViewSwitchDeclaredLeaks {
    static let fromResultKinds: [DeclaredViewSwitchLeak] = [
        leak("fresh window", to: ["Primer analysis"], "NET-TOOLBAR-MODE", [
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("fresh window", to: ["Primer order"], "NET-TOOLBAR-MODE", [
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("fresh window", to: ["Quick Look", "Status only"], "NET-TOOLBAR-MODE", [
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Kraken2", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: primerScheme=QIASeqDIRECT-SARS2",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("NVD", to: ["12S", "Reference", "FASTQ"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: nvd=100",
        ]),
        leak("NAO-MGS", to: ["12S", "Reference", "FASTA document"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
        ]),
        leak("12S", to: ["FASTQ"], "INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
        ]),
        leak("TaxTriage", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: primerScheme=QIASeqDIRECT-SARS2",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Kraken2", to: ["NVD", "MSA"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("NVD", to: ["Assembly", "MHC reference", "Kraken2"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("EsViritu", to: ["CZ ID"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("CZ ID", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ provenance: czIdResult ../k06-czid/Imports/cornea-czid.lungfishtax",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("TaxTriage", to: ["12S", "Reference", "Genotype"], "INSPECTOR-BLOCK-OWNER, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("12S", to: ["Genotype"], "INSPECTOR-BLOCK-OWNER, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("NAO-MGS", to: ["Assembly"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("NAO-MGS", to: ["FASTQ"], "INSPECTOR-BLOCK-OWNER, INSPECTOR-STALE, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
            "+ provenance: naoMgsResult ../k04-naomgs/Imports/naomgs-wastewater",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("TaxTriage", to: ["Assembly", "FASTQ", "MHC reference", "Tree", "FASTA document", "Status only"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("CZ ID", to: ["Tree"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("EsViritu", to: ["FASTQ"], "INSPECTOR-STALE, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS", [
            "+ inspector: multipleSequenceAlignment",
            "+ provenance: esvirituResult ../k02-esviritu/Analyses/esviritu-2026-01-15T10-00-00",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("TaxTriage", to: ["MSA"], "NET-MHC-HOST-STAYS, INSPECTOR-BLOCK-OWNER", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, MultipleSequenceAlignmentViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "+ inspector: batchOperation=TaxTriage",
            "- viewports: MultipleSequenceAlignmentViewController",
        ]),
        leak("NAO-MGS", to: ["Tree"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, PhylogeneticTreeViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: PhylogeneticTreeViewController",
        ]),
        leak("NVD", to: ["Primer analysis"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: nvd=100",
        ]),
        leak("NAO-MGS", to: ["Primer analysis"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
        ]),
        leak("12S", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
            "+ provenance: twelveSAmpliconResultBundle ../k07-twelves/12S/primate-12s.lungfish12s",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("NVD", to: ["Primer order"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: nvd=100",
        ]),
        leak("CZ ID", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: multipleSequenceAlignment",
            "+ provenance: czIdResult ../k06-czid/Imports/cornea-czid.lungfishtax",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("NAO-MGS", to: ["Primer order"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
        ]),
        leak("NVD", to: ["FASTA document"], "NET-MHC-HOST-STAYS, INSPECTOR-BLOCK-OWNER", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "+ inspector: nvd=100",
            "- viewports: none",
        ]),
        leak("TaxTriage", to: ["Primer analysis"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("TaxTriage", to: ["Primer order"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("NVD", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: nvd=100",
            "+ provenance: nvdResult ../k05-nvd/Imports/nvd-demo",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: nvd, seeTheViewer, panelLayout",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("NAO-MGS", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
            "+ provenance: naoMgsResult ../k04-naomgs/Imports/naomgs-wastewater",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: naoMgs, seeTheViewer, panelLayout",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("12S", to: ["EsViritu"], "INSPECTOR-STALE, NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("CZ ID", to: ["Kraken2"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: genotype=../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("TaxTriage", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ inspector: batchOperation=TaxTriage",
            "+ provenance: taxTriageResult ../k03-taxtriage/Analyses/taxtriage-2026-01-15T12-30-00",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("CZ ID", to: ["EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: fastqStatistics",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("NVD", to: ["EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("EsViritu", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ provenance: esvirituResult ../k02-esviritu/Analyses/esviritu-2026-01-15T10-00-00",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: organism, seeTheViewer, panelLayout",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("CZ ID", to: ["TaxTriage"], "NET-MHC-HOST-STAYS, NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, TaxTriageResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- viewports: TaxTriageResultViewController",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("Kraken2", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ provenance: classificationResult ../k01-kraken2/Analyses/kraken2-2026-01-15T11-00-00",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("CZ ID", to: ["NAO-MGS"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, naoMgs, seeTheViewer, panelLayout, sampleFilter=5",
            "- inspectorBlocks: naoMgs, seeTheViewer, panelLayout, sampleFilter=5",
        ]),
        leak("NAO-MGS", to: ["EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
    ]
}
