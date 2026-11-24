// ReadTimeWriteTests+Mapping.swift - A change to the viewport's list and the MHC reference's Mode writes nothing into
// the project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view-state phase, lane VS-MAP (UX 6). The list and mode of the reference and mapping viewport (k08, k22) ride in
// the viewer's record, and the MHC reference's Mode (k12) in the host's record, both in the view memory store on this
// Mac. A person's pick and Focus in the list, or a Mode change, write nothing into the project, whether the project is
// writable, held by another writer or holds read-only bundles.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

extension ReadTimeWriteTests {

    // MARK: - The viewport's list (k08, k22)

    func testAListChangeInAReferenceAndAMappingResultWritesNothingIntoAWritableProject() async throws {
        let fixture = try makeReferenceProject()
        try await assertListChangesWriteNothing(into: fixture, "a writable project")
    }

    func testAListChangeWritesNothingIntoAProjectThatAnotherWriterHolds() async throws {
        let fixture = try makeReferenceProject()
        let other = ProjectLockRecord.current(
            projectURL: fixture.project, mode: "write", toolName: "invented other writer", appVersion: "test")
        try JSONEncoder().encode(other).write(to: ProjectLockManager.lockURL(for: fixture.project), options: .atomic)
        XCTAssertTrue(ProjectOpenWarningState.evaluate(projectURL: fixture.project).isReadOnlyRecommended)
        try await assertListChangesWriteNothing(into: fixture, "a project another writer holds")
    }

    func testAListChangeWritesNothingIntoReadOnlyBundles() async throws {
        let fixture = try makeReferenceProject()
        for bundle in [fixture.reference, fixture.viewerBundle] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
            addTeardownBlock {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path)
            }
        }
        try await assertListChangesWriteNothing(into: fixture, "a project whose bundles are 0o555")
    }

    // MARK: - The MHC reference's Mode (k12)

    /// The Mode set to Haplotype, the host's capture, a switch away and the store's flush write nothing into the
    /// project, and the Mode sits in the store.
    func testAnMHCReferenceModeChangeWritesNothingIntoTheProject() async throws {
        let project = try SafetyNetFiles.makeDirectory(scratch.appendingPathComponent("MHC.lungfish", isDirectory: true))
        let driver = MHCReferenceViewStateDriver()
        let mhc = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: driver.kind), in: project)
        try driver.prepare(mhc) // the embedded reference the Mode picker needs, written before the digest
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let storeRoot = scratch.appendingPathComponent("view-memory-mhc", isDirectory: true)
        // The digest comes before the store reads the project, so a write by that read shows too.
        let before = try ProjectDigest(of: project)
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)

        let harness = try ViewSwitchWindowHarness()
        harness.keepViews(in: store)
        harness.select(mhc.item)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "k12: the MHC reference did not show")
        try await driver.change(in: harness) // Mode to Haplotype
        harness.split.viewerController.surfaceHost.captureActive()
        harness.select(other.item)
        let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !driver.isShown(in: harness) }
        XCTAssertTrue(left, "k12: the MHC reference stayed after the switch")
        store.flushSynchronously()
        harness.close()

        XCTAssertEqual(
            try ProjectDigest(of: project).differences(from: before).map(\.summary), [],
            "k12: a Mode change wrote into the project")
        let kept = try FileManager.default.subpathsOfDirectory(atPath: storeRoot.path)
        XCTAssertTrue(kept.contains { $0.hasSuffix(".json") }, "k12: the Mode sits in the store: \(kept)")
    }

    // MARK: - Helpers

    /// Opens the reference and the mapping result in turn as VS-REF's helper does, picks chr2 and clicks Focus as a
    /// person does, and leaves with no viewer change, so only the leave keeps the list. Then requires each item's list
    /// and mode in the store and the project's digest unchanged.
    private func assertListChangesWriteNothing(into fixture: ReferenceProject, _ label: String) async throws {
        let store = makeViewMemoryStore()
        store.loadProject(at: fixture.project)
        let before = try ProjectDigest(of: fixture.project)
        let contigs = [("chr1", 5_000, 90), ("chr2", 3_000, 40)].map { name, length, reads in
            MappingContigSummary(
                contigName: name, contigLength: length, mappedReads: reads, mappedReadPercent: Double(reads),
                meanDepth: 2, coverageBreadth: 0.5, medianMAPQ: 60, meanIdentity: 0.99)
        }
        for item in [fixture.reference, fixture.resultDirectory] {
            let isReference = item == fixture.reference
            let viewport = ReferenceBundleViewportController()
            _ = viewport.view
            let viewer = viewport.testEmbeddedViewerController
            viewer.viewMemoryStore = store
            if isReference {
                try viewport.configureForTesting(
                    input: .directBundle(bundleURL: item, manifest: try BundleManifest.load(from: item)))
            } else {
                viewport.configureForTesting(
                    result: MappingRoutingFixture.makeMappingResult(
                        resultDirectory: item, viewerBundleURL: fixture.viewerBundle, contigs: contigs),
                    resultDirectoryURL: item)
            }
            let shown = await waitUntil(budget: .lookup) { viewer.currentBundleURL != nil && viewer.viewMemoryIsSettled }
            XCTAssertTrue(shown, "\(item.lastPathComponent) was not shown in \(label).")
            let names = isReference
                ? viewport.sequenceTableView.displayedRows.map(\.summary.name)
                : viewport.contigTableView.displayedRows.map(\.contigName)
            let table: NSTableView = isReference ? viewport.sequenceTableView.tableView : viewport.contigTableView.tableView
            let row = try XCTUnwrap(names.firstIndex(of: "chr2"), "\(item.lastPathComponent) lists no chr2 in \(label).")
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) // a person's pick
            viewport.focusButton.performClick(nil)
            viewer.clearBundleDisplay()
            let kept = keptReferenceView(of: item, in: store)?.viewport
            XCTAssertEqual(kept?.focused, true, "\(item.lastPathComponent) kept no Focus in \(label).")
            XCTAssertEqual(kept?.choices.sequences, ["chr2"], "\(item.lastPathComponent) kept no pick in \(label).")
        }
        store.flushSynchronously()
        XCTAssertEqual(
            try ProjectDigest(of: fixture.project).differences(from: before).map(\.summary), [],
            "A person's list change wrote into \(label).")
    }
}
