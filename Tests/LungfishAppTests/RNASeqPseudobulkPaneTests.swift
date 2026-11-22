// RNASeqPseudobulkPaneTests.swift - The pseudobulk and Import Embedding panes of the Workflow Operations dialog (5.6 TV-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.6, lane TV-PSEUDOBULK. The first commit pinned every label the pane draws, in the order ViewInspector `findAll`
// returns them, cut before the dialog's Output section (the pane's own part) and kept to the strings the pane lays, so a
// control's own placeholder never moves a pin. The ledger ids of `SCR/inv/BIO.md` 1c name the captions: E0 the single-cell
// caption, E1 the small group caption, E2 the selection caption and F the folder caption of the pseudobulk pane, E3 the other
// counts caption and E4 the tool caption of the Import Embedding pane. The strings are literals, so a change of words moves a pin
// in the commit that changes them (QA 2). ViewInspector also lists the Text of each help tag and of its accessibility hint, so a
// help tag is taken out of the drawn list by its words and read as a help tag by its own test.

import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishRNASeqUI
import LungfishTestSupport
import ViewInspector
@testable import LungfishApp

@MainActor
final class RNASeqPseudobulkPaneTests: XCTestCase {
    // Ledger E0, E1, E2 and F, as they read now. E0, F and the second sentence of E2 are help tags, E1 and the first sentence of E2 are in view.
    private let e0 = "A single-cell .lungfishrnaseq result."
    private let e1 = "A group under 10 cells is left out, and so are the cells with no label. The Operations row says which."
    private let e2 = "Each sample's selected cells and the rest of its drawn cells become two columns."
    private let labelsTableFact = "LGE writes the selection's labels table before the run, outside the single-cell result, and the record names it."
    private let folder = "The new result is written in the output directory with .lungfishrnaseq added to the name. It must not exist."
    private let labelsCaption = "A tab-separated table with barcode and label columns, and sample for a result of two or more samples."
    // Ledger E3 and E4 of the Import Embedding pane, which stay as they are.
    private let e3 = "Turn this on when the embedding was computed on counts other than this result's, "
        + "such as 10x's analysis of Cell Ranger counts. The record and the view then say computed on other counts."
    private let e4 = "The tool that made the files and its version, as you state them. LGE records both and did not compute the embedding."

    /// The drawn labels of the pane, in order, kept to the strings of `known` and with the help tags taken out.
    private func paneTexts(_ state: WorkflowOperationDialogState, keeping known: [String]) throws -> [String] {
        let all = try OperationsDialogFixtures.workflowDetailTexts(state)
        let helpTags = Set(RNASeqPseudobulkHelp.items.map(\.summary))
        let wanted = Set(known)
        return Array(all.prefix { $0 != "Output" }).filter { wanted.contains($0) && !helpTags.contains($0) }
    }

    private func pseudobulkState(selection: Bool) throws -> WorkflowOperationDialogState {
        let suite = makeTestDefaultsSuite(prefix: "RNASeqPseudobulkPaneTests")
        let state = try OperationsDialogFixtures.workflowState(
            selecting: "Pseudobulk RNA-seq Cells", defaults: suite.defaults,
            enabling: { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqPseudobulkItem, enabled: true) })
        if selection {
            state.rnaSeqPseudobulk.selection = RNASeqPseudobulkSelection(RNASeqEmbeddingSelectionRequest(
                cellMapURL: URL(fileURLWithPath: "/tmp/pb-pane/Analyses/pbmc-map.lungfishrnaseq", isDirectory: true),
                cellMapName: "pbmc-map",
                parentURL: URL(fileURLWithPath: "/tmp/pb-pane/Analyses/cells.lungfishrnaseq", isDirectory: true),
                embedding: "UMAP", form: .labels(set: "clusters", labels: ["2"]), count: 412, underTenWords: []))
        }
        return state
    }

    private func importState() throws -> WorkflowOperationDialogState {
        let suite = makeTestDefaultsSuite(prefix: "RNASeqPseudobulkPaneTests")
        return try OperationsDialogFixtures.workflowState(
            selecting: RNASeqCellMapImportWords.title, defaults: suite.defaults,
            enabling: { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqCellMapImportItem, enabled: true) })
    }

    // MARK: Pseudobulk pane

    /// The pin of the first commit with each moved caption taken out at its own place (E0 and F) and the headings in sentence case.
    /// "Result name" stands twice, the group title and the field's own label.
    func testThePseudobulkPaneOrderWithALabelsTable() throws {
        let expected = [
            "Inputs",
            "Single-cell RNA-seq result", "No single-cell result selected", "Choose…",
            "Labels table", "No labels table selected", "Choose…", labelsCaption, e1,
            "Primary settings", "Result name", "Result name",
        ]
        let texts = try paneTexts(try pseudobulkState(selection: false), keeping: expected + [e0, folder])
        XCTAssertEqual(texts, expected)
    }

    func testThePseudobulkPaneOrderFromALegendSelection() throws {
        let expected = [
            "Inputs",
            "Single-cell RNA-seq result", "No single-cell result selected", "Choose…",
            "Selected cells", "412 selected cells from pbmc-map", e2,
            "Primary settings", "Result name", "Result name",
        ]
        let texts = try paneTexts(try pseudobulkState(selection: true), keeping: expected + [e0, folder, labelsTableFact])
        XCTAssertEqual(texts, expected)
    }

    func testTheIdsOfE1AndE2AreEachDrawnOnceInTheirOwnState() throws {
        let labels = try paneTexts(try pseudobulkState(selection: false), keeping: [e1, e2])
        let selection = try paneTexts(try pseudobulkState(selection: true), keeping: [e1, e2])
        XCTAssertEqual(labels, [e1], "E1 in the labels table state, and not E2")
        XCTAssertEqual(selection, [e2], "E2 in the legend selection state, and not E1")
    }

    func testE0AndFAndTheLabelsTableSentenceAreHelpTagsOnTheirFields() throws {
        XCTAssertEqual(RNASeqPseudobulkHelp.singleCellResult.summary, e0, "E0")
        XCTAssertEqual(RNASeqPseudobulkHelp.resultFolder.summary, folder, "F")
        XCTAssertEqual(RNASeqPseudobulkHelp.selectionLabelsTable.summary, labelsTableFact, "E2, second sentence")
        let dialog = try OperationsDialogFixtures.workflowDialog(try pseudobulkState(selection: true)).inspect()
        XCTAssertEqual(try dialog.find(viewWithAccessibilityIdentifier: "rnaseq-pseudobulk-selection").help().string(), labelsTableFact)
        XCTAssertEqual(try dialog.find(viewWithAccessibilityIdentifier: "rnaseq-pseudobulk-result-name").help().string(), folder)
        XCTAssertEqual(LungfishHelpContent.catalogFaults(in: RNASeqPseudobulkHelp.items), [])
    }

    // MARK: Import Embedding pane

    func testTheImportPaneOrder() throws {
        let expected = [
            "Inputs", "Single-cell RNA-seq result", "No single-cell result selected", RNASeqPaneWords.importResultCaption,
            "Coordinates", "No coordinates file selected", RNASeqPaneWords.importCoordinatesCaption,
            "Clusters (optional)", "No clusters file selected", RNASeqPaneWords.importClustersCaption,
            "Label columns (optional)", RNASeqPaneWords.importLabelColumnsCaption,
            "Tool and version (optional)", e4, "Primary settings", "Result name", "Result name", RNASeqPaneWords.importFolderCaption,
            "Barcodes", RNASeqPaneWords.importBarcodesCaption, RNASeqPaneWords.importSkipCaption, "Counts", e3,
        ]
        let texts = try paneTexts(try importState(), keeping: expected)
        XCTAssertEqual(texts, expected)
    }

    func testTheIdsOfE3AndE4AreDrawnOnceWithTheirBaseWords() throws {
        let texts = try OperationsDialogFixtures.workflowDetailTexts(try importState())
        XCTAssertEqual(RNASeqPaneWords.importOtherCountsCaption, e3, "E3 holds its base words")
        XCTAssertEqual(RNASeqPaneWords.importToolCaption, e4, "E4 holds its base words")
        XCTAssertEqual(texts.filter { $0 == e3 }.count, 1, "E3 is drawn once")
        XCTAssertEqual(texts.filter { $0 == e4 }.count, 1, "E4 is drawn once")
    }
}
