// FASTAListInspectorClearTests.swift - Showing a FASTA list or a README clears another dataset from the Inspector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp

/// W-10 (S2, BIO and UX): the walk showed a FASTA list, then a FASTQ dataset, then the same list, and the Inspector kept
/// the FASTQ block ("FASTQ Dataset, 170,398 reads", GC Content 39.8%) beside the list. The list's second showing took
/// the cached-document route, which skipped the Inspector clear the load route makes. A README preview kept a bundle's
/// block the same way (walk-log:267).
@MainActor
final class FASTAListInspectorClearTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "FASTAListInspectorClear")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    func testShowingACachedFASTAListClearsThePreviousDataset() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let url = try write("genome.fasta", ">first\nAACCGGTT\n>second\nATATAT\n")
        let document = LoadedDocument(url: url, type: .fasta)
        document.sequences = [
            try LungfishCore.Sequence(name: "first", alphabet: .dna, bases: "AACCGGTT"),
            try LungfishCore.Sequence(name: "second", alphabet: .dna, bases: "ATATAT"),
        ]
        DocumentManager.shared.registerDocument(document)
        defer { DocumentManager.shared.closeDocument(document) }
        let section = harness.split.inspectorController.viewModel.documentSectionViewModel
        section.update(manifest: nil, bundleURL: root.appendingPathComponent("SRR36291587.lungfishfastq"))

        harness.select(RoutingSafetyNetItems.scanned(url))

        let shown = await waitUntil(budget: .lookup) { harness.split.viewerController.fastaCollectionController != nil }
        XCTAssertTrue(shown, "the list never showed")
        XCTAssertNil(section.bundleURL, "the Inspector keeps another dataset beside the FASTA list")
    }

    func testShowingAREADMEPreviewClearsThePreviousDataset() throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let url = try write("README.md", "# Notes\n\nA text file with no numbers of its own.\n")
        let item = RoutingSafetyNetItems.scanned(url)
        XCTAssertTrue(item.type.usesQuickLook, "the README does not take the preview route")
        let section = harness.split.inspectorController.viewModel.documentSectionViewModel
        section.update(manifest: nil, bundleURL: root.appendingPathComponent("minimap2-walk94.lungfishref"))

        harness.select(item)

        XCTAssertNil(section.bundleURL, "the Inspector keeps another dataset beside the README preview")
    }

    /// SWIFT SF1 (a), fails at e344ae753: the sidebar click had pointed Provenance at the README row and the clear dropped
    /// that target. The route points it at the README again, as the load route does after its clear.
    func testReadmePreviewKeepsItsOwnProvenanceTarget() throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let url = try write("README.md", "# Notes\n\nA text file with no numbers of its own.\n")

        harness.select(RoutingSafetyNetItems.scanned(url))

        let target = harness.split.inspectorController.provenanceSectionViewModel.currentItem
        XCTAssertNotNil(target, "Provenance has no target beside the README preview")
        XCTAssertEqual(target?.url?.standardizedFileURL, url.standardizedFileURL, "Provenance does not point at the README")
    }

    /// SWIFT SF1 (b), fails at e344ae753: the clear set the Inspector's content identity to nil, so a late event for the
    /// dataset just left would pass its filter and refill the Inspector. Both cleared routes keep the row's identity.
    func testClearedRoutesKeepTheRowsIdentity() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let inspector = try XCTUnwrap(harness.split.inspectorController)
        let list = try write("genome.fasta", ">first\nAACCGGTT\n>second\nATATAT\n")
        let document = LoadedDocument(url: list, type: .fasta)
        document.sequences = [
            try LungfishCore.Sequence(name: "first", alphabet: .dna, bases: "AACCGGTT"),
            try LungfishCore.Sequence(name: "second", alphabet: .dna, bases: "ATATAT"),
        ]
        DocumentManager.shared.registerDocument(document)
        defer { DocumentManager.shared.closeDocument(document) }

        harness.select(RoutingSafetyNetItems.scanned(list))
        let shown = await waitUntil(budget: .lookup) { harness.split.viewerController.fastaCollectionController != nil }
        XCTAssertTrue(shown, "the list never showed")
        XCTAssertNotNil(harness.split.activeContentSelectionIdentity, "the window holds no identity for the list row")
        XCTAssertEqual(
            inspector.activeContentSelectionIdentity, harness.split.activeContentSelectionIdentity,
            "the cached FASTA list route drops the Inspector's identity")

        harness.select(RoutingSafetyNetItems.scanned(try write("README.md", "# Notes\n")))
        XCTAssertNotNil(harness.split.activeContentSelectionIdentity, "the window holds no identity for the README row")
        XCTAssertEqual(
            inspector.activeContentSelectionIdentity, harness.split.activeContentSelectionIdentity,
            "the README route drops the Inspector's identity")
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let folder = root.appendingPathComponent("\(UUID().uuidString).lungfish/Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
