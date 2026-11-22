// FASTQDemultiplexPaneTextTests.swift - The words and the order of the Demultiplex Barcodes pane, pinned (5.6 TV-DEMUX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.6, lane TV-DEMUX, the tests-only first commit (5.6 Q1, UX 5). A pin is every `Text` of the pane in the order ViewInspector
// meets them in one state, so a label, a caption and a help tag each hold their place. The ruled captions are also read by id: D1 the
// Custom Definition format, D2 to D4 the three engine explanations, D5 the Exact Bare Barcode caption, D6 the three Keep Unchecked
// Samples captions and D7 the long-read kit caption. The pins hold at the base of the sub-phase. The move commit updates each one to
// the state after the move, with each moved paragraph replaced at its own place by its info button.

import XCTest
import SwiftUI
import ViewInspector
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class FASTQDemultiplexPaneTextTests: XCTestCase {
    private typealias Fx = OperationsDialogFixtures

    static let truseq = "truseq-single-a"

    /// A state of the Demultiplex Barcodes pane, as the person sets it.
    static let states: [String: (FASTQOperationDialogState) -> Void] = [
        "demux.cutadapt.truseq": { state in
            state.demultiplexBarcodeSource = .builtinKit
            state.demultiplexKitID = FASTQDemultiplexPaneTextTests.truseq
            state.demultiplexEngine = .cutadapt
        },
        "demux.cutadapt.longRead": { state in
            state.demultiplexBarcodeSource = .builtinKit
            state.demultiplexEngine = .cutadapt
            state.demultiplexKitID = BarcodeKitRegistry.ontNativeBarcoding24.id
        },
        "demux.exactBare.fluidigm": { state in
            state.demultiplexBarcodeSource = .builtinKit
            state.demultiplexEngine = .exactBareBarcode
            state.demultiplexKitID = BarcodeKitRegistry.fluidigmAccessArray.id
        },
        "demux.readNames.truseq": { state in
            state.demultiplexBarcodeSource = .builtinKit
            state.demultiplexKitID = FASTQDemultiplexPaneTextTests.truseq
            state.demultiplexEngine = .headerIndex
        },
        "demux.cutadapt.customDefinition": { state in
            state.demultiplexBarcodeSource = .customDefinition
            state.demultiplexEngine = .cutadapt
        },
        "demux.keepUnchecked.cutadapt": { state in
            state.demultiplexBarcodeSource = .builtinKit
            state.demultiplexKitID = FASTQDemultiplexPaneTextTests.truseq
            state.demultiplexEngine = .cutadapt
            FASTQDemultiplexPaneTextTests.showTheBox(state)
        },
        "demux.keepUnchecked.fluidigm": { state in
            state.demultiplexBarcodeSource = .builtinKit
            state.demultiplexEngine = .cutadapt
            state.demultiplexKitID = BarcodeKitRegistry.fluidigmAccessArray.id
            FASTQDemultiplexPaneTextTests.showTheBox(state)
        },
        "demux.keepUnchecked.exactBare": { state in
            state.demultiplexBarcodeSource = .builtinKit
            state.demultiplexEngine = .exactBareBarcode
            state.demultiplexKitID = BarcodeKitRegistry.fluidigmAccessArray.id
            FASTQDemultiplexPaneTextTests.showTheBox(state)
        },
    ]

    /// Preflight's answer for the settings, as `refreshDemultiplexChanceCheck` keeps it when the kit can be refused.
    private static func showTheBox(_ state: FASTQOperationDialogState) {
        state.demultiplexChanceCheck = FASTQDemultiplexChanceCheck(
            keepsUncheckedSamples: false, answered: state.demultiplexChanceCheckSettings, canRefuse: true)
    }

    /// The pane's ordered texts in the named state.
    private func texts(_ name: String) throws -> [String] {
        let state = Fx.fastqState(.demultiplexBarcodes)
        try XCTUnwrap(Self.states[name])(state)
        return Fx.strings(
            try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self),
            normalizing: ["/tmp/reads.fastq", "/tmp"])
    }

    private func pin(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try texts(name)
        XCTAssertEqual(actual, Self.pins[name], name, file: file, line: line)
    }

    // MARK: Pane order, one state each

    func testCutadaptTruSeqPaneOrder() throws { try pin("demux.cutadapt.truseq") }
    func testCutadaptLongReadKitPaneOrder() throws { try pin("demux.cutadapt.longRead") }
    func testExactBarePaneOrder() throws { try pin("demux.exactBare.fluidigm") }
    func testReadNamesPaneOrder() throws { try pin("demux.readNames.truseq") }
    func testCustomDefinitionPaneOrder() throws { try pin("demux.cutadapt.customDefinition") }

    func testKeepUncheckedRefusalPaneOrders() throws {
        try pin("demux.keepUnchecked.cutadapt")
        try pin("demux.keepUnchecked.fluidigm")
        try pin("demux.keepUnchecked.exactBare")
    }

    // MARK: The ruled captions by id (5.6 B1, UX-WORDS-2 F4 (d), UX-EXACT-BARE-WORDS, BIO-SATKIT-FLUIDIGM 3 and 4)

    private static let d1 = "Select a barcode definition CSV, TSV, or whitespace-delimited text file in the Inputs section. Columns: id,sequence[,secondary_sequence][,sample_name], or a header line naming the columns (id,sequence,sample_name). At Both Ends with no sample sheet, the secondary sequence may be written as it appears at the end of the read or as the i5 primer's barcode, since the run reads it the way the first 10,000 reads carry it, and the Operations Panel says which."
    private static let d2 = "Cutadapt searches the read sequences for the barcodes, uses the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it first checks the read names. If they carry the indexes of two or more of the kit's barcodes, it splits the reads by those indexes instead, as Read Names does."
    private static let d3 = "Exact Bare Barcode looks for each barcode, and its reverse complement, as an exact match anywhere in the read. It works with barcodes of plain A, C, G and T letters and never trims, so the barcode stays in the read."
    private static let d4 = "Read Names splits the reads by the index that bcl2fastq or BCL Convert wrote in each read name, with at most one mismatch in each index. It does not search the read sequences, leaves every read as it is and keeps both reads of a pair together. A read whose name matches no barcode of the kit, or more than one, goes to Unassigned."
    private static let d5 = "Exact Bare Barcode does not check for chance matches. On reads that do not carry the chosen barcodes in their sequence, such as reads whose index is only in the read names, it can make sample files from chance matches. Use it only on reads that carry the barcodes in their sequence."
    private static let d6Cutadapt = "Many reads that carry no barcode would match a barcode of this kit by chance, so the check for chance matches cannot judge the samples, and the run is refused. If the indexes are in the read names, choose the engine Read Names. Otherwise choose Keep Unchecked Samples to make the sample files anyway, then check each sample against your sample sheet."
    private static let d6Fluidigm = "Cutadapt searches each barcode of this kit anywhere in the read, so about half of all reads or more match one of them by chance. The check for chance matches cannot judge the samples, and the run is refused. For Fluidigm barcodes in ONT reads, use ONT Fluidigm Sample Split. For reads whose index is in the read names, choose the engine Read Names. Choose Keep Unchecked Samples only to make the sample files anyway, then check each sample against your sample sheet."
    private static let d6ExactBare = "The read names carry barcodes of this kit, so Exact Bare Barcode would find them in the read sequences only by chance, and the run is refused. Choose the engine Read Names to split the reads by their names. Choose Keep Unchecked Samples only if the read sequences carry these barcodes too, then check each sample against your sample sheet."
    private static let d7 = "Long-read kit: cutadapt searches the kit's full adapter and barcode construct at both read ends in both orientations, and a read is assigned only when both ends carry the same barcode. Location and distance settings do not apply."

    func testTheRuledCaptionsAreDrawnInTheirStates() throws {
        let rows: [(id: String, state: String, text: String)] = [
            ("D1", "demux.cutadapt.customDefinition", Self.d1),
            ("D2", "demux.cutadapt.truseq", Self.d2),
            ("D3", "demux.exactBare.fluidigm", Self.d3),
            ("D4", "demux.readNames.truseq", Self.d4),
            ("D5", "demux.exactBare.fluidigm", Self.d5),
            ("D6 Cutadapt", "demux.keepUnchecked.cutadapt", Self.d6Cutadapt),
            ("D6 Fluidigm", "demux.keepUnchecked.fluidigm", Self.d6Fluidigm),
            ("D6 Exact Bare", "demux.keepUnchecked.exactBare", Self.d6ExactBare),
            ("D7", "demux.cutadapt.longRead", Self.d7),
        ]
        for row in rows {
            XCTAssertTrue(try texts(row.state).contains(row.text), "\(row.id) is not drawn in \(row.state)")
        }
        XCTAssertEqual(FASTQOperationDialogState.demultiplexExactBareChanceCaption, Self.d5, "D5")
        XCTAssertEqual(FASTQOperationDialogState.demultiplexKeepUncheckedSamplesCaption, Self.d6Cutadapt, "D6 Cutadapt")
        XCTAssertEqual(FASTQOperationDialogState.demultiplexKeepUncheckedSamplesFluidigmCaption, Self.d6Fluidigm, "D6 Fluidigm")
        XCTAssertEqual(FASTQOperationDialogState.demultiplexExactBareKeepUncheckedSamplesCaption, Self.d6ExactBare, "D6 Exact Bare")
        XCTAssertEqual(FASTQOperationDialogState.demultiplexPlatformConstructCaption, Self.d7, "D7")
    }

    /// The Cutadapt kit shows D7 and no Location picker, and the Illumina kit the reverse, so D7 shows exactly when the
    /// kit searches its full platform construct (`demultiplexKitUsesPlatformConstruct`).
    func testTheLongReadCaptionShowsOnlyForAKitThatSearchesItsFullConstruct() throws {
        XCTAssertTrue(try texts("demux.cutadapt.longRead").contains(Self.d7))
        XCTAssertFalse(try texts("demux.cutadapt.longRead").contains("Location"))
        XCTAssertFalse(try texts("demux.cutadapt.truseq").contains(Self.d7))
        XCTAssertTrue(try texts("demux.cutadapt.truseq").contains("Location"))
    }

    // MARK: The pins

    // PINS-BEGIN
    private static let pins: [String: [String]] = [
        "demux.cutadapt.customDefinition": [
            "Inputs",
            "<root>",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Barcode Definition",
            "Required before this tool can run.",
            "Choose…",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Built-In Kit",
            "Custom Definition",
            "Barcode Source",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Select a barcode definition CSV, TSV, or whitespace-delimited text file in the Inputs section. Columns: id,sequence[,secondary_sequence][,sample_name], or a header line naming the columns (id,sequence,sample_name). At Both Ends with no sample sheet, the secondary sequence may be written as it appears at the end of the read or as the i5 primer's barcode, since the run reads it the way the first 10,000 reads carry it, and the Operations Panel says which.",
            "Cutadapt",
            "Exact Bare Barcode",
            "Read Names",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Cutadapt searches the read sequences for the barcodes, uses the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it first checks the read names. If they carry the indexes of two or more of the kit's barcodes, it splits the reads by those indexes instead, as Read Names does.",
            "Both Ends",
            "5' End",
            "3' End",
            "Location",
            "Choose where cutadapt should look for barcode sequences.",
            "Choose where cutadapt should look for barcode sequences.",
            "Choose where cutadapt should look for barcode sequences.",
            "5' Distance",
            "",
            "Maximum bases from the read end to search for barcodes.",
            "Maximum bases from the read end to search for barcodes.",
            "3' Distance",
            "",
            "Maximum bases from the read end to search for barcodes.",
            "Maximum bases from the read end to search for barcodes.",
            "Error Rate",
            "",
            "Maximum allowed mismatch rate for approximate matching.",
            "Maximum allowed mismatch rate for approximate matching.",
            "Trim Barcodes",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
        "demux.cutadapt.longRead": [
            "Inputs",
            "<root>",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Built-In Kit",
            "Custom Definition",
            "Barcode Source",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "TruSeq Single Index Set A (D701-D712)",
            "TruSeq Single Index Set B (D501-D508)",
            "TruSeq HT Dual Index (96 combinations)",
            "Nextera XT Index Kit v2",
            "IDT for Illumina UD Indexes (96 pairs)",
            "Fluidigm Access Array (864)",
            "PacBio Sequel 16 (v3)",
            "PacBio Sequel 96 (v2)",
            "PacBio Sequel 384 (v1)",
            "M13 Universal Primers",
            "ONT Native Barcoding (NBD104, 12)",
            "ONT Native Barcoding (NBD114, 12)",
            "ONT Native Barcoding (NBD104/NBD114, 24)",
            "ONT Native Barcoding V14 (SQK-NBD114-96, 96)",
            "ONT PCR Barcoding (PBC096, 96)",
            "ONT Rapid Barcoding (RBK004, 12)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-24, 24)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-96, 96)",
            "ONT 16S Barcoding V14 (SQK-16S114-24, 24)",
            "ONT 16S Rapid Amplicon (RAB204/RAB214, 24)",
            "Built-In Kit",
            "Built-in barcode kit expected for the sequencing library.",
            "Built-in barcode kit expected for the sequencing library.",
            "Cutadapt",
            "Exact Bare Barcode",
            "Read Names",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Cutadapt searches the read sequences for the barcodes, uses the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it first checks the read names. If they carry the indexes of two or more of the kit's barcodes, it splits the reads by those indexes instead, as Read Names does.",
            "Long-read kit: cutadapt searches the kit's full adapter and barcode construct at both read ends in both orientations, and a read is assigned only when both ends carry the same barcode. Location and distance settings do not apply.",
            "Error Rate",
            "",
            "Maximum allowed mismatch rate for approximate matching.",
            "Maximum allowed mismatch rate for approximate matching.",
            "Trim Barcodes",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
        "demux.cutadapt.truseq": [
            "Inputs",
            "<root>",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Built-In Kit",
            "Custom Definition",
            "Barcode Source",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "TruSeq Single Index Set A (D701-D712)",
            "TruSeq Single Index Set B (D501-D508)",
            "TruSeq HT Dual Index (96 combinations)",
            "Nextera XT Index Kit v2",
            "IDT for Illumina UD Indexes (96 pairs)",
            "Fluidigm Access Array (864)",
            "PacBio Sequel 16 (v3)",
            "PacBio Sequel 96 (v2)",
            "PacBio Sequel 384 (v1)",
            "M13 Universal Primers",
            "ONT Native Barcoding (NBD104, 12)",
            "ONT Native Barcoding (NBD114, 12)",
            "ONT Native Barcoding (NBD104/NBD114, 24)",
            "ONT Native Barcoding V14 (SQK-NBD114-96, 96)",
            "ONT PCR Barcoding (PBC096, 96)",
            "ONT Rapid Barcoding (RBK004, 12)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-24, 24)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-96, 96)",
            "ONT 16S Barcoding V14 (SQK-16S114-24, 24)",
            "ONT 16S Rapid Amplicon (RAB204/RAB214, 24)",
            "Built-In Kit",
            "Built-in barcode kit expected for the sequencing library.",
            "Built-in barcode kit expected for the sequencing library.",
            "Cutadapt",
            "Exact Bare Barcode",
            "Read Names",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Cutadapt searches the read sequences for the barcodes, uses the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it first checks the read names. If they carry the indexes of two or more of the kit's barcodes, it splits the reads by those indexes instead, as Read Names does.",
            "Both Ends",
            "5' End",
            "3' End",
            "Location",
            "Choose where cutadapt should look for barcode sequences.",
            "Choose where cutadapt should look for barcode sequences.",
            "Choose where cutadapt should look for barcode sequences.",
            "5' Distance",
            "",
            "Maximum bases from the read end to search for barcodes.",
            "Maximum bases from the read end to search for barcodes.",
            "3' Distance",
            "",
            "Maximum bases from the read end to search for barcodes.",
            "Maximum bases from the read end to search for barcodes.",
            "Error Rate",
            "",
            "Maximum allowed mismatch rate for approximate matching.",
            "Maximum allowed mismatch rate for approximate matching.",
            "Trim Barcodes",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
        "demux.exactBare.fluidigm": [
            "Inputs",
            "<root>",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Built-In Kit",
            "Custom Definition",
            "Barcode Source",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Fluidigm Access Array (864)",
            "Built-In Kit",
            "Built-in barcode kit expected for the sequencing library.",
            "Built-in barcode kit expected for the sequencing library.",
            "Cutadapt",
            "Exact Bare Barcode",
            "Read Names",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Exact Bare Barcode looks for each barcode, and its reverse complement, as an exact match anywhere in the read. It works with barcodes of plain A, C, G and T letters and never trims, so the barcode stays in the read.",
            "Exact Bare Barcode does not check for chance matches. On reads that do not carry the chosen barcodes in their sequence, such as reads whose index is only in the read names, it can make sample files from chance matches. Use it only on reads that carry the barcodes in their sequence.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
        "demux.keepUnchecked.cutadapt": [
            "Inputs",
            "<root>",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Built-In Kit",
            "Custom Definition",
            "Barcode Source",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "TruSeq Single Index Set A (D701-D712)",
            "TruSeq Single Index Set B (D501-D508)",
            "TruSeq HT Dual Index (96 combinations)",
            "Nextera XT Index Kit v2",
            "IDT for Illumina UD Indexes (96 pairs)",
            "Fluidigm Access Array (864)",
            "PacBio Sequel 16 (v3)",
            "PacBio Sequel 96 (v2)",
            "PacBio Sequel 384 (v1)",
            "M13 Universal Primers",
            "ONT Native Barcoding (NBD104, 12)",
            "ONT Native Barcoding (NBD114, 12)",
            "ONT Native Barcoding (NBD104/NBD114, 24)",
            "ONT Native Barcoding V14 (SQK-NBD114-96, 96)",
            "ONT PCR Barcoding (PBC096, 96)",
            "ONT Rapid Barcoding (RBK004, 12)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-24, 24)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-96, 96)",
            "ONT 16S Barcoding V14 (SQK-16S114-24, 24)",
            "ONT 16S Rapid Amplicon (RAB204/RAB214, 24)",
            "Built-In Kit",
            "Built-in barcode kit expected for the sequencing library.",
            "Built-in barcode kit expected for the sequencing library.",
            "Cutadapt",
            "Exact Bare Barcode",
            "Read Names",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Cutadapt searches the read sequences for the barcodes, uses the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it first checks the read names. If they carry the indexes of two or more of the kit's barcodes, it splits the reads by those indexes instead, as Read Names does.",
            "Keep Unchecked Samples",
            "Many reads that carry no barcode would match a barcode of this kit by chance, so the check for chance matches cannot judge the samples, and the run is refused. If the indexes are in the read names, choose the engine Read Names. Otherwise choose Keep Unchecked Samples to make the sample files anyway, then check each sample against your sample sheet.",
            "Both Ends",
            "5' End",
            "3' End",
            "Location",
            "Choose where cutadapt should look for barcode sequences.",
            "Choose where cutadapt should look for barcode sequences.",
            "Choose where cutadapt should look for barcode sequences.",
            "5' Distance",
            "",
            "Maximum bases from the read end to search for barcodes.",
            "Maximum bases from the read end to search for barcodes.",
            "3' Distance",
            "",
            "Maximum bases from the read end to search for barcodes.",
            "Maximum bases from the read end to search for barcodes.",
            "Error Rate",
            "",
            "Maximum allowed mismatch rate for approximate matching.",
            "Maximum allowed mismatch rate for approximate matching.",
            "Trim Barcodes",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
        "demux.keepUnchecked.exactBare": [
            "Inputs",
            "<root>",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Built-In Kit",
            "Custom Definition",
            "Barcode Source",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Fluidigm Access Array (864)",
            "Built-In Kit",
            "Built-in barcode kit expected for the sequencing library.",
            "Built-in barcode kit expected for the sequencing library.",
            "Cutadapt",
            "Exact Bare Barcode",
            "Read Names",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Exact Bare Barcode looks for each barcode, and its reverse complement, as an exact match anywhere in the read. It works with barcodes of plain A, C, G and T letters and never trims, so the barcode stays in the read.",
            "Exact Bare Barcode does not check for chance matches. On reads that do not carry the chosen barcodes in their sequence, such as reads whose index is only in the read names, it can make sample files from chance matches. Use it only on reads that carry the barcodes in their sequence.",
            "Keep Unchecked Samples",
            "The read names carry barcodes of this kit, so Exact Bare Barcode would find them in the read sequences only by chance, and the run is refused. Choose the engine Read Names to split the reads by their names. Choose Keep Unchecked Samples only if the read sequences carry these barcodes too, then check each sample against your sample sheet.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
        "demux.keepUnchecked.fluidigm": [
            "Inputs",
            "<root>",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Built-In Kit",
            "Custom Definition",
            "Barcode Source",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "TruSeq Single Index Set A (D701-D712)",
            "TruSeq Single Index Set B (D501-D508)",
            "TruSeq HT Dual Index (96 combinations)",
            "Nextera XT Index Kit v2",
            "IDT for Illumina UD Indexes (96 pairs)",
            "Fluidigm Access Array (864)",
            "PacBio Sequel 16 (v3)",
            "PacBio Sequel 96 (v2)",
            "PacBio Sequel 384 (v1)",
            "M13 Universal Primers",
            "ONT Native Barcoding (NBD104, 12)",
            "ONT Native Barcoding (NBD114, 12)",
            "ONT Native Barcoding (NBD104/NBD114, 24)",
            "ONT Native Barcoding V14 (SQK-NBD114-96, 96)",
            "ONT PCR Barcoding (PBC096, 96)",
            "ONT Rapid Barcoding (RBK004, 12)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-24, 24)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-96, 96)",
            "ONT 16S Barcoding V14 (SQK-16S114-24, 24)",
            "ONT 16S Rapid Amplicon (RAB204/RAB214, 24)",
            "Built-In Kit",
            "Built-in barcode kit expected for the sequencing library.",
            "Built-in barcode kit expected for the sequencing library.",
            "Cutadapt",
            "Exact Bare Barcode",
            "Read Names",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Cutadapt searches the read sequences for the barcodes, uses the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it first checks the read names. If they carry the indexes of two or more of the kit's barcodes, it splits the reads by those indexes instead, as Read Names does.",
            "Keep Unchecked Samples",
            "Cutadapt searches each barcode of this kit anywhere in the read, so about half of all reads or more match one of them by chance. The check for chance matches cannot judge the samples, and the run is refused. For Fluidigm barcodes in ONT reads, use ONT Fluidigm Sample Split. For reads whose index is in the read names, choose the engine Read Names. Choose Keep Unchecked Samples only to make the sample files anyway, then check each sample against your sample sheet.",
            "Long-read kit: cutadapt searches the kit's full adapter and barcode construct at both read ends in both orientations, and a read is assigned only when both ends carry the same barcode. Location and distance settings do not apply.",
            "Error Rate",
            "",
            "Maximum allowed mismatch rate for approximate matching.",
            "Maximum allowed mismatch rate for approximate matching.",
            "Trim Barcodes",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Remove matched barcode sequence from demultiplexed reads.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
        "demux.readNames.truseq": [
            "Inputs",
            "<root>",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Built-In Kit",
            "Custom Definition",
            "Barcode Source",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "Use a built-in barcode kit or a custom barcode definition.",
            "TruSeq Single Index Set A (D701-D712)",
            "TruSeq Single Index Set B (D501-D508)",
            "TruSeq HT Dual Index (96 combinations)",
            "Nextera XT Index Kit v2",
            "IDT for Illumina UD Indexes (96 pairs)",
            "Fluidigm Access Array (864)",
            "PacBio Sequel 16 (v3)",
            "PacBio Sequel 96 (v2)",
            "PacBio Sequel 384 (v1)",
            "M13 Universal Primers",
            "ONT Native Barcoding (NBD104, 12)",
            "ONT Native Barcoding (NBD114, 12)",
            "ONT Native Barcoding (NBD104/NBD114, 24)",
            "ONT Native Barcoding V14 (SQK-NBD114-96, 96)",
            "ONT PCR Barcoding (PBC096, 96)",
            "ONT Rapid Barcoding (RBK004, 12)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-24, 24)",
            "ONT Rapid Barcoding V14 (SQK-RBK114-96, 96)",
            "ONT 16S Barcoding V14 (SQK-16S114-24, 24)",
            "ONT 16S Rapid Amplicon (RAB204/RAB214, 24)",
            "Built-In Kit",
            "Built-in barcode kit expected for the sequencing library.",
            "Built-in barcode kit expected for the sequencing library.",
            "Cutadapt",
            "Exact Bare Barcode",
            "Read Names",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Read Names splits the reads by the index that bcl2fastq or BCL Convert wrote in each read name, with at most one mismatch in each index. It does not search the read sequences, leaves every read as it is and keeps both reads of a pair together. A read whose name matches no barcode of the kit, or more than one, goes to Unassigned.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
    ]
    // PINS-END
}
