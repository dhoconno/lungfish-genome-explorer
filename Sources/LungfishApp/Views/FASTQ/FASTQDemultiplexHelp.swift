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
        "Select a barcode definition CSV, TSV, or whitespace-delimited text file in the Inputs section. Columns: id,sequence[,secondary_sequence][,sample_name], or a header line naming the columns (id,sequence,sample_name). At Both Ends with no sample sheet, the secondary sequence may be written as it appears at the end of the read or as the i5 primer's barcode, since the run reads it the way the first 10,000 reads carry it, and the Operations Panel says which."

    /// D2, the Cutadapt explanation.
    static let cutadaptText =
        "Cutadapt searches the read sequences for the barcodes, uses the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it first checks the read names. If they carry the indexes of two or more of the kit's barcodes, it splits the reads by those indexes instead, as Read Names does."

    /// D3, the Exact Bare Barcode explanation (true, BIO-EXACT-BARE-RC item 1).
    static let exactBareText =
        "Exact Bare Barcode looks for each barcode, and its reverse complement, as an exact match anywhere in the read. It works with barcodes of plain A, C, G and T letters and never trims, so the barcode stays in the read."

    /// D4, the Read Names explanation.
    static let readNamesText =
        "Read Names splits the reads by the index that bcl2fastq or BCL Convert wrote in each read name, with at most one mismatch in each index. It does not search the read sequences, leaves every read as it is and keeps both reads of a pair together. A read whose name matches no barcode of the kit, or more than one, goes to Unassigned."

    /// The popover beside Engine holds the three explanations together, to compare.
    static let enginesText = [cutadaptText, exactBareText, readNamesText].joined(separator: "\n\n")

    static let engines = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.engines",
        summary: "Compare how the three engines find barcodes.",
        detail: enginesText,
        audience: .analyst)

    static let customDefinitionFormat = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.customDefinitionFormat",
        summary: "The layout of a Custom Definition barcode file.",
        detail: customDefinitionFormatText,
        audience: .analyst)

    static let cutadaptSegment = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.engine.cutadapt",
        summary: "Searches the read sequences with the error rate below, allowing insertions and deletions.",
        audience: .analyst)

    static let exactBareSegment = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.engine.exactBare",
        summary: "Finds each barcode, or its reverse complement, as an exact match anywhere in the read.",
        audience: .analyst)

    static let readNamesSegment = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.engine.readNames",
        summary: "Splits reads by the index in each read name and does not search the sequences.",
        audience: .analyst)

    /// The kit picker's help tag for a kit that cutadapt searches as its full platform construct (D7's construct clause).
    static let kitConstruct = LungfishHelpContent.HelpItem(
        id: "workflow.fastq.demultiplex.kitConstruct",
        summary: "Cutadapt searches the kit's full adapter and barcode construct at both read ends, in both orientations.",
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
