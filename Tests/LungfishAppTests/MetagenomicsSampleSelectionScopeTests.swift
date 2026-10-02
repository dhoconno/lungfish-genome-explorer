// MetagenomicsSampleSelectionScopeTests.swift - Sample selection observers filter by window scope (R9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishEsVirituUI
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishNaoMgsUI
@testable import LungfishNvdUI
import LungfishTestSupport
@testable import LungfishTaxTriageUI

/// `metagenomicsSampleSelectionChanged` is a window event. Each test puts the
/// same kind of classifier viewport in two project windows and stages a new
/// selection in both sample pickers. A post must reload only the viewport in
/// the window whose scope it carries, and a post with no scope must reload
/// neither. The five viewports are NVD, NAO-MGS, TaxTriage, EsViritu and the
/// Kraken2 taxonomy viewport.
///
/// The tests live in LungfishAppTests because it already links all five
/// viewports and the project-window stand-in from LungfishKitTestSupport.
@MainActor
final class MetagenomicsSampleSelectionScopeTests: XCTestCase {
    private var first: ScopeOwningWindowController!
    private var second: ScopeOwningWindowController!

    override func setUp() async throws {
        try await super.setUp()
        first = ScopeOwningWindowController()
        second = ScopeOwningWindowController()
    }

    override func tearDown() async throws {
        first.close()
        second.close()
        first = nil
        second = nil
        try await super.tearDown()
    }

    // MARK: - Two-window driver

    /// One classifier viewport that shows a result inside one window.
    private struct Viewport {
        /// Puts a selection in the sample picker that the viewport has not applied yet.
        let stageSelection: () -> Void
        /// Whether the viewport has applied the staged selection.
        let isApplied: () -> Bool
    }

    private func post(carrying scope: WindowStateScope?) {
        NotificationCenter.default.post(
            name: .metagenomicsSampleSelectionChanged,
            object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: scope)
        )
    }

    /// Builds one viewport in each window, stages the same selection in both
    /// and posts three times. Nothing yields between the staging and the last
    /// post, so a viewport that also watches its own picker (NAO-MGS does,
    /// one main-queue hop after the change) has not applied the selection by
    /// itself yet and every assertion reads the effect of the post alone.
    private func assertAPostReachesOnlyTheViewportInItsWindow(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ makeViewport: (ScopeOwningWindowController) throws -> Viewport
    ) rethrows {
        let inFirst = try makeViewport(first)
        let inSecond = try makeViewport(second)
        inFirst.stageSelection()
        inSecond.stageSelection()
        XCTAssertFalse(inFirst.isApplied(), "Staging alone applied the selection in the first window", file: file, line: line)
        XCTAssertFalse(inSecond.isApplied(), "Staging alone applied the selection in the second window", file: file, line: line)

        post(carrying: nil)
        XCTAssertFalse(inFirst.isApplied(), "A post with no scope reloaded the first window's viewport", file: file, line: line)
        XCTAssertFalse(inSecond.isApplied(), "A post with no scope reloaded the second window's viewport", file: file, line: line)

        post(carrying: second.windowStateScope)
        XCTAssertFalse(inFirst.isApplied(), "A post carrying the second window's scope reloaded the first window's viewport", file: file, line: line)
        XCTAssertTrue(inSecond.isApplied(), "A post carrying the second window's scope did not reload the second window's viewport", file: file, line: line)

        post(carrying: first.windowStateScope)
        XCTAssertTrue(inFirst.isApplied(), "A post carrying the first window's scope did not reload the first window's viewport", file: file, line: line)
    }

    private func makeResultDirectory() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "MetagenomicsSampleSelectionScope")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return root
    }

    // MARK: - The five observers

    func testNvdViewportReloadsOnlyForTheWindowWhoseScopeThePostCarries() {
        assertAPostReachesOnlyTheViewportInItsWindow { window in
            let viewport = NvdResultViewController()
            window.host(viewport.view)
            XCTAssertEqual(ScopedEventFilter.hostingWindowScope(of: viewport.view), window.windowStateScope)
            viewport.configureWithCachedRows(
                [Self.nvdRow(sample: "sample-a"), Self.nvdRow(sample: "sample-b")],
                manifest: Self.nvdManifest,
                bundleURL: URL(fileURLWithPath: "/tmp/nvd-sample-selection-scope", isDirectory: true)
            )
            viewport.samplePickerState = ClassifierSamplePickerState(allSamples: ["sample-a", "sample-b"])
            let reloadsBefore = viewport.testOutlineReloadCount
            return Viewport(
                stageSelection: { viewport.samplePickerState.selectedSamples = ["sample-a"] },
                isApplied: { viewport.testOutlineReloadCount > reloadsBefore }
            )
        }
    }

    func testNaoMgsViewportReloadsOnlyForTheWindowWhoseScopeThePostCarries() {
        assertAPostReachesOnlyTheViewportInItsWindow { window in
            let viewport = NaoMgsResultViewController()
            window.host(viewport.view)
            XCTAssertEqual(ScopedEventFilter.hostingWindowScope(of: viewport.view), window.windowStateScope)
            viewport.configureWithCachedRows(
                [Self.naoMgsRow(sample: "sample-a"), Self.naoMgsRow(sample: "sample-b")],
                manifest: Self.naoMgsManifest
            )
            XCTAssertEqual(viewport.testTaxonomyTableView.numberOfRows, 2)
            return Viewport(
                stageSelection: { viewport.samplePickerState.selectedSamples = ["sample-a"] },
                isApplied: { viewport.testTaxonomyTableView.numberOfRows == 1 }
            )
        }
    }

    func testTaxTriageViewportReloadsOnlyForTheWindowWhoseScopeThePostCarries() throws {
        try assertAPostReachesOnlyTheViewportInItsWindow { window in
            let root = try makeResultDirectory()
            let database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: [
                    Self.taxTriageRow(sample: "sample-1", organism: "Alpha virus", taxId: 1),
                    Self.taxTriageRow(sample: "sample-2", organism: "Beta virus", taxId: 2),
                ],
                metadata: ["tool": "taxtriage"]
            )
            let viewport = TaxTriageResultViewController()
            window.host(viewport.view)
            XCTAssertEqual(ScopedEventFilter.hostingWindowScope(of: viewport.view), window.windowStateScope)
            viewport.configureFromDatabase(database, resultURL: root)
            // Two samples are ticked, so the segmented sample filter selects no segment.
            XCTAssertEqual(viewport.testSampleFilterControl.selectedSegment, -1)
            return Viewport(
                stageSelection: { viewport.samplePickerState.selectedSamples = ["sample-2"] },
                // Applying a one-sample selection selects that sample's segment (All Samples is segment 0).
                isApplied: { viewport.testSampleFilterControl.selectedSegment == 2 }
            )
        }
    }

    func testEsVirituViewportReloadsOnlyForTheWindowWhoseScopeThePostCarries() throws {
        try assertAPostReachesOnlyTheViewportInItsWindow { window in
            let root = try makeResultDirectory()
            let database = try EsVirituDatabase.create(
                at: root.appendingPathComponent("esviritu.sqlite"),
                rows: [
                    Self.esVirituRow(sample: "sample-a", virusName: "Example virus", accession: "NC_000001.1", assembly: "ASM_1"),
                    Self.esVirituRow(sample: "sample-b", virusName: "Other virus", accession: "NC_000002.1", assembly: "ASM_2"),
                ],
                metadata: [:]
            )
            let viewport = EsVirituResultViewController()
            window.host(viewport.view)
            XCTAssertEqual(ScopedEventFilter.hostingWindowScope(of: viewport.view), window.windowStateScope)
            viewport.configureFromDatabase(database, resultURL: root)
            // Two samples are ticked, so the result is the merged "batch" result.
            XCTAssertEqual(viewport.testResult?.sampleId, "batch")
            return Viewport(
                stageSelection: { viewport.samplePickerState.selectedSamples = ["sample-b"] },
                isApplied: { viewport.testResult?.sampleId == "sample-b" }
            )
        }
    }

    func testTaxonomyViewportReloadsOnlyForTheWindowWhoseScopeThePostCarries() throws {
        try assertAPostReachesOnlyTheViewportInItsWindow { window in
            let root = try makeResultDirectory()
            let database = try Kraken2Database.create(
                at: root.appendingPathComponent("kraken2.sqlite"),
                rows: [
                    Self.krakenRoot(sample: "sample-a"),
                    Self.krakenRoot(sample: "sample-b"),
                ],
                metadata: [:]
            )
            let viewport = TaxonomyViewController()
            window.host(viewport.view)
            XCTAssertEqual(ScopedEventFilter.hostingWindowScope(of: viewport.view), window.windowStateScope)
            viewport.configureFromDatabase(database)
            // Two samples are ticked, so the table shows the merged tree.
            XCTAssertNil(viewport.testTableView.currentSampleID)
            return Viewport(
                stageSelection: { viewport.samplePickerState.selectedSamples = ["sample-b"] },
                isApplied: { viewport.testTableView.currentSampleID == "sample-b" }
            )
        }
    }

    // MARK: - Fixtures

    private static let nvdManifest = NvdManifest(
        experiment: "scope",
        sampleCount: 2,
        contigCount: 2,
        hitCount: 2,
        blastDbVersion: nil,
        snakemakeRunId: nil,
        sourceDirectoryPath: "/tmp",
        samples: [],
        cachedTopContigs: nil
    )

    private static func nvdRow(sample: String) -> NvdContigRow {
        NvdContigRow(
            sampleId: sample,
            qseqid: "NODE_1",
            qlen: 1000,
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            sseqid: "NC_000001.1",
            stitle: "Example virus reference",
            pident: 99.0,
            evalue: 0,
            bitscore: 1000,
            mappedReads: 50,
            readsPerBillion: 1_000_000
        )
    }

    private static let naoMgsManifest = NaoMgsManifest(
        sampleName: "sample-a",
        sourceFilePath: "/tmp/naomgs.tsv",
        hitCount: 20,
        taxonCount: 1,
        topTaxon: "Example virus",
        topTaxonId: 1234
    )

    private static func naoMgsRow(sample: String) -> NaoMgsTaxonSummaryRow {
        NaoMgsTaxonSummaryRow(
            sample: sample,
            taxId: 1234,
            name: "Example virus",
            hitCount: 10,
            uniqueReadCount: 8,
            avgIdentity: 99.5,
            avgBitScore: 200,
            avgEditDistance: 1,
            pcrDuplicateCount: 0,
            accessionCount: 1,
            topAccessions: ["NC_000001.1"],
            bamPath: nil,
            bamIndexPath: nil
        )
    }

    private static func taxTriageRow(sample: String, organism: String, taxId: Int) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: taxId, status: nil, tassScore: 0.9,
            readsAligned: 2, uniqueReads: 2, pctReads: nil, pctAlignedReads: nil,
            coverageBreadth: nil, meanCoverage: nil, meanDepth: nil, confidence: "High",
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
            mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil,
            isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: nil, bamIndexPath: nil, primaryAccession: nil, accessionLength: nil
        )
    }

    private static func esVirituRow(
        sample: String,
        virusName: String,
        accession: String,
        assembly: String
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample, virusName: virusName, description: nil,
            contigLength: 1_000, segment: nil, accession: accession,
            assembly: assembly, assemblyLength: 1_000, kingdom: nil, phylum: nil,
            tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
            subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
            coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
            pi: nil, filteredReadsInSample: 4, bamPath: nil, bamIndexPath: nil
        )
    }

    private static func krakenRoot(sample: String) -> Kraken2ClassificationRow {
        Kraken2ClassificationRow(
            sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
            readsDirect: 0, readsClade: 10, percentage: 100, parentTaxId: nil, depth: 0, fractionDirect: 0
        )
    }
}
