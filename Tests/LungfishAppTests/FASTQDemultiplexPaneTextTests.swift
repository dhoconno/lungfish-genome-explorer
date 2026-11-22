// FASTQDemultiplexPaneTextTests.swift - The words and the order of the Demultiplex Barcodes pane, pinned (5.6 TV-DEMUX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.6, lane TV-DEMUX, the tests-only first commit (5.6 Q1, UX 5). A pin is every `Text` of the pane in the order ViewInspector
// meets them in one state, so a label, a caption and a help tag each hold their place. The ruled captions are also read by id: D1 the
// Custom Definition format, D2 to D4 the three engine explanations, D5 the Exact Bare Barcode caption, D6 the three Keep Unchecked
// Samples captions and D7 the long-read kit caption. The pins hold the decided words (`SCR/codex/TV-DEMUX-decided.md`), with each
// moved paragraph at its own place replaced by its info button. X, the refusal of Exact Bare Barcode, is pinned in
// `DemultiplexExactBareGuardTests`.

import AppKit
import XCTest
import SwiftUI
import ViewInspector
import LungfishTestSupport
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

    // MARK: The ruled captions that stay in view, by id (5.6 B1, UX-EXACT-BARE-WORDS, BIO-SATKIT-FLUIDIGM 3 and 4)

    private static let d5 = "Exact Bare Barcode does not check for chance matches. If the chosen barcodes are absent from the read sequences, such as when indexes appear only in read names, chance matches can produce sample files. Use it only on reads that carry the barcodes in their sequence."
    private static let d6Cutadapt = "Many reads without barcodes would match this kit's barcodes by chance. The check for chance matches cannot judge the samples, so the run is refused. If the indexes are in the read names, choose the engine Read Names. Otherwise choose Keep Unchecked Samples to make the sample files anyway, then check each sample against your sample sheet."
    private static let d6Fluidigm = "Cutadapt searches for each kit barcode anywhere in the read. About half of all reads or more match by chance. The check for chance matches cannot judge the samples, so the run is refused. Use ONT Fluidigm Sample Split for Fluidigm barcodes in ONT reads. If the indexes are in the read names, choose the engine Read Names. Choose Keep Unchecked Samples only to make the sample files anyway, then check each sample against your sample sheet."
    private static let d6ExactBare = "The read names carry this kit's barcodes, so Exact Bare Barcode would find them in read sequences only by chance and the run is refused. To split reads by name, choose the engine Read Names. Choose Keep Unchecked Samples only if the read sequences carry these barcodes too, then check each sample against your sample sheet."
    private static let d7 = "With this kit for long reads, a read is assigned only when both ends carry the same barcode. Location and distance settings do not apply."

    func testTheRuledCaptionsThatStayInViewAreDrawnInTheirStates() throws {
        let rows: [(id: String, state: String, text: String)] = [
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

    /// D7 shows exactly when the kit searches its full platform construct (`demultiplexKitUsesPlatformConstruct`), and the
    /// construct clause is the kit picker's help tag then.
    func testTheLongReadCaptionShowsOnlyForAKitThatSearchesItsFullConstruct() throws {
        let longRead = try texts("demux.cutadapt.longRead")
        let truseq = try texts("demux.cutadapt.truseq")
        XCTAssertTrue(longRead.contains(Self.d7))
        XCTAssertFalse(longRead.contains("Location"))
        XCTAssertFalse(truseq.contains(Self.d7))
        XCTAssertTrue(truseq.contains("Location"))
        XCTAssertTrue(longRead.contains(FASTQDemultiplexHelp.kitConstruct.summary))
        XCTAssertFalse(truseq.contains(FASTQDemultiplexHelp.kitConstruct.summary))
        XCTAssertTrue(truseq.contains(LungfishHelpContent.fastqBarcodeKit.summary))
    }

    // MARK: The moved explanations, one press away with the text of their decided constant (5.6 U2, U3)

    private static let d1 = "In Inputs, choose a CSV, TSV, or whitespace-delimited barcode definition file with columns id,sequence[,secondary_sequence][,sample_name] or a header line (id,sequence,sample_name). At Both Ends with no sample sheet, write the secondary sequence as it appears at the end of the read or as the i5 primer's barcode. The run uses the form found in the first 10,000 reads, and the Operations Panel says which."
    private static let d2 = "Cutadapt searches read sequences for barcodes at the error rate below and can allow insertions and deletions. For Illumina, Element, Ultima and MGI kits and Custom Definitions, it checks read names first. If they contain indexes for two or more of the kit's barcodes, it splits reads by index, as Read Names does."
    private static let d3 = "Exact Bare Barcode searches for exact matches to each barcode and its reverse complement anywhere in the read. It accepts barcodes with plain A, C, G and T letters and never trims, so the barcode stays in the read."
    private static let d4 = "Read Names splits reads by the indexes bcl2fastq or BCL Convert wrote in the read names, with at most one mismatch in each index. It keeps reads unchanged and pairs together without searching read sequences. Reads whose names match zero or multiple kit barcodes go to Unassigned."

    func testTheMovedExplanationsAreFoundInTheirPopovers() throws {
        try assertPopover(
            state: "demux.cutadapt.customDefinition", item: FASTQDemultiplexHelp.customDefinitionFormat,
            about: "Custom Definition format", text: Self.d1, id: "D1")
        try assertPopover(
            state: "demux.cutadapt.truseq", item: FASTQDemultiplexHelp.engines, about: "engines",
            text: [Self.d2, Self.d3, Self.d4].joined(separator: "\n\n"), id: "D2 to D4")
        XCTAssertEqual(FASTQDemultiplexHelp.customDefinitionFormatText, Self.d1, "D1")
        XCTAssertEqual(FASTQDemultiplexHelp.cutadaptText, Self.d2, "D2")
        XCTAssertEqual(FASTQDemultiplexHelp.exactBareText, Self.d3, "D3")
        XCTAssertEqual(FASTQDemultiplexHelp.readNamesText, Self.d4, "D4")
    }

    /// The format button belongs to a Custom Definition, so a built-in kit shows none, and no moved paragraph stays in view.
    func testTheFormatButtonShowsOnlyForACustomDefinitionAndNoMovedParagraphStaysInView() throws {
        let enginesID = LungfishInfoButton.accessibilityIdentifier(for: FASTQDemultiplexHelp.engines)
        let formatID = LungfishInfoButton.accessibilityIdentifier(for: FASTQDemultiplexHelp.customDefinitionFormat)
        XCTAssertEqual(try hostedButtonIDs("demux.cutadapt.truseq"), [enginesID])
        XCTAssertEqual(try hostedButtonIDs("demux.cutadapt.customDefinition"), [enginesID, formatID].sorted())
        for name in Self.states.keys.sorted() {
            let drawn = try texts(name)
            for moved in [Self.d1, Self.d2, Self.d3, Self.d4] { XCTAssertFalse(drawn.contains(moved), name) }
        }
    }

    /// The identifiers of the info buttons of the pane in the named state, sorted, found by walking the hosted views.
    private func hostedButtonIDs(_ name: String) throws -> [String] {
        let state = Fx.fastqState(.demultiplexBarcodes)
        try XCTUnwrap(Self.states[name])(state)
        let host = NSHostingView(rootView: FASTQOperationToolPanes(state: state).frame(width: 620, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        var ids: [String] = []
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) {
            host.layoutSubtreeIfNeeded()
            ids = Self.infoButtons(in: host).compactMap { ($0.cell as NSAccessibilityProtocol?)?.accessibilityIdentifier() }.sorted()
            return !ids.isEmpty
        }, "\(name) has no info button")
        return ids
    }

    private func assertPopover(
        state name: String, item: LungfishHelpContent.HelpItem, about subject: String, text: String, id: String
    ) throws {
        let state = Fx.fastqState(.demultiplexBarcodes)
        try XCTUnwrap(Self.states[name])(state)
        let host = NSHostingView(rootView: FASTQOperationToolPanes(state: state).frame(width: 620, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let identifier = LungfishInfoButton.accessibilityIdentifier(for: item)
        var found: LungfishInfoButton?
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) {
            host.layoutSubtreeIfNeeded()
            found = Self.infoButtons(in: host).first { ($0.cell as NSAccessibilityProtocol?)?.accessibilityIdentifier() == identifier }
            return found != nil
        }, "\(id) has no info button")
        let button = try XCTUnwrap(found)
        addTeardownBlock { @MainActor in
            button.closePopover()
            window.orderOut(nil)
        }
        let element = try XCTUnwrap(button.cell as NSAccessibilityProtocol?)
        XCTAssertEqual(element.accessibilityLabel(), "About \(subject)", id)
        XCTAssertEqual(element.accessibilityRole(), .button, id)
        XCTAssertEqual(element.accessibilityHelp(), item.summary, id)
        XCTAssertFalse(button.refusesFirstResponder, id)
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, id)
        _ = element.accessibilityPerformPress()
        XCTAssertTrue(button.isPopoverShown, "\(id): a press opens the popover")
        XCTAssertEqual(button.popoverController.text, text, id)
    }

    private static func infoButtons(in view: NSView) -> [LungfishInfoButton] {
        ((view as? LungfishInfoButton).map { [$0] } ?? []) + view.subviews.flatMap { infoButtons(in: $0) }
    }

    func testTheDemultiplexHelpItemsPassTheCatalogCheck() {
        XCTAssertEqual(LungfishHelpContent.catalogFaults(in: FASTQDemultiplexHelp.all), [])
    }

    // MARK: The word ceilings (5.6 U7)

    /// The words a person reads as static text: a `Text` that is no help tag, sits in no control and is not hidden.
    private static func drawnWords(in view: some View) throws -> Int {
        let controls = [".picker(", ".toggle(", ".button(", ".textField(", ".menu("]
        return try view.inspect().findAll(ViewType.Text.self)
            .filter { text in
                let path = text.pathToRoot
                return !path.contains(".help()") && !controls.contains { path.contains($0) } && !text.isHidden()
            }
            .reduce(0) { total, text in total + ((try? text.string()) ?? "").split(whereSeparator: \.isWhitespace).count }
    }

    private func words(_ name: String) throws -> Int {
        let state = Fx.fastqState(.demultiplexBarcodes)
        try XCTUnwrap(Self.states[name])(state)
        return try Self.drawnWords(in: FASTQOperationToolPanes(state: state))
    }

    func testTheCutadaptTruSeqPaneHoldsAtMostFortyWords() throws {
        XCTAssertLessThanOrEqual(try words("demux.cutadapt.truseq"), 40)
    }

    /// Every other state reads no more words than at the base `53631b6aa`, counted by the same rule (the base counts).
    func testNoStateReadsMoreWordsThanAtTheBase() throws {
        let base: [String: Int] = [
            "demux.cutadapt.customDefinition": 150,
            "demux.cutadapt.longRead": 105,
            "demux.cutadapt.truseq": 71,
            "demux.exactBare.fluidigm": 98,
            "demux.keepUnchecked.cutadapt": 133,
            "demux.keepUnchecked.exactBare": 158,
            "demux.keepUnchecked.fluidigm": 188,
            "demux.readNames.truseq": 69,
        ]
        for (name, count) in base.sorted(by: { $0.key < $1.key }) {
            let head = try words(name)
            print("DEMUX-WORDS \(name) base \(count) head \(head)")
            XCTAssertLessThanOrEqual(head, count, name)
        }
    }

    /// Negative test: a hidden label, a button title and a help tag leave the count unchanged.
    func testTheWordCountLeavesOutAHiddenLabelAButtonTitleAndAHelpTag() throws {
        struct Plain: View {
            var body: some View { VStack { Text("one two three"); Text("with a tag") } }
        }
        struct WithExtras: View {
            var body: some View {
                VStack {
                    Text("one two three")
                    Text("these four words hidden").hidden()
                    Button("Press this button now") {}
                    Text("with a tag").help("a help tag of seven words in all")
                }
            }
        }
        XCTAssertEqual(try Self.drawnWords(in: Plain()), 6)
        XCTAssertEqual(try Self.drawnWords(in: WithExtras()), 6)
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
            "Cutadapt",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Exact Bare Barcode",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Read Names",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
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
            "Selects a kit whose full adapter and barcode construct Cutadapt searches at both read ends in both orientations.",
            "Selects a kit whose full adapter and barcode construct Cutadapt searches at both read ends in both orientations.",
            "Cutadapt",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Exact Bare Barcode",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Read Names",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "With this kit for long reads, a read is assigned only when both ends carry the same barcode. Location and distance settings do not apply.",
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
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Exact Bare Barcode",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Read Names",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
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
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Exact Bare Barcode",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Read Names",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Exact Bare Barcode does not check for chance matches. If the chosen barcodes are absent from the read sequences, such as when indexes appear only in read names, chance matches can produce sample files. Use it only on reads that carry the barcodes in their sequence.",
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
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Exact Bare Barcode",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Read Names",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Keep Unchecked Samples",
            "Many reads without barcodes would match this kit's barcodes by chance. The check for chance matches cannot judge the samples, so the run is refused. If the indexes are in the read names, choose the engine Read Names. Otherwise choose Keep Unchecked Samples to make the sample files anyway, then check each sample against your sample sheet.",
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
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Exact Bare Barcode",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Read Names",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Exact Bare Barcode does not check for chance matches. If the chosen barcodes are absent from the read sequences, such as when indexes appear only in read names, chance matches can produce sample files. Use it only on reads that carry the barcodes in their sequence.",
            "Keep Unchecked Samples",
            "The read names carry this kit's barcodes, so Exact Bare Barcode would find them in read sequences only by chance and the run is refused. To split reads by name, choose the engine Read Names. Choose Keep Unchecked Samples only if the read sequences carry these barcodes too, then check each sample against your sample sheet.",
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
            "Selects a kit whose full adapter and barcode construct Cutadapt searches at both read ends in both orientations.",
            "Selects a kit whose full adapter and barcode construct Cutadapt searches at both read ends in both orientations.",
            "Cutadapt",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Exact Bare Barcode",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Read Names",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Keep Unchecked Samples",
            "Cutadapt searches for each kit barcode anywhere in the read. About half of all reads or more match by chance. The check for chance matches cannot judge the samples, so the run is refused. Use ONT Fluidigm Sample Split for Fluidigm barcodes in ONT reads. If the indexes are in the read names, choose the engine Read Names. Choose Keep Unchecked Samples only to make the sample files anyway, then check each sample against your sample sheet.",
            "With this kit for long reads, a read is assigned only when both ends carry the same barcode. Location and distance settings do not apply.",
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
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Searches read sequences for barcodes at the error rate below and can allow insertions and deletions.",
            "Exact Bare Barcode",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Finds exact matches to a barcode or its reverse complement anywhere in the read.",
            "Read Names",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Splits reads by the index in each read name without searching read sequences.",
            "Engine",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
            "Choose cutadapt fuzzy matching, exact barcode matching, or a split by the index in each read name.",
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
