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

    // MARK: Export pane

    private func exportState() throws -> WorkflowOperationDialogState {
        let suite = makeTestDefaultsSuite(prefix: "RNASeqPseudobulkPaneTests")
        return try OperationsDialogFixtures.workflowState(
            selecting: "Export RNA-seq Counts", defaults: suite.defaults,
            enabling: { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqExportItem, enabled: true) })
    }

    /// The pin of the export pane, with the five headings of 5.6 U4 in sentence case ("RNA-seq results", "Sample sheet (optional)",
    /// "Export folder", "Adjusted p-value cutoff" and "Fold-change bar"). A control's own label, such as "Folder name", is not kept.
    func testTheExportPaneOrderAndItsFiveSentenceCaseHeadings() throws {
        let expected = [
            "Inputs", "RNA-seq results", "No RNA-seq results selected", RNASeqPaneWords.resultsCaption,
            "Sample sheet (optional)", "No sample sheet", RNASeqPaneWords.sampleSheetCaption,
            "Primary settings", "Export folder", RNASeqPaneWords.exportFolderCaption,
            "Design", RNASeqPaneWords.designCaption, "Contrasts", RNASeqPaneWords.contrastCaption,
            "Adjusted p-value cutoff", RNASeqExportDefaults.cutoffHelp + ".",
            "Fold-change bar", RNASeqExportDefaults.lfcBarHelp + ".", "Batch", RNASeqPaneWords.batchCaption,
        ]
        let texts = try paneTexts(try exportState(), keeping: expected)
        XCTAssertEqual(texts, expected)
    }

    // MARK: Words of the panes (5.6 U7)

    // The strings of the base, 729720e7f, as literals that the head's words never move. The lists are the first commit's pins with the
    // button titles out, which is how the count reads a pane. The export pane had no pin there, so its list is read from
    // `RNASeqWorkflowPanes.swift` at that commit, where the five headings were in title case and no caption had moved.
    private let baseE0 = "A single-cell .lungfishrnaseq result."
    private let baseE1 = "A group under 10 cells is left out, and so are the cells with no label. The Operations row says which."
    private let baseE2 = "Each sample's selected cells and the rest of its drawn cells become two columns. "
        + "LGE writes the selection's labels table before the run, outside the single-cell result, and the record names it."
    private let baseFolder = "The new result is written in the output directory with .lungfishrnaseq added to the name. It must not exist."
    private let outputSection = ["Output", "Directory", "No output directory selected"]

    private var baseLegendSelectionPane: [String] {
        ["Inputs", "Single-cell RNA-seq Result", "No single-cell result selected", baseE0,
         "Selected Cells", "412 selected cells from pbmc-map", baseE2, "Primary settings", "Result Name", baseFolder]
    }

    private var baseLabelsTablePane: [String] {
        ["Inputs", "Single-cell RNA-seq Result", "No single-cell result selected", baseE0,
         "Labels Table", "No labels table selected", labelsCaption, baseE1, "Primary settings", "Result Name", baseFolder]
    }

    private var baseImportPane: [String] {
        ["Inputs", "Single-cell RNA-seq Result", "No single-cell result selected", RNASeqPaneWords.importResultCaption,
         "Coordinates", "No coordinates file selected", RNASeqPaneWords.importCoordinatesCaption,
         "Clusters (optional)", "No clusters file selected", RNASeqPaneWords.importClustersCaption,
         "Label Columns (optional)", RNASeqPaneWords.importLabelColumnsCaption,
         "Tool and Version (optional)", e4, "Primary settings", "Result Name", RNASeqPaneWords.importFolderCaption,
         "Barcodes", RNASeqPaneWords.importBarcodesCaption, RNASeqPaneWords.importSkipCaption, "Counts", e3]
    }

    private var baseExportPane: [String] {
        ["Inputs", "RNA-seq Results", "No RNA-seq results selected", RNASeqPaneWords.resultsCaption,
         "Sample Sheet (optional)", "No sample sheet", RNASeqPaneWords.sampleSheetCaption,
         "Primary settings", "Export Folder", RNASeqPaneWords.exportFolderCaption,
         "Design", RNASeqPaneWords.designCaption, "Contrasts", RNASeqPaneWords.contrastCaption,
         "Adjusted p-value Cutoff", RNASeqExportDefaults.cutoffHelp + ".", "Fold-change Bar", RNASeqExportDefaults.lfcBarHelp + ".",
         "Batch", RNASeqPaneWords.batchCaption]
    }

    /// The drawn, visible static text under `root`, in order. It leaves out each Text that is the title of a Button, the label of a
    /// TextField, hidden by `.hidden()`, or a help tag (ViewInspector lists the Text of a help tag and of its accessibility hint too).
    private static func visibleStaticTexts<V: BaseViewType>(under root: InspectableView<V>, helpTags: Set<String>) -> [String] {
        var controlTitles: [String] = []
        for button in root.findAll(ViewType.Button.self) where !button.isHidden() {
            if let label = try? button.labelView() {
                controlTitles += label.findAll(ViewType.Text.self).compactMap { try? $0.string() }
            }
        }
        for field in root.findAll(ViewType.TextField.self) where !field.isHidden() {
            if let label = try? field.labelView() {
                controlTitles += label.findAll(ViewType.Text.self).compactMap { try? $0.string() }
            }
        }
        var texts = root.findAll(ViewType.Text.self).filter { !$0.isHidden() }.compactMap { try? $0.string() }
        for title in controlTitles {
            if let index = texts.firstIndex(of: title) { texts.remove(at: index) }
        }
        return texts.filter { !helpTags.contains($0) }
    }

    /// Words as the help catalog counts them, split on white space.
    private static func wordCount(_ texts: [String]) -> Int {
        texts.reduce(0) { $0 + $1.split { $0.isWhitespace || $0.isNewline }.count }
    }

    /// The visible static text of the dialog's detail pane, from its first heading to the end of its Output section.
    private func visibleTexts(_ state: WorkflowOperationDialogState) throws -> [String] {
        let scrolls = try OperationsDialogFixtures.workflowDialog(state).inspect().findAll(ViewType.ScrollView.self)
        XCTAssertGreaterThanOrEqual(scrolls.count, 2)
        return Self.visibleStaticTexts(under: scrolls[1], helpTags: Set(RNASeqPseudobulkHelp.items.map(\.summary)))
    }

    /// 5.6 U7. The pane opened from a legend selection holds at most 40 words of static text, with or without the dialog's Output
    /// section. By hand the head reads Inputs 1, Single-cell RNA-seq result 3, No single-cell result selected 4, Selected cells 2, the
    /// selection line 5, E2 14, Primary settings 2 and Result name 2, which is 33, and 39 with the Output section. The base read 74
    /// and 80.
    func testTheLegendSelectionPaneHoldsAtMostFortyWords() throws {
        let texts = try visibleTexts(try pseudobulkState(selection: true))
        let pane = Array(texts.prefix { $0 != "Output" })
        // ViewInspector lists the Text of the directory line three times, once as drawn and twice as its own help tag, which
        // counts once. The pin shows the Output section draws exactly the three strings of `outputSection`.
        var seen = Set<String>()
        let output = texts.drop { $0 != "Output" }.filter { seen.insert($0).inserted }
        XCTAssertEqual(output, outputSection, "the Output section")
        XCTAssertLessThanOrEqual(Self.wordCount(pane), 40, "the pane")
        XCTAssertLessThanOrEqual(Self.wordCount(pane + output), 40, "the pane with the dialog's Output section")
        XCTAssertEqual(Self.wordCount(pane), 33, "head")
        XCTAssertEqual(Self.wordCount(pane + output), 39, "head with the Output section")
        XCTAssertEqual(Self.wordCount(baseLegendSelectionPane), 74, "base")
        XCTAssertEqual(Self.wordCount(baseLegendSelectionPane + outputSection), 80, "base with the Output section")
    }

    /// The negative test of the count: a hidden label, a button title and a field title leave it unchanged, and a visible label adds
    /// its words, so the count is not at zero and cannot be lowered by hiding a word or moving it into a button.
    func testTheCountIgnoresAHiddenLabelAButtonTitleAndAFieldTitle() throws {
        func count(_ probe: CountProbe) throws -> Int {
            Self.wordCount(Self.visibleStaticTexts(under: try probe.inspect(), helpTags: ["help words five six"]))
        }
        let plain = try count(CountProbe(extra: .none))
        XCTAssertEqual(plain, 5, "one two three, and visible four")
        XCTAssertEqual(try count(CountProbe(extra: .hiddenLabel)), plain, "a hidden label adds no word")
        XCTAssertEqual(try count(CountProbe(extra: .buttonTitle)), plain, "a button title adds no word")
        XCTAssertEqual(try count(CountProbe(extra: .fieldTitle)), plain, "a field title adds no word")
        XCTAssertEqual(try count(CountProbe(extra: .visibleLabel)), plain + 3, "a visible label adds its three words")
    }

    /// The other states read no more words than at the base. The count is kept to the strings of the base lists, in any case, as the
    /// pins are, so a control's own option or placeholder never counts.
    func testTheOtherStatesReadNoMoreWordsThanAtTheBase() throws {
        func counts(_ state: WorkflowOperationDialogState, base: [String]) throws -> (head: Int, base: Int) {
            let known = Set(base.map { $0.lowercased() })
            let pane = try visibleTexts(state).prefix { $0 != "Output" }.filter { known.contains($0.lowercased()) }
            return (Self.wordCount(Array(pane)), Self.wordCount(base))
        }
        let labels = try counts(try pseudobulkState(selection: false), base: baseLabelsTablePane)
        XCTAssertEqual(labels.base, 80, "labels table, base")
        XCTAssertEqual(labels.head, 57, "labels table, head: E0 (4 words) and F (19) are help tags now")
        let importPane = try counts(try importState(), base: baseImportPane)
        XCTAssertEqual(importPane.head, importPane.base, "Import Embedding, no word moved")
        let export = try counts(try exportState(), base: baseExportPane)
        XCTAssertEqual(export.head, export.base, "export, only the case of five headings moved")
    }
}

/// A small view for the negative test of the word count.
private struct CountProbe: View {
    enum Extra { case none, hiddenLabel, buttonTitle, fieldTitle, visibleLabel }
    let extra: Extra

    var body: some View {
        VStack {
            Text("one two three")
            Text("visible four").help("help words five six")
            switch extra {
            case .none: EmptyView()
            case .hiddenLabel: Text("hidden words seven eight nine").hidden()
            case .buttonTitle: Button("Button title ten eleven") {}
            case .fieldTitle: TextField("Field title twelve", text: .constant(""))
            case .visibleLabel: Text("visible words added")
            }
        }
    }
}
