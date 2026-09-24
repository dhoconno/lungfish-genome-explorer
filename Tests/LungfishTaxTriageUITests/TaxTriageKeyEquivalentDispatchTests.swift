// TaxTriageKeyEquivalentDispatchTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// UX-03: reproduces (or refutes) whether the ⌘] / ⌘[ / ⌘0 shortcuts implemented in
// TaxTriageResultViewController.performKeyEquivalent(with:) are actually reachable
// through real AppKit key-equivalent dispatch (NSWindow.sendEvent), as opposed to
// only being reachable when a test calls controller.performKeyEquivalent(with:)
// directly. AppKit dispatches key equivalents down the view hierarchy starting at
// the window's contentView, not to view controllers, so a plain NSViewController
// override with no forwarding view is expected to never see the event this way.

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit

final class TaxTriageKeyEquivalentDispatchTests: XCTestCase {
    /// Builds a real NSWindow, hosts the controller's view as the content view
    /// (mirroring how the App composition root embeds this leaf), and sends a
    /// ⌘] key-down event through the window's real event-dispatch path rather
    /// than calling performKeyEquivalent on the controller directly.
    @MainActor func testCommandBracketDoesNotReachControllerThroughRealWindowDispatch() throws {
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
        // composition roots do in the shipping app -- NOT calling performKeyEquivalent
        // on the controller directly.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        guard let cmdBracket = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "]",
            charactersIgnoringModifiers: "]",
            isARepeat: false,
            keyCode: 30
        ) else {
            throw XCTSkip("Could not synthesize NSEvent in this environment")
        }

        let selectedSegmentBefore = vc.testSampleFilterControl.selectedSegment

        // This is the real AppKit path: NSApp.sendEvent -> window.sendEvent, which
        // walks contentView -> subviews for key equivalents, then the main menu.
        // It does NOT visit the window's contentViewController's performKeyEquivalent
        // override unless some view along the chain forwards to it.
        window.sendEvent(cmdBracket)

        // Reproduced: dispatching the real key event through the window never
        // reaches the controller's performKeyEquivalent override, so the
        // segmented control's selection is unchanged.
        XCTAssertEqual(
            vc.testSampleFilterControl.selectedSegment,
            selectedSegmentBefore,
            "⌘] delivered through real window dispatch should not reach TaxTriageResultViewController.performKeyEquivalent, since AppKit routes key equivalents through the view hierarchy, not to view controllers."
        )

        // Calling performKeyEquivalent directly (as the pre-existing unit
        // tests do) still handles the shortcut and does not crash now that
        // configureFromDatabase rebuilds the segmented control to match
        // sampleIds.count (previously it kept its single-segment default,
        // so this direct call crashed with an NSSegmentedCell range
        // exception the instant a multi-sample batch was loaded).
        let directCallHandled = vc.performKeyEquivalent(with: cmdBracket)
        XCTAssertTrue(
            directCallHandled,
            "The controller's own performKeyEquivalent override should handle ⌘] when called directly, confirming the logic exists but is unreachable via window dispatch."
        )
        XCTAssertEqual(vc.testSampleFilterControl.selectedSegment, selectedSegmentBefore + 1)
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
