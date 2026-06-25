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

    @MainActor func testDatabaseLoadDefaultsToStackedLayoutAndSelectsTopRow() throws {
        let defaults = UserDefaults.standard
        let savedLayout = defaults.object(forKey: MetagenomicsPanelLayout.defaultsKey)
        let savedLegacy = defaults.object(forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        defaults.removeObject(forKey: MetagenomicsPanelLayout.defaultsKey)
        defaults.removeObject(forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        defer {
            if let savedLayout {
                defaults.set(savedLayout, forKey: MetagenomicsPanelLayout.defaultsKey)
            } else {
                defaults.removeObject(forKey: MetagenomicsPanelLayout.defaultsKey)
            }
            if let savedLegacy {
                defaults.set(savedLegacy, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
            } else {
                defaults.removeObject(forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageStackedDefault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let rows = [
            TaxTriageTaxonomyRow(
                sample: "sample-1",
                organism: "Aeromonas salmonicida",
                taxId: 645,
                status: nil,
                tassScore: 0.99,
                readsAligned: 21_383,
                uniqueReads: 9_690,
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
                primaryAccession: "NZ_CP110645.1",
                accessionLength: 4_866_465
            )
        ]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "taxtriage"])

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

        let deadline = Date().addingTimeInterval(2)
        while vc.testBatchFlatTableView.displayedRows.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testRightPaneContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testLeftPaneContainer)
        XCTAssertEqual(vc.testBatchFlatTableView.selectedMetrics().map(\.organism), ["Aeromonas salmonicida"])
        XCTAssertFalse(vc.testLeftPaneContainer.isHidden)
    }

    @MainActor func testDatabaseConfiguredBeforeWindowDisplaysBatchTableAfterAttach() throws {
        let defaults = UserDefaults.standard
        let savedLayout = defaults.object(forKey: MetagenomicsPanelLayout.defaultsKey)
        let savedLegacy = defaults.object(forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        defaults.set(MetagenomicsPanelLayout.listLeading.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)
        defaults.set(true, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        defer {
            if let savedLayout {
                defaults.set(savedLayout, forKey: MetagenomicsPanelLayout.defaultsKey)
            } else {
                defaults.removeObject(forKey: MetagenomicsPanelLayout.defaultsKey)
            }
            if let savedLegacy {
                defaults.set(savedLegacy, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
            } else {
                defaults.removeObject(forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
            }
        }

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

    @MainActor func testDatabaseRowsLoadAsynchronouslyAfterInitialConfigure() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageLazyLoad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rows = (0..<25).map { index in
            TaxTriageTaxonomyRow(
                sample: "sample-1",
                organism: "Organism \(index)",
                taxId: 10_000 + index,
                status: nil,
                tassScore: 0.75,
                readsAligned: 10 + index,
                uniqueReads: 5 + index,
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
                primaryAccession: "NC_\(index)",
                accessionLength: 1000
            )
        }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        XCTAssertTrue(
            vc.testBatchFlatTableView.displayedRows.isEmpty,
            "configureFromDatabase should return before SQLite rows are paged into the viewport"
        )

        let deadline = Date().addingTimeInterval(2)
        while vc.testBatchFlatTableView.displayedRows.count < rows.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, rows.count)
    }
}
