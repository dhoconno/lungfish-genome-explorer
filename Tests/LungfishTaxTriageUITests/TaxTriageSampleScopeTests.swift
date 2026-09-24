// TaxTriageSampleScopeTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// UX-05: the organism search field used to hide itself whenever a result had
// only one sample (`rebuildSampleFilterSegments` coupled its visibility to
// the now-redundant sample segmented control), leaving the single most common
// case — a single-sample TaxTriage run — with no way to search organisms.
//
// UX-18: the audit's comparison matrix records TaxTriage's sample scope UI as
// "segmented control, one segment per sample", which "doesn't scale to large
// sample counts". Reproducing this finding surfaced that it no longer holds
// as stated: `configureFromDatabase` — the sole production entry point
// (`ViewerViewController+TaxTriage.swift`) — always sets `isBatchGroupMode`,
// whose "Show flat table, hide single-result UI" branch force-hides
// `sampleFilterControl` unconditionally. The segmented control's only would-be
// caller, `enableMultiSampleFlatTableMode()`, is never invoked from anywhere
// in the app. So today the real (and already-scalable) sample-scope surface
// for every reachable TaxTriage result is the Inspector's shared
// `ClassifierSamplePickerState`/`ClassifierSamplePickerView` multi-select
// checklist (`applyBatchGroupFilter`), the same component Kraken2/EsViritu/12S
// use — matching the audit's own recommendation to converge on it. A popup
// alternative to the segmented control was still added, in case a future
// caller reactivates the single-sample-result path, but it is not reachable
// today, and this file's tests reflect the code as it is actually exercised.

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit

final class TaxTriageSampleScopeTests: XCTestCase {
    @MainActor func testSingleSampleResultKeepsOrganismSearchFieldVisible() throws {
        let (vc, tempDir) = try Self.makeController(sampleCount: 1)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertTrue(vc.testSampleFilterControl.isHidden, "the segmented control is redundant with one sample and should hide")
        XCTAssertFalse(
            vc.testingOrganismSearchField.isHidden,
            "UX-05: a single-sample result must still expose organism search"
        )
    }

    @MainActor func testBatchGroupModeAlwaysHidesBothSampleScopeControlsRegardlessOfCount() throws {
        // Every production TaxTriage result reaches the viewer through
        // `configureFromDatabase`, which is always batch-group mode: sample
        // scoping is exclusively the Inspector's multi-select picker
        // (`applyBatchGroupFilter`/`samplePickerState`), never
        // `sampleFilterControl`/`sampleFilterPopUp`. This holds at both a
        // small and a large sample count.
        for count in [3, 12] {
            let (vc, tempDir) = try Self.makeController(sampleCount: count)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            XCTAssertTrue(vc.testSampleFilterControl.isHidden, "count=\(count)")
            XCTAssertTrue(vc.testSampleFilterPopUp.isHidden, "count=\(count)")
            XCTAssertNotNil(vc.samplePickerState, "batch-group mode must populate the shared Inspector picker state")
            XCTAssertEqual(vc.samplePickerState.selectedSamples.count, count)
        }
    }

    @MainActor func testSampleFilterPopUpBuildsScalableItemListWhenTheUnreachableSingleResultPathIsDriven() throws {
        // `enableMultiSampleFlatTableMode()` (the only caller that would show
        // `sampleFilterControl`/`sampleFilterPopUp`) is never invoked from
        // anywhere in the app today — see the file-level note. This test
        // exercises `rebuildSampleFilterSegments` directly, bypassing
        // `configureFromDatabase`'s batch-group re-hide, to prove the popup
        // itself is correctly built and scales past the threshold, so the
        // mechanism is ready if a future caller reactivates that path.
        let (vc, tempDir) = try Self.makeController(sampleCount: 12)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        vc.testRebuildSampleFilterSegments()

        XCTAssertTrue(vc.testSampleFilterControl.isHidden, "segmented control should hide once the popup takes over")
        XCTAssertFalse(vc.testSampleFilterPopUp.isHidden)
        XCTAssertEqual(vc.testSampleFilterPopUp.numberOfItems, 13)  // "All Samples" + 12
    }

    @MainActor func testSelectNextSampleAdvancesPopUpSelectionAtLargeSampleCounts() throws {
        let (vc, tempDir) = try Self.makeController(sampleCount: 12)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        vc.testRebuildSampleFilterSegments()

        XCTAssertEqual(vc.testSampleFilterPopUp.indexOfSelectedItem, 0)
        vc.selectNextSample(nil)
        XCTAssertEqual(vc.testSampleFilterPopUp.indexOfSelectedItem, 1)
        vc.selectAllSamplesOverview(nil)
        XCTAssertEqual(vc.testSampleFilterPopUp.indexOfSelectedItem, 0)
    }

    // MARK: - Fixture

    @MainActor private static func makeController(sampleCount: Int) throws -> (TaxTriageResultViewController, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageSampleScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let rows = (0..<sampleCount).map { index in
            TaxTriageTaxonomyRow(
                sample: "sample-\(index)",
                organism: "Organism \(index)",
                taxId: index,
                status: nil,
                tassScore: 0.9,
                readsAligned: 100,
                uniqueReads: 50,
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

        let deadline = Date().addingTimeInterval(10)
        while vc.testBatchFlatTableView.displayedRows.isEmpty
            && sampleCount > 1
            && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        return (vc, tempDir)
    }
}
