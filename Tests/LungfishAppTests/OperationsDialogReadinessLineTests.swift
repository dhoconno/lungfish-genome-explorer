// OperationsDialogReadinessLineTests.swift - One readiness line in each Operations dialog, and no Overview that repeats a card (5.6 TV-SHELL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.6, lane TV-SHELL. Each of the seven dialogs that use `DatasetOperationsDialog` shows its readiness text once, in the
// footer. The footer's text carries the readiness help tag and, where the dialog names an identifier namespace, the `status-text`
// identifier, so the tests read the footer by either and fail if a pane draws the text again. The Workflow dialog's footer also holds
// the replay line, and Check Configuration sits in the Run Again block. The states are `OperationsDialogFixtures` of
// `OperationsDialogPaneOrderTests`, whose pins hold the order of every pane.

import XCTest
import SwiftUI
import ViewInspector
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class OperationsDialogReadinessLineTests: XCTestCase {
    private typealias Fx = OperationsDialogFixtures

    private var defaults: UserDefaults { makeTestDefaultsSuite(prefix: "OperationsDialogReadinessLineTests").defaults }

    /// The readiness text is drawn once. The one line that carries the readiness help tag is the footer's, and a dialog with an
    /// identifier namespace names that line `status-text`.
    private func assertDrawnOnceInTheFooter(
        _ texts: [InspectableView<ViewType.Text>], _ readinessText: String, hasIdentifier: Bool, _ dialog: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(readinessText.isEmpty, dialog, file: file, line: line)
        XCTAssertEqual(Fx.drawn(readinessText, in: texts), 1, dialog, file: file, line: line)
        let tagged = texts.filter { (try? $0.help().string()) == LungfishHelpContent.operationReadiness.summary }
        XCTAssertEqual(tagged.compactMap { try? $0.string() }, [readinessText], dialog, file: file, line: line)
        XCTAssertEqual(Fx.footerLines(texts), hasIdentifier ? [readinessText] : [], dialog, file: file, line: line)
    }

    func testTheFASTQDialogDrawsItsReadinessTextOnce() throws {
        for tool in [FASTQOperationToolID.qualityTrim, .mafft, .rnaSeqQuant] {
            let state = Fx.fastqState(tool)
            let texts = try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
            assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: false, "FASTQ \(tool.rawValue)")
        }
    }

    func testTheWorkflowDialogDrawsItsReadinessTextOnce() throws {
        let state = try Fx.workflowState(
            selecting: "MiSeq Amplicon MHC Genotyping", defaults: defaults, enabling: { $0.setWorkflow(.ontGenotyping, enabled: true) })
        let texts = try Fx.workflowDialog(state).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: true, "Workflow")
        let pseudobulk = try Fx.workflowState(
            selecting: "Pseudobulk RNA-seq Cells", defaults: defaults,
            enabling: { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqPseudobulkItem, enabled: true) })
        let pseudobulkTexts = try Fx.workflowDialog(pseudobulk).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(pseudobulkTexts, pseudobulk.readinessText, hasIdentifier: true, "Workflow pseudobulk")
    }

    func testThePrimerDesignDialogDrawsItsReadinessTextOnce() throws {
        let state = PrimerDesignDialogState()
        let texts = try PrimerDesignDialog(state: state, onRun: {}, onClose: {}).inspect().findAll(ViewType.Text.self)
        let text = state.errorMessage ?? state.validationMessage ?? state.inputReadinessMessage ?? "Ready. Progress will appear in Operations."
        assertDrawnOnceInTheFooter(texts, text, hasIdentifier: true, "Primer design")
    }

    func testTheBAMVariantCallingDialogDrawsItsReadinessTextOnce() throws {
        for tool in [nil, BAMVariantCallingToolID.ivar] {
            let state = try Fx.bamState(tool: tool)
            let texts = try BAMVariantCallingDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
            assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: false, "BAM variant calling \(tool?.rawValue ?? "default")")
        }
    }

    func testTheORFDialogDrawsItsReadinessTextOnce() throws {
        let state = Fx.orfState()
        let texts = try SequenceORFOperationDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: true, "ORF")
    }

    func testTheDatabaseSearchDialogDrawsItsReadinessTextOnce() throws {
        let state = DatabaseSearchDialogState(initialDestination: .genBankGenomes)
        let texts = try DatabaseSearchDialog(state: state).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(
            texts, DatabaseSearchDialogPresentation(state: state).statusText, hasIdentifier: true, "Database search")
    }

    func testTheIQTreeDialogDrawsItsReadinessTextOnce() throws {
        let state = Fx.iqTreeState()
        state.seedText = "12a"
        let texts = try IQTreeInferenceDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: true, "IQ-TREE")
    }

    // MARK: Workflow, the replay line and Check Configuration

    func testTheWorkflowFooterShowsTheReplayLineWhileARunAgainSubmits() throws {
        let fixture = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state.restoreReplayConfiguration(
            fixture.configuration, sourceBundleURL: fixture.root.appendingPathComponent("original.lungfishrun"))
        let line = "Validating the captured configuration before launch…"

        let before = try Fx.workflowDialog(fixture.state).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(before, fixture.state.readinessText, hasIdentifier: true, "Run Again before submit")
        XCTAssertEqual(Fx.drawn(line, in: before), 0)

        fixture.state.isSubmittingReplay = true
        let submitting = try Fx.workflowDialog(fixture.state).inspect().findAll(ViewType.Text.self)
        XCTAssertEqual(Fx.drawn(line, in: submitting), 1)
        XCTAssertEqual(Fx.footerLines(submitting), [line])
        XCTAssertEqual(Fx.drawn(fixture.state.readinessText, in: submitting), 0)
    }

    func testCheckConfigurationSitsInTheRunAgainBlockAndNoSectionIsNamedReadiness() throws {
        let fixture = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state.restoreReplayConfiguration(
            fixture.configuration, sourceBundleURL: fixture.root.appendingPathComponent("original.lungfishrun"))
        let detail = try Fx.workflowDetailTexts(fixture.state, paths: fixture.paths)
        let runAgain = try XCTUnwrap(detail.firstIndex { $0.hasPrefix("Run Again: ") })
        let check = try XCTUnwrap(detail.firstIndex(of: "Check Configuration"))
        let inputs = try XCTUnwrap(detail.firstIndex(of: "Inputs"))
        XCTAssertLessThan(runAgain, check)
        XCTAssertLessThan(check, inputs)
        XCTAssertEqual(detail.filter { $0 == "Check Configuration" }.count, 1)
        XCTAssertEqual(detail.filter { $0 == "Readiness" }.count, 0)
        _ = try Fx.workflowDialog(fixture.state).inspect().find(viewWithAccessibilityIdentifier: "workflow-operations-check-repeat")
    }

    // MARK: No Overview that repeats the card

    func testTheWorkflowOverviewShowsOnlyWhatItHolds() throws {
        let pseudobulk = try Fx.workflowState(
            selecting: "Pseudobulk RNA-seq Cells", defaults: defaults,
            enabling: { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqPseudobulkItem, enabled: true) })
        let pseudobulkTexts = try Fx.workflowDetailTexts(pseudobulk)
        XCTAssertEqual(pseudobulkTexts.first, "Inputs", "no Previous Run button and no replay, so no Overview")
        XCTAssertEqual(pseudobulkTexts.filter { $0 == "Overview" }.count, 0)

        let ont = try Fx.workflowState(
            selecting: "MiSeq Amplicon MHC Genotyping", defaults: defaults, enabling: { $0.setWorkflow(.ontGenotyping, enabled: true) })
        let ontTexts = try Fx.workflowDetailTexts(ont)
        XCTAssertEqual(Array(ontTexts.prefix(3)), ["Overview", "Open Previous Run…", "Inputs"], "the summary is the card's")
    }

    func testTheFASTQPanesNoLongerOpenWithAnOverview() throws {
        for tool in [FASTQOperationToolID.qualityTrim, .mafft, .rnaSeqQuant] {
            let state = Fx.fastqState(tool)
            let texts = Fx.strings(try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self))
            XCTAssertEqual(texts.first, "Inputs", tool.rawValue)
            XCTAssertEqual(texts.filter { $0 == "Overview" || $0 == "Readiness" }, [], tool.rawValue)
            XCTAssertEqual(texts.filter { $0 == state.selectedToolSummary }, [], tool.rawValue)
        }
    }

    // MARK: Sentence case headings

    func testTheHeadingsOfTheSevenDialogsAreInSentenceCase() throws {
        let bam = Fx.strings(try BAMVariantCallingToolPanes(state: try Fx.bamState(tool: .ivar)).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(bam.filter { $0 == "iVar options" || $0 == "iVar settings" }, ["iVar settings", "iVar options"])
        let loFreq = Fx.strings(try BAMVariantCallingToolPanes(state: try Fx.bamState()).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(loFreq.filter { $0.hasSuffix(" settings") }, ["LoFreq settings"])
        let orf = Fx.strings(
            try SequenceORFOperationDialog(state: Fx.orfState(), onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(orf.filter { $0 == "Reading frames" || $0 == "Reading Frames" }, ["Reading frames"])
        let iqTree = Fx.strings(
            try IQTreeInferenceDialog(state: Fx.iqTreeState(), onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(iqTree.filter { $0 == "Branch support" || $0 == "Branch Support" }, ["Branch support"])
        XCTAssertEqual(
            DatasetOperationSection.allCases.map(\.title),
            ["Overview", "Inputs", "Primary settings", "Advanced settings", "Output"])
        XCTAssertEqual(MappingWizardSheet.readGroupSectionTitle, "Read group")
        XCTAssertEqual(MappingWizardSheet.advancedSectionTitle, "Advanced settings")
    }

    func testOnlyAToolWithAControlShowsAdvancedSettings() throws {
        for tool in [FASTQOperationToolID.qualityTrim, .mafft, .rnaSeqQuant] {
            let state = Fx.fastqState(tool)
            let texts = Fx.strings(try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self))
            XCTAssertEqual(
                texts.filter { $0 == "Advanced settings" }.count, tool.hasAdvancedSettingsControls ? 1 : 0, tool.rawValue)
        }
        XCTAssertEqual(
            Set(FASTQOperationToolID.allCases.filter(\.hasAdvancedSettingsControls)), [.pbaa, .savont, .ontGenotyping, .mafft])
        let package = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: package.root) }
        XCTAssertEqual(try Fx.workflowDetailTexts(package.state, paths: package.paths).filter { $0 == "Advanced settings" }, [])
    }

    // MARK: The summary is the card's help tag

    @MainActor
    private final class EnabledFASTQLibrary: WorkflowLibraryEnabling {
        func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool { true }
    }

    /// The card of the selected tool, found by its title in the rendered sidebar, holds the tool's summary as its help tag, which the
    /// pane's Overview held before.
    func testTheRenderedCardHoldsTheToolSummaryAsItsHelpTag() throws {
        for tool in [FASTQOperationToolID.qualityTrim, .mafft, .rnaSeqQuant] {
            let state = FASTQOperationDialogState(
                initialCategory: tool.categoryID, selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
                workflowLibrary: EnabledFASTQLibrary())
            state.selectTool(tool)
            let dialog = try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect()
            let card = try dialog.find(ViewType.Button.self) { (try? $0.labelView().find(text: tool.title)) != nil }
            XCTAssertEqual(try card.help().string(), state.selectedToolSummary, tool.rawValue)
            XCTAssertEqual(try card.help().string(), FASTQOperationDialogState.toolSummary(for: tool), tool.rawValue)
        }
    }
}
