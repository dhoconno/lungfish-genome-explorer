// ClassifierExtractionMenuWiringTests.swift — VC → menu → orchestrator wiring
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Phase 7 Task 7.2 — Verifies that a context-menu "Extract Reads…" click
/// reaches `TaxonomyReadExtractionAction.present()` with the expected
/// `Context` propagated from the table-view callback wiring.
///
/// These tests complement the Phase 6 I3 invariants (which only verify the
/// `onExtractReadsRequested` callback fires): here we plug that callback into
/// a code path that actually calls `present()` and assert on the Context seen
/// by the orchestrator via a `#if DEBUG` capture hook (`testingCaptureOnly`).
///
/// The ViralDetectionTableView and TaxonomyTableView are the two table views
/// that live at the view-level (not buried inside a full VC). The other three
/// tools (TaxTriage, NAO-MGS, NVD) own their outline views at the VC level
/// and their context-menu → `present()` wiring is covered by the Phase 6
/// source-level I1 tests plus manual smoke testing; instantiating the full
/// VC here requires a live AppKit window hierarchy that isn't practical in
/// unit tests.
@MainActor
final class ClassifierExtractionMenuWiringTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Enable capture-only mode on the shared orchestrator so real dialog
        // presentation is suppressed.
        TaxonomyReadExtractionAction.shared.testingCaptureOnly = true
        TaxonomyReadExtractionAction.shared.testingCapture = .init()
    }

    override func tearDown() {
        TaxonomyReadExtractionAction.shared.testingCaptureOnly = false
        TaxonomyReadExtractionAction.shared.testingCapture = .init()
        super.tearDown()
    }

    // MARK: - EsViritu

    func testEsViritu_menuClick_callsOrchestratorWithExpectedContext() throws {
        let table = ViralDetectionTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        // Attach a parent host so view.window is non-nil.
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.contentView = NSView(frame: .zero)
        host.contentView?.addSubview(table)

        // Wire the callback to fire the orchestrator — reuses the same
        // Context-construction pattern the real VC uses.
        var wasCalled = 0
        table.onExtractReadsRequested = {
            wasCalled += 1
            let ctx = TaxonomyReadExtractionAction.Context(
                tool: .esviritu,
                resultPath: URL(fileURLWithPath: "/tmp/unit-test.sqlite"),
                selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_TEST"], taxIds: [])],
                suggestedName: "test-extract"
            )
            TaxonomyReadExtractionAction.shared.present(context: ctx, hostWindow: host)
        }

        table.simulateContextMenuExtractReads()

        XCTAssertEqual(wasCalled, 1)
        XCTAssertEqual(TaxonomyReadExtractionAction.shared.testingCapture.presentCount, 1)
        let captured = TaxonomyReadExtractionAction.shared.testingCapture.lastContext
        XCTAssertEqual(captured?.tool, .esviritu)
        XCTAssertEqual(captured?.selections.first?.accessions, ["NC_TEST"])
        XCTAssertEqual(captured?.selections.first?.sampleId, "S1")
        XCTAssertEqual(captured?.suggestedName, "test-extract")
    }

    // MARK: - Kraken2

    func testKraken2_menuClick_callsOrchestratorWithExpectedContext() throws {
        let table = TaxonomyTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.contentView = NSView(frame: .zero)
        host.contentView?.addSubview(table)

        var wasCalled = 0
        table.onExtractReadsRequested = {
            wasCalled += 1
            let ctx = TaxonomyReadExtractionAction.Context(
                tool: .kraken2,
                resultPath: URL(fileURLWithPath: "/tmp/kr2-result"),
                selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [9606])],
                suggestedName: "kr2-test"
            )
            TaxonomyReadExtractionAction.shared.present(context: ctx, hostWindow: host)
        }

        table.simulateContextMenuExtractReads()

        XCTAssertEqual(wasCalled, 1)
        XCTAssertEqual(TaxonomyReadExtractionAction.shared.testingCapture.presentCount, 1)
        let captured = TaxonomyReadExtractionAction.shared.testingCapture.lastContext
        XCTAssertEqual(captured?.tool, .kraken2)
        XCTAssertEqual(captured?.selections.first?.taxIds, [9606])
        XCTAssertNil(captured?.selections.first?.sampleId)
        XCTAssertEqual(captured?.suggestedName, "kr2-test")
    }

    // MARK: - All tools — orchestrator accepts every classifier tool

    /// VC-agnostic wiring coverage for the 3 tools (TaxTriage, NAO-MGS, NVD)
    /// whose menus are built inside VCs that can't be instantiated in a unit
    /// test without a full AppKit window hierarchy. This is a weaker test
    /// than the live EsViritu/Kraken2 click paths above — it only proves the
    /// orchestrator's `present()` path accepts each tool — but it would still
    /// catch a regression that silently drops a `ClassifierTool` case from
    /// the dispatch switch.
    ///
    /// NOTE: The per-VC menu-click tests for TaxTriage/NAO-MGS/NVD are
    /// deliberately deferred to Phase 8 manual GUI verification because
    /// instantiating those VCs requires a live NSApplication context.
    func testAllTools_orchestratorAcceptsAllClassifierTools() {
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.contentView = NSView(frame: .zero)

        for tool in ClassifierTool.allCases {
            // Reset the capture so we observe exactly one call per iteration.
            TaxonomyReadExtractionAction.shared.testingCapture = .init()

            let selection: ClassifierRowSelector
            switch tool {
            case .esviritu, .taxtriage, .naomgs, .nvd:
                selection = ClassifierRowSelector(
                    sampleId: "S1",
                    accessions: ["NC_TEST"],
                    taxIds: []
                )
            case .kraken2:
                selection = ClassifierRowSelector(
                    sampleId: nil,
                    accessions: [],
                    taxIds: [9606]
                )
            }

            let ctx = TaxonomyReadExtractionAction.Context(
                tool: tool,
                resultPath: URL(fileURLWithPath: "/tmp/unit-test-\(tool.rawValue).sqlite"),
                selections: [selection],
                suggestedName: "test-\(tool.rawValue)"
            )
            TaxonomyReadExtractionAction.shared.present(context: ctx, hostWindow: host)

            XCTAssertEqual(
                TaxonomyReadExtractionAction.shared.testingCapture.presentCount,
                1,
                "Orchestrator must accept present() for \(tool.rawValue)"
            )
            let captured = TaxonomyReadExtractionAction.shared.testingCapture.lastContext
            XCTAssertEqual(
                captured?.tool,
                tool,
                "Captured context must preserve tool for \(tool.rawValue)"
            )
            XCTAssertEqual(
                captured?.suggestedName,
                "test-\(tool.rawValue)",
                "Captured context must preserve suggestedName for \(tool.rawValue)"
            )
        }
    }
}
