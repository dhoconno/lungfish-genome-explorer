// EsVirituResultActionsTests.swift - EsViritu's bar is the shared classifier action bar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ADOPT (plan exit check 4, O86, UX-3E-LABELS). EsViritu adopts `ClassifierResultActions`. Its bar
// holds Verify with BLAST…, Extract Reads… and BLAST Results in the ruling's titles, VoiceOver labels and hints, and
// BLAST Results reopens the BLAST results a person closed. The view has no defaults seam and these tests touch none.

import AppKit
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishEsVirituUI

@MainActor
final class EsVirituResultActionsTests: XCTestCase {

    /// The bar's three shared buttons read the ruling's words. At the base the bar had no BLAST Results button.
    func testBarHoldsTheSharedButtonsInTheRulingsWords() throws {
        let vc = EsVirituResultViewController()
        isolateLayouts(vc)
        _ = vc.view
        let bar = vc.testActionBar

        XCTAssertEqual(bar.blastButton.title, "Verify with BLAST\u{2026}")
        XCTAssertEqual(bar.blastButton.accessibilityLabel(), "Verify with BLAST")
        XCTAssertEqual(bar.blastButton.accessibilityHelp()?.hasPrefix("Select a row to verify it with BLAST. "), true)
        XCTAssertEqual(
            bar.blastButton.accessibilityHelp()?.contains("Uses BLASTN without taxon restriction by default."), true
        )
        XCTAssertEqual(bar.extractButton.title, "Extract Reads\u{2026}")
        XCTAssertEqual(bar.extractButton.accessibilityLabel(), "Extract Reads")
        XCTAssertEqual(
            bar.extractButton.accessibilityHelp()?.hasPrefix("Select one or more rows to extract their reads. "), true
        )
        XCTAssertEqual(
            bar.extractButton.accessibilityHelp()?.contains("Opens a dialog to save the reads as FASTQ or FASTA"), true
        )

        let results = try Self.blastResultsButton(in: bar)
        XCTAssertEqual(results.title, "BLAST Results")
        XCTAssertEqual(results.accessibilityLabel(), "BLAST Results")
        XCTAssertEqual(results.toolTip, "Show or hide the BLAST results below the table.")
        XCTAssertEqual(results.accessibilityHelp(), "Shows or hides the BLAST results below the table.")
    }

    /// BLAST Results closes the results and reopens them as they were (U-3E-1).
    func testBlastResultsClosesAndReopensTheResults() throws {
        let vc = EsVirituResultViewController()
        isolateLayouts(vc)
        _ = vc.view
        let button = try Self.blastResultsButton(in: vc.testActionBar)
        XCTAssertEqual(button.state, .off, "nothing is open when the viewer opens")

        vc.showBlastFailure("NCBI BLAST did not return a result.")
        let drawer = try XCTUnwrap(vc.testBlastDrawerContainer)
        XCTAssertFalse(drawer.isHidden)
        XCTAssertEqual(button.state, .on, "the button shows that the results are open")

        button.performClick(nil)
        XCTAssertTrue(drawer.isHidden, "the button closes the results")
        XCTAssertEqual(button.state, .off)

        button.performClick(nil)
        XCTAssertFalse(drawer.isHidden, "the button reopens the results a person closed")
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(drawer.blastResultsTab.emptyStateDetailText, "NCBI BLAST did not return a result.")
    }

    /// NVD-RUN-AGAIN-STALE-CONTIG (lane ROWPANE). EsViritu gives its pane no Re-run action, so the pane offers no Re-run
    /// button. At the base the button showed and did nothing.
    func testPaneOffersNoDeadRerun() throws {
        let vc = EsVirituResultViewController()
        isolateLayouts(vc)
        _ = vc.view
        vc.showBlastFailure("NCBI BLAST did not return a result.")
        let drawer = try XCTUnwrap(vc.testBlastDrawerContainer)

        XCTAssertTrue(drawer.blastResultsTab.rerunBlastButton.isHidden)
    }

    // MARK: - Fixture

    private static func blastResultsButton(in bar: ClassifierActionBar) throws -> NSButton {
        try XCTUnwrap(
            buttons(in: bar).first { $0.accessibilityIdentifier() == "classifier-result-blast-results" },
            "EsViritu's bar has no BLAST Results button of the shared component"
        )
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
        }
    }
}
