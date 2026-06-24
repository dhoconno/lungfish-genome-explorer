// TaxTriageResultViewControllerSmokeTests.swift - Standalone smoke test for the TaxTriage leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit

final class TaxTriageResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testViewControllerInstantiates() {
        let vc = TaxTriageResultViewController()
        XCTAssertNotNil(vc.view)
    }

    @MainActor func testDatabaseConfiguredBeforeWindowDisplaysBatchTableAfterAttach() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageInitialLayout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let row = TaxTriageTaxonomyRow(
            sample: "sample-1",
            organism: "Influenza A virus",
            taxId: 11320,
            status: nil,
            tassScore: 0.95,
            readsAligned: 12,
            uniqueReads: 12,
            pctReads: nil,
            pctAlignedReads: nil,
            coverageBreadth: nil,
            meanCoverage: nil,
            meanDepth: nil,
            confidence: nil,
            k2Reads: nil,
            parentK2Reads: nil,
            giniCoefficient: nil,
            meanBaseQ: nil,
            meanMapQ: nil,
            mapqScore: nil,
            disparityScore: nil,
            minhashScore: nil,
            diamondIdentity: nil,
            k2DisparityScore: nil,
            siblingsScore: nil,
            breadthWeightScore: nil,
            hhsPercentile: nil,
            isAnnotated: nil,
            annClass: nil,
            microbialCategory: nil,
            highConsequence: nil,
            isSpecies: nil,
            pathogenicSubstrains: nil,
            sampleType: nil,
            bamPath: nil,
            bamIndexPath: nil,
            primaryAccession: "NC_123456.1",
            accessionLength: 1000
        )
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(vc.testBatchFlatTableView.isHidden)
        XCTAssertGreaterThan(vc.testRightPaneContainer.frame.width, 300)
        XCTAssertGreaterThan(vc.testBatchFlatTableView.frame.width, 300)
        XCTAssertGreaterThan(vc.testBatchFlatTableView.frame.height, 300)
    }
}
