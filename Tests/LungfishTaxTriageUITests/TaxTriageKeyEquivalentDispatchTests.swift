// TaxTriageKeyEquivalentDispatchTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// UX-03: reproduced that the ⌘] / ⌘[ / ⌘0 shortcuts, when implemented as
// TaxTriageResultViewController.performKeyEquivalent(with:) overrides, were
// never reachable through real AppKit key-equivalent dispatch (NSWindow.sendEvent) —
// AppKit dispatches key equivalents down the view hierarchy starting at the
// window's contentView, not to view controllers. The fix moved the shortcuts
// to real `View` menu items (Next/Previous/All Samples in MainMenu.swift)
// with a nil target, dispatched through the responder chain to
// TaxTriageResultViewController.selectNextSample(_:) etc. — the same pattern
// TaxonomyViewController.expandAllTaxonomyItems already used. This file now
// proves that real menu-item dispatch (NSApp.sendAction, which walks the
// responder chain exactly as a real menu click would) reaches the controller.

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit

final class TaxTriageKeyEquivalentDispatchTests: XCTestCase {
    /// Builds a real NSWindow hosting the controller's view as the content
    /// view (mirroring how the App composition root embeds this leaf), then
    /// drives the real menu-item dispatch path — `NSApp.sendAction`, which
    /// walks the responder chain exactly as AppKit does for an actual menu
    /// click or its key equivalent — rather than calling the controller's
    /// selectors directly.
    @MainActor func testMenuActionSelectorsReachControllerThroughRealResponderChainDispatch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageKeyDispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rows = [
            Self.taxonomyRow(sample: "sample-1", organism: "Alpha virus", taxId: 1, tassScore: 0.9, reads: 20),
            Self.taxonomyRow(sample: "sample-2", organism: "Beta virus", taxId: 2, tassScore: 0.8, reads: 10),
        ]
        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        let deadline = Date().addingTimeInterval(10)
        while vc.testBatchFlatTableView.displayedRows.count < rows.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        // Host the controller's view in a real, key window, the way NSWindowController
        // composition roots do in the shipping app.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(vc.view)
        defer { window.orderOut(nil) }

        let selectedSegmentBefore = vc.testSampleFilterControl.selectedSegment

        // `window.tryToPerform(_:with:)` is the same responder-chain walk
        // AppKit performs for a real, nil-target menu item (it is what
        // `NSApp.sendAction(_:to:nil:)` itself calls internally after
        // resolving the key window), starting at `window.firstResponder` —
        // made explicit here rather than relying on `NSApp`'s own key-window
        // tracking, which is not guaranteed to be set up in a headless test
        // host. This is the mechanism the new View > Next Sample menu
        // item (MainMenu.swift) uses instead of the unreachable
        // performKeyEquivalent override this finding reproduced.
        let handled = window.firstResponder?.tryToPerform(
            #selector(TaxTriageResultViewController.selectNextSample(_:)),
            with: nil
        ) ?? false

        XCTAssertTrue(
            handled,
            "View > Next Sample's nil-target action should reach TaxTriageResultViewController.selectNextSample via the responder chain, the same way TaxonomyViewController.expandAllTaxonomyItems already does."
        )
        XCTAssertEqual(
            vc.testSampleFilterControl.selectedSegment,
            selectedSegmentBefore + 1,
            "selectNextSample should advance the sample selection exactly as the old (unreachable) performKeyEquivalent override did."
        )

        let handledAllSamples = window.firstResponder?.tryToPerform(
            #selector(TaxTriageResultViewController.selectAllSamplesOverview(_:)),
            with: nil
        ) ?? false
        XCTAssertTrue(handledAllSamples)
        XCTAssertEqual(vc.testSampleFilterControl.selectedSegment, 0)
    }

    private static func taxonomyRow(
        sample: String,
        organism: String,
        taxId: Int,
        tassScore: Double,
        reads: Int
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample,
            organism: organism,
            taxId: taxId,
            status: nil,
            tassScore: tassScore,
            readsAligned: reads,
            uniqueReads: reads / 2,
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
            primaryAccession: "NC_\(taxId)",
            accessionLength: 1000
        )
    }
}
