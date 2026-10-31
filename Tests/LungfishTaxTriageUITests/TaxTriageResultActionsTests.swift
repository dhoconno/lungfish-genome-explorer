// TaxTriageResultActionsTests.swift - TaxTriage's bar speaks the shared classifier label set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane 3E (UX-3E-LABELS, approved as O86). TaxTriage adopts `ClassifierResultActions` first. A greyed
// button leads its tooltip and VoiceOver hint with the reason it is greyed (R1, R2 and R4), the bar counts rows
// in rows, and the bar holds the BLAST Results button that shows or hides the BLAST results below the table
// (U-3E-1). The view has no defaults seam and these tests touch none.

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageResultActionsTests: XCTestCase {

    private static let first = "Human papillomavirus type 16"
    private static let second = "Human papillomavirus type 18"

    /// With no row picked, the greyed Extract and BLAST buttons say why (R4 and R1). At the base, clearing the
    /// selection left Extract with the help of an enabled button, or enabled.
    func testGreyedExtractCarriesTheSelectReason() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        let bar = vc.testActionBar

        try select([Self.first], in: vc) { bar.extractButton.isEnabled }
        vc.testBatchFlatTableView.testTableView.deselectAll(nil)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { bar.infoLabel.stringValue == "Select an organism to view details" },
            "the cleared selection did not reach the bar"
        )

        XCTAssertFalse(bar.extractButton.isEnabled, "Extract has no rows to extract")
        let extractReason = "Select one or more rows to extract their reads."
        XCTAssertEqual(bar.extractButton.toolTip?.hasPrefix(extractReason + " "), true, bar.extractButton.toolTip ?? "")
        XCTAssertEqual(bar.extractButton.accessibilityHelp()?.hasPrefix(extractReason), true)
        let blastReason = "Select a row to verify it with BLAST."
        XCTAssertEqual(bar.blastButton.toolTip?.hasPrefix(blastReason + " "), true, bar.blastButton.toolTip ?? "")
        XCTAssertEqual(bar.blastButton.accessibilityHelp()?.hasPrefix(blastReason), true)
    }

    /// Two rows picked: the bar counts rows, and BLAST asks for one row (R2).
    func testTwoRowsReadAsRowsAndBlastAsksForOne() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        let bar = vc.testActionBar

        try select([Self.first, Self.second], in: vc) { bar.infoLabel.stringValue.hasPrefix("2 ") }

        XCTAssertEqual(bar.infoLabel.stringValue, "2 rows selected")
        XCTAssertFalse(bar.blastButton.isEnabled)
        let reason = "Select one row to verify it with BLAST."
        XCTAssertEqual(bar.blastButton.toolTip?.hasPrefix(reason + " "), true, bar.blastButton.toolTip ?? "")
        XCTAssertEqual(bar.blastButton.accessibilityHelp()?.hasPrefix(reason), true)
        XCTAssertTrue(bar.extractButton.isEnabled, "two rows can be extracted together")
    }

    /// The bar holds the BLAST Results button (U-3E-1). It reopens the results after a person closed them, and its
    /// state follows the pane when a BLAST run opens it.
    func testBarHoldsTheBlastResultsButton() throws {
        let vc = TaxTriageResultViewController()
        isolateLayouts(vc)
        _ = vc.view
        let button = try XCTUnwrap(
            Self.buttons(in: vc.testActionBar).first { $0.title == "BLAST Results" },
            "TaxTriage's bar has no BLAST Results button"
        )
        XCTAssertEqual(button.accessibilityLabel(), "BLAST Results")
        XCTAssertEqual(button.toolTip, "Show or hide the BLAST results below the table.")
        XCTAssertFalse(vc.isBlastDrawerOpen)

        vc.showBlastFailure("NCBI BLAST did not return a result.")
        XCTAssertTrue(vc.isBlastDrawerOpen)
        XCTAssertEqual(button.state, .on, "the button shows that the results are open")

        button.performClick(nil)
        XCTAssertFalse(vc.isBlastDrawerOpen, "the button closes the results")
        XCTAssertEqual(button.state, .off)

        button.performClick(nil)
        XCTAssertTrue(vc.isBlastDrawerOpen, "the button reopens the results a person closed")
        XCTAssertEqual(button.state, .on)
    }

    // MARK: - Fixture

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
        }
    }

    private func makeController(_ fixture: Fixture) -> TaxTriageResultViewController {
        let vc = TaxTriageResultViewController()
        isolateLayouts(vc)
        _ = vc.view
        vc.configureFromDatabase(fixture.database, resultURL: fixture.root)
        // A ceiling, not a speed check. The rows load on a detached task and the wait ends as soon as they show.
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testBatchFlatTableView.displayedRows.count == 2 },
            "the rows did not load"
        )
        return vc
    }

    /// Selects the flat-table rows of `organisms` and runs the loop until `settled` holds.
    private func select(
        _ organisms: [String], in vc: TaxTriageResultViewController, until settled: () -> Bool
    ) throws {
        let rows = vc.testBatchFlatTableView.displayedRows
        let indexes = try organisms.map { name in
            try XCTUnwrap(rows.firstIndex { $0.organism == name }, "\(name) is not in the flat table")
        }
        vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(indexes), byExtendingSelection: false)
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup, settled), "the selection did not settle")
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let database: TaxTriageDatabase

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TaxTriageResultActions-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("sample-1/minimap2", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("sample-1.bam"))
            try Data().write(to: folder.appendingPathComponent("sample-1.bam.bai"))
            database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: [
                    Self.row(TaxTriageResultActionsTests.first, taxId: 333760, reads: 40, accession: "NC_001526.4"),
                    Self.row(TaxTriageResultActionsTests.second, taxId: 333761, reads: 12, accession: "NC_001357.1"),
                ],
                metadata: ["tool": "taxtriage"]
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func row(_ organism: String, taxId: Int, reads: Int, accession: String) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: "sample-1", organism: organism, taxId: taxId, status: nil, tassScore: 0.9, readsAligned: reads,
                uniqueReads: reads / 2, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
                meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
                meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
                diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
                hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
                isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
                bamPath: "sample-1/minimap2/sample-1.bam", bamIndexPath: "sample-1/minimap2/sample-1.bam.bai",
                primaryAccession: accession, accessionLength: 7906
            )
        }
    }
}
