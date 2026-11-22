// WorkflowOperationHelp.swift - The help tags of the Workflow Operations dialog, for the cards and the pseudobulk pane (5.6 TV-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishKit
import LungfishWorkflow

/// The help items of the pseudobulk pane, built here from the pane's own words (5.6 A1) and checked by
/// `LungfishHelpContent.catalogFaults(in:)` in `RNASeqPseudobulkPaneTests`. None is added to `LungfishHelpContent.allItems`.
enum RNASeqPseudobulkHelp {
    /// E0, the help tag of the single-cell result field.
    static let singleCellResult = LungfishHelpContent.HelpItem(
        id: "rnaseq.pseudobulk.single-cell-result", summary: RNASeqPaneWords.singleCellCaption, audience: .benchScientist)

    /// F, the help tag of the result name field.
    static let resultFolder = LungfishHelpContent.HelpItem(
        id: "rnaseq.pseudobulk.result-folder", summary: RNASeqPaneWords.pseudobulkFolderCaption, audience: .benchScientist)

    /// The labels-table sentence of E2, a provenance fact, as the help tag of the selection line.
    static let selectionLabelsTable = LungfishHelpContent.HelpItem(
        id: "rnaseq.pseudobulk.selection-labels-table", summary: RNASeqPaneWords.selectionLabelsTableFact, audience: .benchScientist)

    /// W7 (5.5 S3), the caveat the CLI prints after a run with `--cell-map`. The popover holds the CLI's own constant, so the
    /// two cannot differ, and the help tag and the VoiceOver subject are the pane's.
    static let selectionTest = LungfishHelpContent.HelpItem(
        id: "rnaseq.pseudobulk.selection-test",
        summary: "Explains why testing a selection against the rest finds genes by construction.",
        detail: RNASeqPseudobulk.selectionWords, audience: .benchScientist)
    static let selectionTestSubject = "testing a selection"

    static var items: [LungfishHelpContent.HelpItem] { [singleCellResult, resultFolder, selectionLabelsTable, selectionTest] }
}

extension WorkflowOperationTool {
    /// The card's help tag, the words that the one-line subtitle leaves out (UX-SHELL-WIZARDS Q3). An imported package has none and
    /// keeps the dialog's general sidebar help.
    var help: String? {
        switch kind {
        case .ontGenotyping: return WorkflowLibraryCatalog.item(for: .ontGenotyping)?.help
        case .fullLengthONTMHCGenotyping: return WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)?.help
        case .twelveSAmpliconMatching: return WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.twelveSAmpliconMatchingID)?.help
        case .rnaSeqExport: return WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.rnaSeqExportID)?.help
        case .rnaSeqPseudobulk: return WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.rnaSeqPseudobulkID)?.help
        case .rnaSeqCellMapImport: return WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.rnaSeqCellMapImportID)?.help
        case .workflowPackage: return nil
        }
    }
}
