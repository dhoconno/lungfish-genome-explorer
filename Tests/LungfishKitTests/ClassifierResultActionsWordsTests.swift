// ClassifierResultActionsWordsTests.swift - The shared classifier actions speak the approved label set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane 3E (UX-3E-LABELS section 4, approved as O86). The bar's Extract and BLAST titles are the shared row
// command titles, the provenance icon reads Show Provenance, a greyed button's reason leads its tooltip and its
// VoiceOver hint, the bar holds the BLAST Results button, and an extraction reaches the App as one request.

import AppKit
import LungfishWorkflow
import XCTest
@testable import LungfishKit

@MainActor
final class ClassifierResultActionsWordsTests: XCTestCase {

    func testBarTitlesMatchTheRowCommands() {
        let actions = ClassifierResultActions()
        XCTAssertEqual(actions.bar.extractButton.title, ResultRowCommand.extractReads.title)
        XCTAssertEqual(actions.bar.blastButton.title, ResultRowCommand.blastVerify.title)
        XCTAssertEqual(actions.bar.provenanceButton.accessibilityLabel(), "Show Provenance")
        XCTAssertEqual(actions.blastResultsButton.title, "BLAST Results")
        XCTAssertEqual(actions.blastResultsButton.accessibilityLabel(), "BLAST Results")
        XCTAssertTrue(actions.blastResultsButton.isDescendant(of: actions.bar), "the bar holds BLAST Results")
    }

    func testReasonLeadsTooltipAndHint() {
        let actions = ClassifierResultActions()
        let reason = "Select one or more rows to extract their reads."
        actions.bar.setExtractEnabled(false, reason: reason)

        XCTAssertEqual(
            actions.bar.extractButton.toolTip,
            "\(reason) \(LungfishHelpContent.classifierExtractFASTQ.summary)"
        )
        XCTAssertEqual(actions.bar.extractButton.accessibilityHelp()?.hasPrefix(reason + " "), true)

        actions.bar.setExtractEnabled(true)
        XCTAssertEqual(actions.bar.extractButton.toolTip, LungfishHelpContent.classifierExtractFASTQ.summary)
    }

    /// Each selection state gives the ruled reason of every greyed button (R1 to R4) and counts rows in rows.
    func testSelectionStatesGiveTheRuledReasons() {
        let actions = ClassifierResultActions()
        let bar = actions.bar

        XCTAssertFalse(bar.extractButton.isEnabled, "nothing is picked when a viewer opens")
        XCTAssertEqual(bar.extractButton.toolTip?.hasPrefix(ClassifierActionWords.selectRowsToExtract), true)

        actions.showNoSelection(prompt: "Select an organism to view details")
        XCTAssertEqual(bar.infoLabel.stringValue, "Select an organism to view details")
        XCTAssertFalse(bar.blastButton.isEnabled)
        XCTAssertEqual(bar.blastButton.toolTip?.hasPrefix("Select a row to verify it with BLAST. "), true)
        XCTAssertEqual(bar.extractButton.toolTip?.hasPrefix("Select one or more rows to extract their reads. "), true)

        actions.showSelection(count: 1)
        XCTAssertEqual(bar.infoLabel.stringValue, "1 row selected")
        XCTAssertTrue(bar.blastButton.isEnabled)
        XCTAssertTrue(bar.extractButton.isEnabled)

        actions.showSelection(count: 12)
        XCTAssertEqual(bar.infoLabel.stringValue, "12 rows selected")
        XCTAssertFalse(bar.blastButton.isEnabled)
        XCTAssertEqual(bar.blastButton.accessibilityHelp()?.hasPrefix("Select one row to verify it with BLAST. "), true)
        XCTAssertTrue(bar.extractButton.isEnabled)

        actions.showSeveralSamples(info: "Organism overview of 3 samples.")
        XCTAssertEqual(
            bar.blastButton.toolTip?.hasPrefix("Choose one sample to verify its rows with BLAST. "), true
        )
        XCTAssertFalse(bar.extractButton.isEnabled)
    }

    /// The App answers one request that carries the row count and the left-out line, and an empty one asks nothing.
    func testExtractionRequestReachesTheApp() {
        let actions = ClassifierResultActions()
        var received: [ClassifierExtractionRequest] = []
        actions.onExtractionRequested = { received.append($0) }
        let selector = ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001526.4"], taxIds: [])
        let request = ClassifierExtractionRequest(
            tool: .taxtriage, resultPath: URL(fileURLWithPath: "/tmp/result"), selectors: [selector],
            suggestedName: "taxtriage_S1_NC_001526.4", selectedRowCount: 2, leftOutNotice: "1 selected row is left out."
        )

        actions.requestExtraction(request)
        actions.requestExtraction(ClassifierExtractionRequest(
            tool: .taxtriage, resultPath: request.resultPath, selectors: [], suggestedName: "nothing"
        ))

        XCTAssertEqual(received, [request])
    }

    /// The BLAST Results button follows the pane, and it reopens the pane a person closed.
    func testBlastResultsButtonFollowsThePane() {
        let actions = ClassifierResultActions()
        var changes: [Bool] = []
        actions.onBlastDrawerOpenChanged = { changes.append($0) }

        actions.showBlastFailure(ClassifierActionWords.alignmentFileMissing)
        XCTAssertTrue(actions.isBlastDrawerOpen)
        XCTAssertEqual(actions.blastResultsButton.state, .on)

        actions.blastResultsButton.performClick(nil)
        XCTAssertFalse(actions.isBlastDrawerOpen)
        XCTAssertEqual(actions.blastResultsButton.state, .off)

        actions.blastResultsButton.performClick(nil)
        XCTAssertTrue(actions.isBlastDrawerOpen)
        XCTAssertEqual(changes, [true, false, true])
    }
}
