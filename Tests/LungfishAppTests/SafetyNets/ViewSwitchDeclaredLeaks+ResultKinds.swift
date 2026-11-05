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
        leak("fresh window", to: ["Quick Look", "PDF", "Status only"], "NET-TOOLBAR-MODE", [
            "+ toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("Kraken2", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: primerScheme=QIASeqDIRECT-SARS2",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
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
        leak("TaxTriage", to: ["12S", "Reference", "Genotype"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("12S", to: ["Genotype"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("NAO-MGS", to: ["Assembly"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("NAO-MGS", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ provenance: naoMgsResult ../k04-naomgs/Imports/naomgs-wastewater",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        leak("CZ ID", to: ["Tree"], "NET-DOCUMENT-STAYS", [
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
        ]),
        leak("EsViritu", to: ["FASTQ"], "INSPECTOR-STALE, NET-PROVENANCE-STAYS", [
            "+ provenance: esvirituResult ../k02-esviritu/Analyses/esviritu-2026-01-15T10-00-00",
            "- inspector: fastqStatistics",
            "- provenance: fastqBundle Reads/illumina-reads.lungfishfastq",
        ]),
        // re-read on this pair after HOST-UX SF1 cleared the 12S blocks (manager ruling 22:3x)
        // smaller after NAOMGS's reset (manager ruling 00:4x)
        leak("12S", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: selectAResult, panelLayout",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("CZ ID", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: selectAResult, panelLayout",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        // smaller after NVDV's reset (manager ruling 15:56)
        leak("NVD", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-DOCUMENT-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ document: ../k17-fasta/Inputs/MT192765.1.fasta",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: selectAResult, panelLayout",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        // smaller after NAOMGS's reset (manager ruling 00:4x)
        leak("NAO-MGS", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: selectAResult, panelLayout",
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
        // re-read on this pair after HOST-UX SF1 cleared the 12S blocks (manager ruling 22:3x)
        // smaller after TT's reset (manager ruling 16:45)
        leak("TaxTriage", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, INSPECTOR-BLOCK-OWNER, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: selectAResult, panelLayout",
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
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            // BACKLOG INSPECTOR-CLEAR-MODE (S4): after a classifier result, a cleared Inspector keeps its result mode's empty blocks beside a preview.
            "+ inspectorBlocks: selectAResult, panelLayout",
            "+ toolbar: ToggleSidebar, Operations, ToggleAnnotationDrawer, ToggleInspector",
            "- mode: empty",
            "- status: Previewing: main.nf",
            "- inspectorTab: empty document of [document, selection]",
            "- inspectorBlocks: document",
            "- toolbar: ToggleSidebar, ToggleChromosomeDrawer, TranslateTool, Operations, ToggleInspector",
        ]),
        leak("CZ ID", to: ["TaxTriage"], "NET-INSPECTOR-DOCUMENT-STAYS", [
            "+ inspector: assembly",
            "+ inspectorBlocks: seeTheViewer, panelLayout, operationDetails=TaxTriage, sampleFilter=1",
            "- inspectorBlocks: panelLayout, operationDetails=TaxTriage, sampleFilter=1",
        ]),
        // re-read on this pair after HOST-UX SF1 cleared the 12S blocks (manager ruling 22:3x)
        leak("Kraken2", to: ["Quick Look"], "W6-PREVIEW-KEEPS-RESULT-BLOCK, NET-INSPECTOR-DOCUMENT-STAYS, NET-PROVENANCE-STAYS, NET-TOOLBAR-MODE", [
            "+ mode: metagenomics",
            "+ inspectorTab: metagenomics resultSummary of [resultSummary, provenance]",
            "+ inspectorBlocks: selectAResult, panelLayout",
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
