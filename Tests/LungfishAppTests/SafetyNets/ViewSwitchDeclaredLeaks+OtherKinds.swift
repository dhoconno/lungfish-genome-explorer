// ViewSwitchDeclaredLeaks+OtherKinds.swift - Declared view-switch leaks from the bundle, analysis and file kinds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Read at the base by lane NET of 3.1. See ViewSwitchDeclaredLeaks.swift for the
// meaning of the lines. A failing walk prints entries ready to paste here.

extension ViewSwitchDeclaredLeaks {
    static let fromOtherKinds: [DeclaredViewSwitchLeak] = [
        leak("MHC reference", to: ["MSA"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, MultipleSequenceAlignmentViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: MultipleSequenceAlignmentViewController",
        ]),
        leak("MSA", to: ["Tree"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, PhylogeneticTreeViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: PhylogeneticTreeViewController",
        ]),
        leak("FASTA document", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ provenance: sequence ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
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
        leak("MHC reference", to: ["Tree"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, PhylogeneticTreeViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: PhylogeneticTreeViewController",
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
        leak("Tree", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: phylogeneticTree",
            "+ provenance: phylogeneticTreeBundle ../k14-tree/Phylogenetic Trees/known-sarcopterygian.lungfishtree",
            "+ inspectorTab: genomics selection of [document, selection, view, derive, provenance]",
            "+ inspectorBlocks: selection, variant",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Quick Look", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: phylogeneticTree",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("Genotype", to: ["Primer analysis"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("Primer analysis", to: ["Status only", "Reference"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("MHC reference", to: ["FASTA document"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: none",
        ]),
        leak("FASTA document", to: ["TaxTriage"], "NET-MHC-HOST-STAYS, NET-DOCUMENT-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, TaxTriageResultViewController",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: TaxTriageResultViewController",
        ]),
        leak("Reference", to: ["MSA"], "INSPECTOR-BLOCK-OWNER, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("MSA", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: multipleSequenceAlignment",
            "+ inspector: batchOperation=TaxTriage",
            "+ provenance: multipleSequenceAlignmentBundle ../k13-msa/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa",
            "+ inspectorTab: genomics document of [document, selection, view, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
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
        leak("FASTQ", to: ["Primer analysis"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: nvd=100",
        ]),
        leak("Status only", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: primerScheme=QIASeqDIRECT-SARS2",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("MHC reference", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genomics",
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ provenance: mhcReferenceBundle ../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorTab: genomics document of [document, selection, view, derive, provenance]",
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("FASTQ", to: ["Primer order"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
        ]),
        leak("Assembly", to: ["Primer analysis"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("Tree", to: ["Kraken2", "EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: phylogeneticTree",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("FASTQ", to: ["FASTA document", "12S"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("Genotype", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: genotype",
            "+ inspector: genotype=../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ provenance: genotypeResultBundle ../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ inspectorTab: genotype document of [document, selection, annotations, view, provenance]",
            "+ toolbar: ToggleSidebar, Operations, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Quick Look", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: genotype=../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("MSA", to: ["Kraken2", "EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: multipleSequenceAlignment",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Tree", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: phylogeneticTree",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("Genotype", to: ["Status only"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("Status only", to: ["Reference"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("Reference", to: ["Primer order"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("FASTQ", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: fastq",
            "+ inspector: multipleSequenceAlignment",
            "+ provenance: esvirituResult ../k02-esviritu/Analyses/esviritu-2026-01-15T10-00-00",
            "+ inspectorTab: fastq document of [document, provenance]",
            "+ inspectorBlocks: document, fastqMetadata, fastqPBAAArtifacts",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("MHC reference", to: ["Kraken2"], "NET-MHC-HOST-STAYS, NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, TaxonomyViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- viewports: TaxonomyViewController",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Assembly", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: assembly",
            "+ inspector: assembly",
            "+ provenance: analysisResult ../k09-assembly/Analyses/spades-2026-01-15T13-30-00",
            "+ inspectorTab: assembly document of [document, view, provenance]",
            "+ toolbar: ToggleSidebar, Operations, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("MSA", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: multipleSequenceAlignment",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("MHC reference", to: ["EsViritu"], "NET-MHC-HOST-STAYS, NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, EsVirituResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- viewports: EsVirituResultViewController",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Genotype", to: ["Kraken2", "EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: genotype=../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("MHC reference", to: ["TaxTriage"], "NET-MHC-HOST-STAYS, NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, TaxTriageResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- viewports: TaxTriageResultViewController",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("MSA", to: ["NAO-MGS"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, NaoMgsResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: NaoMgsResultViewController",
        ]),
        leak("Tree", to: ["NVD"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, NvdResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: NvdResultViewController",
        ]),
        leak("Reference", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-ALIGNMENT-SECTION-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: mapping",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ provenance: referenceBundle ../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorTab: mapping document of [document, selection, view, derive, provenance]",
            "+ inspectorBlocks: document, alignmentBundle",
            "+ toolbar: ToggleSidebar, TranslateTool, Operations, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("FASTQ", to: ["Kraken2"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: fastqStatistics",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("MHC reference", to: ["NAO-MGS"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, NaoMgsResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: NaoMgsResultViewController",
        ]),
        leak("Primer analysis", to: ["12S"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
        ]),
        leak("Quick Look", to: ["FASTQ"], "INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: naoMgs=MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304_S2_L001",
        ]),
        // re-read on this pair after HOST-UX SF1 cleared the 12S blocks (manager ruling 22:3x)
        leak("FASTQ", to: ["EsViritu"], "INSPECTOR-STALE, NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: fastqStatistics",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("Primer order", to: ["Reference"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: nvd=100",
        ]),
        leak("Genotype", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: genotype=../k11-genotype/Genotyping/DW472-mhc.lungfishgenotype",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("Tree", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: phylogeneticTree",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Assembly", to: ["Kraken2"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("MSA", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: multipleSequenceAlignment",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Genotype", to: ["NAO-MGS", "NVD", "Reference"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("Assembly", to: ["EsViritu"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout, sampleFilter=1",
            "- inspectorBlocks: panelLayout, sampleFilter=1",
        ]),
        leak("MHC reference", to: ["NVD"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, NvdResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: NvdResultViewController",
        ]),
        leak("FASTA document", to: ["FASTQ"], "INSPECTOR-BLOCK-OWNER, INSPECTOR-STALE, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: nvd=100",
            "+ provenance: sequence ../k17-fasta/Inputs/MT192765.1.fasta",
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
        leak("Primer order", to: ["FASTQ", "MSA"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("FASTQ", to: ["NAO-MGS", "NVD"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: fastqStatistics",
        ]),
        leak("MHC reference", to: ["CZ ID"], "NET-MHC-HOST-STAYS, NET-INSPECTOR-DOCUMENT-STAYS, NET-DOCUMENT-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, CzIdResultViewController",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "+ inspector: mhcReference=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- viewports: CzIdResultViewController",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Reference", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        leak("FASTA document", to: ["MHC reference"], "INSPECTOR-BLOCK-OWNER, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("MHC reference", to: ["12S"], "INSPECTOR-BLOCK-OWNER, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspector: batchOperation=TaxTriage",
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
        leak("Quick Look", to: ["Tree"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("Tree", to: ["FASTQ"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
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
        leak("MHC reference", to: ["Assembly"], "NET-MHC-HOST-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, AssemblyResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "- viewports: AssemblyResultViewController",
        ]),
        leak("Assembly", to: ["CZ ID"], "NET-MHC-HOST-STAYS, NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ viewports: NSHostingController<MHCReferenceBundleViewport>, CzIdResultViewController",
            "+ native: mhc bundle=../k12-mhc/Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref references=3 definitions=[mhc-simulated-mcm-teaching]",
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout",
            "- viewports: CzIdResultViewController",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Status only", to: ["Primer order"], "INSPECTOR-BLOCK-OWNER", [
            "+ inspector: batchOperation=TaxTriage",
        ]),
        leak("MSA", to: ["FASTQ"], "INSPECTOR-BLOCK-OWNER, INSPECTOR-STALE, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS", [
            "+ inspector: multipleSequenceAlignment",
            "+ inspector: batchOperation=TaxTriage",
            "+ provenance: multipleSequenceAlignmentBundle ../k13-msa/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("Reference", to: ["CZ ID"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: bundle=../k08-reference/Reference Sequences/MT192765.1.lungfishref",
            "+ inspectorBlocks: organism, seeTheViewer, panelLayout",
            "- inspectorBlocks: selectAResult, panelLayout",
        ]),
        leak("Status only", to: ["Quick Look"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: primerScheme=QIASeqDIRECT-SARS2",
        ]),
    ]
}
