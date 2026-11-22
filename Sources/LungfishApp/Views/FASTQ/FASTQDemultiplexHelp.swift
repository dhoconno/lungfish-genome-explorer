// FASTQDemultiplexHelp.swift - The help items of the Demultiplex Barcodes pane (5.6 TV-DEMUX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishKit
import LungfishWorkflow

/// The general explanations of the Demultiplex Barcodes pane, one click away behind an info button beside the control they
/// explain (5.6 U1, U2), the help tag of each engine segment and the kit picker's help tag for a long-read kit. The items
/// are built here, from this file's constants, and `LungfishHelpContent.catalogFaults(in:)` checks them (5.6 A1).
enum FASTQDemultiplexHelp {
    /// D1, the Custom Definition format (UX-WORDS-2 F4 (d) put its i5 sentence in the caption, which this moves, BIO-DUAL-FORM 4).
    static let customDefinitionFormatText =
        "In Inputs, choose a CSV, TSV, or whitespace-delimited barcode definition file with columns id,sequence[,secondary_sequence][,sample_name] or a header line (id,sequence,sample_name). At Both Ends with no sample sheet, write the secondary sequence as it appears at the end of the read or as the i5 primer's barcode. The run uses the form found in the first 10,000 reads, and the Operations Panel says which."

    /// D2, the Cutadapt explanation.
    static let cutadaptText =
        "Cutadapt searches read sequences for barcodes at the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it checks read names first. If they contain indexes for two or more of the kit's barcodes, it splits reads by index, as Read Names does."

    /// D3, the Exact Bare Barcode explanation (true, BIO-EXACT-BARE-RC item 1).
    static let exactBareText =
        "Exact Bare Barcode searches for exact matches to each barcode and its reverse complement anywhere in the read. It accepts barcodes with plain A, C, G and T letters and never trims, so the barcode stays in the read."

    /// D4, the Read Names explanation.
    static let readNamesText =
        "Read Names splits reads by the indexes bcl2fastq or BCL Convert wrote in the read names, with at most one mismatch in each index. It keeps reads unchanged and pairs together without searching read sequences. Reads whose names match zero or multiple kit barcodes go to Unassigned."

    /// The popover beside Engine holds the three explanations together, to compare.
    static let enginesText = [cutadaptText, exactBareText, readNamesText].joined(separator: "\n\n")

    static let engines = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.engines",
        summary: "Shows how each engine finds barcodes.",
        detail: enginesText,
        audience: .analyst)

    static let customDefinitionFormat = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.customDefinitionFormat",
        summary: "Shows how to format a Custom Definition file.",
        detail: customDefinitionFormatText,
        audience: .analyst)

    static let cutadaptSegment = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.engine.cutadapt",
        summary: "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
        audience: .analyst)

    static let exactBareSegment = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.engine.exactBare",
        summary: "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
        audience: .analyst)

    static let readNamesSegment = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.engine.readNames",
        summary: "Splits reads by the index in each read name without searching read sequences.",
        audience: .analyst)

    /// The kit picker's help tag for a kit that cutadapt searches as its full platform construct (D7's construct clause).
    static let kitConstruct = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.kitConstruct",
        summary: "Selects a kit whose full adapter and barcode construct Cutadapt searches at both read ends in both orientations.",
        audience: .analyst)

    static func segmentHelp(for engine: DemultiplexEngine) -> LungfishHelpContent.HelpItem {
        switch engine {
        case .cutadapt: return cutadaptSegment
        case .exactBareBarcode: return exactBareSegment
        case .headerIndex: return readNamesSegment
        }
    }

    static let all: [LungfishHelpContent.HelpItem] = [
        engines, customDefinitionFormat, cutadaptSegment, exactBareSegment, readNamesSegment, kitConstruct,
    ]
}
