// AssemblySavedBlastRestoreTests.swift - A saved BLAST search comes back when its contigs are selected again
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN2, item 2. An assembly's plan saves under the result folder, so the records here sit there, as the
// plan puts them. `heldIn` names that folder.

import AppKit
import LungfishCore
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishAssemblyUI
@testable import LungfishWorkflow

@MainActor
final class AssemblySavedBlastRestoreTests: XCTestCase {
    private func makeViewer(result name: String, in project: SavedBlastSearchProject) async throws -> AssemblyResultViewController {
        _ = NSApplication.shared
        let folder = try project.result(name)
        let viewer = AssemblyResultViewController()
        _ = viewer.view
        try await viewer.configureForTesting(result: makeAssemblyResult(writeFASTAIndex: true, in: folder))
        return viewer
    }

    private func settle(_ viewer: AssemblyResultViewController) async {
        await viewer.savedBlastRestorer.restoreTask?.value
    }

    func testAssemblyContigSelectionRestoresOnlyItsOwnResultsSavedSearch() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let viewer = try await makeViewer(result: "A", in: project)
        _ = try project.result("B")
        let recordA = try project.saveRecord(rid: "RID-A", sourceResult: "A", sample: nil, taxId: nil, contig: "contig_7", heldIn: "A")
        try project.saveRecord(rid: "RID-B", sourceResult: "B", sample: nil, taxId: nil, contig: "contig_7", age: -60, heldIn: "B")
        try project.saveRecord(rid: "RID-B-KEPT-IN-A", sourceResult: "B", sample: nil, taxId: nil, contig: "contig_7", age: -60, heldIn: "A")

        try await viewer.testSelectContigs(named: ["contig_7"])
        await settle(viewer)

        let pane = try XCTUnwrap(viewer.testBlastDrawerContainer?.blastResultsTab, "the selection's search opens the pane")
        XCTAssertEqual(pane.currentResult?.rid, "RID-A")
        XCTAssertEqual(pane.currentRecordURL?.standardizedFileURL.path, recordA.standardizedFileURL.path, "the export reads this file")
        guard case .contigBlast = pane.presentationStyle else { return XCTFail("the pane keeps its contig style") }
        XCTAssertTrue(viewer.isBlastDrawerOpen, "no control opens this viewer's pane, so a restore opens it")
    }

    func testAnotherAssemblySelectionInTheSameResultDoesNotShowIt() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let viewer = try await makeViewer(result: "A", in: project)
        try project.saveRecord(rid: "RID-A", sourceResult: "A", sample: nil, taxId: nil, contig: "contig_7", heldIn: "A")

        try await viewer.testSelectContigs(named: ["contig_9"])
        await settle(viewer)
        XCTAssertNil(viewer.testBlastDrawerContainer, "a selection with no saved search leaves the pane as it is")

        viewer.selectedContigNames = ["contig_7", "contig_9"]
        await settle(viewer)
        XCTAssertNil(viewer.testBlastDrawerContainer, "a list with one more contig is another search")
    }

    func testAnAssemblyContigListSearchComesBackInAnotherOrder() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let viewer = try await makeViewer(result: "A", in: project)
        try project.saveRecord(rid: "RID-A", sourceResult: "A", sample: nil, taxId: nil, contig: "contig_9,contig_7", heldIn: "A")

        try await viewer.testSelectContigs(named: ["contig_7", "contig_9"])
        await settle(viewer)

        XCTAssertEqual(viewer.testBlastDrawerContainer?.blastResultsTab.currentResult?.rid, "RID-A")
    }

    func testAnAssemblyScanAfterTheSelectionMovedIsDropped() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let viewer = try await makeViewer(result: "A", in: project)
        try project.saveRecord(rid: "RID-A", sourceResult: "A", sample: nil, taxId: nil, contig: "contig_7", heldIn: "A")

        viewer.selectedContigNames = ["contig_7"]
        let scan = try XCTUnwrap(viewer.savedBlastRestorer.restoreTask)
        viewer.selectedContigNames = ["contig_9"]
        await scan.value
        await settle(viewer)

        XCTAssertNil(viewer.testBlastDrawerContainer)
    }

    func testAnAssemblyRunIsNotReplacedAndARestoreFollowsItsEnd() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let viewer = try await makeViewer(result: "A", in: project)
        try project.saveRecord(rid: "RID-A", sourceResult: "A", sample: nil, taxId: nil, contig: "contig_7", heldIn: "A")

        viewer.selectedContigNames = ["contig_7"]
        let scan = try XCTUnwrap(viewer.savedBlastRestorer.restoreTask)
        viewer.showBlastLoading(phase: .submitting, requestId: nil)
        await scan.value
        let pane = try XCTUnwrap(viewer.testBlastDrawerContainer?.blastResultsTab)
        XCTAssertNil(pane.currentResult, "a scan that returns after a run began is dropped")

        viewer.selectedContigNames = []
        viewer.selectedContigNames = ["contig_7"]
        XCTAssertNil(viewer.savedBlastRestorer.restoreTask, "a run in flight starts no scan")

        viewer.showBlastFailure("The search stopped.")
        viewer.selectedContigNames = []
        viewer.selectedContigNames = ["contig_7"]
        await settle(viewer)
        XCTAssertEqual(pane.currentResult?.rid, "RID-A")
    }

    func testARestoredAssemblySearchStaysWhenTheNextSelectionHasNone() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let viewer = try await makeViewer(result: "A", in: project)
        try project.saveRecord(rid: "RID-A", sourceResult: "A", sample: nil, taxId: nil, contig: "contig_7", heldIn: "A")

        viewer.selectedContigNames = ["contig_7"]
        await settle(viewer)
        viewer.selectedContigNames = ["contig_9"]
        await settle(viewer)

        XCTAssertEqual(viewer.testBlastDrawerContainer?.blastResultsTab.currentResult?.rid, "RID-A")
    }
}
