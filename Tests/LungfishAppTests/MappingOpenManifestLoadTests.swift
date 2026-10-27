// MappingOpenManifestLoadTests.swift - A mapping opens with one decode of each large file, off the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// A mapping onto a large reference carries a copy of that reference, whose
/// manifest the open decoded five times on the main thread: for the route,
/// the Provenance sources, the embedded viewer, the row refresh and the BAM
/// metadata context. The mapping result, which lists every reference sequence,
/// was decoded on the main thread too.
@MainActor
final class MappingOpenManifestLoadTests: XCTestCase {
    override func tearDown() async throws {
        BundleLoadProbe.install(nil)
        ReferenceBundleSequenceCache.installBuildObserver(nil)
        try await super.tearDown()
    }

    func testMappingOpenDecodesViewerManifestOnceOffMain() async throws {
        let root = try TestTempDirectory.make(prefix: "MappingOpenManifestLoad")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Mapped Once",
            chromosomes: [.init(name: "chr1", length: 100)],
            in: root
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", includeReadGroup: false, includeChromosomeStats: true,
            originalSourcePath: MappingRoutingFixture.ownBAMOriginalSourcePath
        )
        let resultURL = root.appendingPathComponent("mapping-result", isDirectory: true)
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        try MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: bundleURL,
            contigs: [MappingRoutingFixture.chr1RecordRow]
        ).save(to: resultURL)
        let digestBefore = try TreeDigest.of(root)
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayMappingAnalysisFromSidebar(at: resultURL)

        let opened = await waitUntil(timeout: .seconds(30)) {
            guard let viewport = split.viewerController.referenceBundleViewportController else { return false }
            return viewport.testContigTableView.displayedRows == [MappingRoutingFixture.chr1LabelledRecordRow]
                && viewport.mappingRowsRefreshTask == nil
                && viewport.testEmbeddedViewerController.currentReferenceBundle != nil
        }
        XCTAssertTrue(opened, "the mapping viewport never showed its record's row, labelled with its sample and track, and its viewer")
        XCTAssertEqual(decodes.count(.mappingResult), 1)
        XCTAssertEqual(decodes.count(.bundleManifest), 1)
        XCTAssertEqual(try TreeDigest.of(root), digestBefore, "opening a mapping wrote to its folder (UX 6)")
    }

    /// SWIFT-fai 4.7 item 1, for the mapping open. A mapping onto a large reference
    /// (SILVA, 905,628 sequences) made the embedded viewer build the viewer bundle's
    /// chromosome name index (250 ms) and the `.fai` of its sequences (seconds) on the
    /// main actor, at its first lookup and first fetch, and the UI locked. The open
    /// builds both beside the viewer manifest decode, off the main actor, and the
    /// embedded viewer shows that same bundle.
    func testMappingOpenBuildsSequenceIndexesOffMain() async throws {
        let root = try TestTempDirectory.make(prefix: "MappingOpenIndexes")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Mapped Indexes",
            chromosomes: [.init(name: "chr1", length: 100)],
            in: root
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", includeReadGroup: false, includeChromosomeStats: true,
            originalSourcePath: MappingRoutingFixture.ownBAMOriginalSourcePath
        )
        let resultURL = root.appendingPathComponent("mapping-result", isDirectory: true)
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        try MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: bundleURL,
            contigs: [MappingRoutingFixture.chr1RecordRow]
        ).save(to: resultURL)
        let builds = SequenceIndexBuildLog()
        builds.install()

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayMappingAnalysisFromSidebar(at: resultURL)

        let opened = await waitUntil(timeout: .seconds(30)) {
            guard let viewport = split.viewerController.referenceBundleViewportController else { return false }
            return viewport.testContigTableView.displayedRows == [MappingRoutingFixture.chr1LabelledRecordRow]
                && viewport.mappingRowsRefreshTask == nil
                && viewport.testEmbeddedViewerController.currentReferenceBundle != nil
        }
        XCTAssertTrue(opened, "the mapping viewport never showed its record's row, labelled with its sample and track, and its viewer")
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)
        // Selecting a contig looks it up in the shown bundle's name index and fetches its sequence.
        let recordRow = try XCTUnwrap(viewport.testContigTableView.displayedRows.first)
        viewport.testSelectContig(named: recordRow.contigName)
        let shown = try XCTUnwrap(viewport.testEmbeddedViewerController.currentReferenceBundle)
        XCTAssertEqual(shown.url.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(shown.sequenceCache.nameIndexBuildCount, 1)
        XCTAssertEqual(shown.sequenceCache.readerBuildCount, 1)
        XCTAssertEqual(builds.count(.nameIndex), 1, "a second bundle built its name index")
        XCTAssertEqual(builds.count(.reader), 1, "a second bundle built its sequence reader")
    }
}
