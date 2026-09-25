// TaxTriageSampleFilterAlignmentPaneTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Regression: after the Inspector Sample Filter changed (a sample unticked or
// ticked again) on a TaxTriage result in List Over Detail layout, the
// alignment pane below the table stopped drawing for every row until the
// result was reopened. The filter reload collapsed the detail pane, and the
// App's detached viewer (whose header gives it a minimum height) kept
// NSSplitView from collapsing it fully. The reveal treated any pane taller
// than 1 pt as shown and `adjustSubviews()` then kept its collapsed
// proportion, so the pane stayed about 31 pt tall with a zero-height
// sequence view for every later selection.

import XCTest
import AppKit
@testable import LungfishApp
@testable import LungfishTaxTriageUI
import LungfishIO
import LungfishKit

@MainActor
final class TaxTriageSampleFilterAlignmentPaneTests: XCTestCase {
    func testSelectingARowAfterASampleFilterChangeInstallsItsAlignmentInAFullSizePane() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repositoryRoot.appendingPathComponent("Tests/Fixtures/classifier-full-viewer", isDirectory: true)
        let fixtureBAM = fixture.appendingPathComponent("evidence.bam")
        let fixtureIndex = fixture.appendingPathComponent("evidence.bam.bai")
        guard FileManager.default.isReadableFile(atPath: fixtureBAM.path),
              FileManager.default.isReadableFile(atPath: fixtureIndex.path) else {
            XCTFail("Missing repository fixture Tests/Fixtures/classifier-full-viewer/evidence.bam(.bai)")
            return
        }

        // Evidence must live inside the result folder, as TaxTriage writes it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageFilterPane-\(UUID().uuidString)", isDirectory: true)
        let minimap = root.appendingPathComponent("minimap2", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bamURL = minimap.appendingPathComponent("evidence.bam")
        let indexURL = minimap.appendingPathComponent("evidence.bam.bai")
        try FileManager.default.copyItem(at: fixtureBAM, to: bamURL)
        try FileManager.default.copyItem(at: fixtureIndex, to: indexURL)
        let rows = [
            Self.row(sample: "sample-1", organism: "Alpha virus", taxId: 1, tass: 0.9, bam: bamURL, index: indexURL),
            Self.row(sample: "sample-1", organism: "Beta virus", taxId: 2, tass: 0.8, bam: bamURL, index: indexURL),
            Self.row(sample: "sample-2", organism: "Gamma virus", taxId: 3, tass: 0.7, bam: bamURL, index: indexURL),
        ]
        let db = try TaxTriageDatabase.create(
            at: root.appendingPathComponent("taxtriage.sqlite"),
            rows: rows,
            metadata: ["tool": "taxtriage"]
        )

        let suiteName = "TaxTriageFilterPane.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(MetagenomicsPanelLayout.stacked.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)

        let provider = ClassifierAlignmentEvidenceViewportController()
        let vc = TaxTriageResultViewController()
        vc.layoutDefaults = defaults
        vc.classifierAlignmentViewerFactory = { provider }
        _ = vc.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        vc.configureFromDatabase(db, resultURL: root)
        window.layoutIfNeeded()

        func pump(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func waitForRows(_ condition: ([TaxTriageMetric]) -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition(vc.testBatchFlatTableView.displayedRows) && Date() < deadline { pump(0.02) }
            pump(0.2)
        }
        func selectAndAssert(sample: String, organism: String, _ context: String) throws {
            let index = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.firstIndex {
                $0.sample == sample && $0.organism == organism
            }, context)
            vc.testBatchFlatTableView.testTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let deadline = Date().addingTimeInterval(10)
            while (provider.status == .loading || provider.status == .idle) && Date() < deadline { pump(0.02) }
            window.layoutIfNeeded()
            pump(0.1)

            let source = try XCTUnwrap(provider.viewer.viewerView.testDetachedAlignmentSource, "\(context): \(provider.status)")
            XCTAssertEqual(source.identityURL, bamURL, context)
            XCTAssertEqual(source.contig.name, "synthetic-track-A", context)

            let evidenceView = provider.viewer.view
            XCTAssertTrue(evidenceView.isDescendant(of: vc.testLeftPaneContainer), context)
            XCTAssertFalse(evidenceView.isHiddenOrHasHiddenAncestor, context)
            XCTAssertGreaterThanOrEqual(
                vc.testLeftPaneContainer.frame.height, 250,
                "\(context): the alignment pane must be re-expanded, not left as a sliver"
            )
            XCTAssertGreaterThan(provider.viewer.viewerView.frame.height, 100, "\(context): the sequence view has room to draw")
        }

        waitForRows { $0.count == 3 }
        try selectAndAssert(sample: "sample-1", organism: "Beta virus", "before the filter change")

        vc.samplePickerState.selectedSamples = ["sample-1"]
        NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
        waitForRows { rows in !rows.isEmpty && rows.allSatisfy { $0.sample == "sample-1" } }
        try selectAndAssert(sample: "sample-1", organism: "Beta virus", "after unticking a sample")
        try selectAndAssert(sample: "sample-1", organism: "Alpha virus", "after reselecting another row")

        vc.samplePickerState.selectedSamples = ["sample-1", "sample-2"]
        NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
        waitForRows { $0.count == 3 }
        try selectAndAssert(sample: "sample-2", organism: "Gamma virus", "after ticking it again")
    }

    private static func row(
        sample: String,
        organism: String,
        taxId: Int,
        tass: Double,
        bam: URL,
        index: URL
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: taxId, status: nil, tassScore: tass,
            readsAligned: 2, uniqueReads: 2, pctReads: nil, pctAlignedReads: nil,
            coverageBreadth: nil, meanCoverage: nil, meanDepth: nil, confidence: "High",
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
            mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil,
            isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: bam.path, bamIndexPath: index.path,
            primaryAccession: "synthetic-track-A", accessionLength: 120
        )
    }
}
