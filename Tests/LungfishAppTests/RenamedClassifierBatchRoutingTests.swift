// RenamedClassifierBatchRoutingTests.swift - WFL-06 regression coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reported 2026-09-23 (best-practices audit, WFL-06): renaming a classifier
// batch folder to anything that does not start with the tool's own prefix
// (e.g. "kraken2-batch-...") made `displayBatchGroup` fall through to
// "Unrecognized batch prefix", even though `analysis-metadata.json` still
// identifies the tool. This drives `displayBatchGroup` (and the sidebar
// selection path that calls it) against renamed batch directories and
// asserts the correct classifier viewer is installed.

import XCTest
import AppKit
import SQLite3
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

@MainActor
final class RenamedClassifierBatchRoutingTests: XCTestCase {

    private func makeController() -> (MainSplitViewController, NSWindow) {
        let controller = MainSplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenamedClassifierBatchRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeMetadata(tool: String, to directory: URL) throws {
        let metadata = AnalysesFolder.AnalysisMetadata(tool: tool, isBatch: true, created: Date())
        try AnalysesFolder.writeAnalysisMetadata(metadata, to: directory)
    }

    // MARK: - EsViritu (renamed, with metadata)

    private func makeEsVirituBatch(named dirName: String, in root: URL, withMetadata: Bool) throws -> URL {
        let batch = root.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try EsVirituDatabase.create(
            at: batch.appendingPathComponent("esviritu.sqlite"),
            rows: [
                EsVirituDetectionRow(
                    sample: "sample-a", virusName: "Example virus", description: nil,
                    contigLength: 1_000, segment: nil, accession: "NC_000001.1",
                    assembly: "ASM_1", assemblyLength: 1_000, kingdom: nil, phylum: nil,
                    tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                    subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
                    coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                    pi: nil, filteredReadsInSample: 4, bamPath: nil, bamIndexPath: nil
                ),
            ],
            metadata: ["tool": "esviritu"]
        )
        if withMetadata {
            try writeMetadata(tool: "esviritu", to: batch)
        }
        return batch
    }

    func testRenamedEsVirituBatchStillRoutesToEsViritu() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A user-chosen name that does NOT start with "esviritu".
        let batch = try makeEsVirituBatch(named: "My Sequencing Run 2026-09-01", in: root, withMetadata: true)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.esVirituViewController,
                         "Renamed EsViritu batch must still route to the EsViritu viewer")
        XCTAssertEqual(controller.inspectorController.viewModel.contentMode, .metagenomics)
    }

    func testUnrenamedEsVirituBatchStillRoutes() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try makeEsVirituBatch(named: "esviritu-batch-2026-09-01T00-00-00", in: root, withMetadata: true)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.esVirituViewController)
    }

    func testLegacyEsVirituBatchWithNoMetadataRoutesByPrefix() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No analysis-metadata.json (legacy folder), correct prefix retained.
        let batch = try makeEsVirituBatch(named: "esviritu-batch-2026-01-01T00-00-00", in: root, withMetadata: false)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.esVirituViewController,
                         "Legacy folder with correct prefix and no metadata sidecar must still route by prefix")
    }

    // MARK: - Kraken2 (renamed, with metadata)

    private func makeKraken2Row(sample: String, taxonName: String, taxId: Int) -> Kraken2ClassificationRow {
        Kraken2ClassificationRow(
            sample: sample, taxonName: taxonName, taxId: taxId, rank: "S", rankDisplayName: "Species",
            readsDirect: 50, readsClade: 100, percentage: 1.0, parentTaxId: nil, depth: 0, fractionDirect: 0.0
        )
    }

    func testRenamedKraken2BatchStillRoutesToTaxonomy() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = root.appendingPathComponent("Project Alpha Results", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        _ = try Kraken2Database.create(
            at: batch.appendingPathComponent("kraken2.sqlite"),
            rows: [makeKraken2Row(sample: "sample-a", taxonName: "Escherichia coli", taxId: 562)],
            metadata: ["tool": "kraken2"]
        )
        try writeMetadata(tool: "kraken2", to: batch)

        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.taxonomyViewController,
                         "Renamed Kraken2 batch must still route to the taxonomy viewer")
    }

    // MARK: - TaxTriage (renamed, with metadata)

    private func makeTaxTriageRow(sample: String, organism: String) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: nil, status: nil,
            tassScore: 0.9, readsAligned: 100, uniqueReads: nil,
            pctReads: nil, pctAlignedReads: nil, coverageBreadth: nil,
            meanCoverage: nil, meanDepth: nil, confidence: nil,
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil,
            disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil,
            microbialCategory: nil, highConsequence: nil, isSpecies: nil,
            pathogenicSubstrains: nil, sampleType: nil,
            bamPath: nil, bamIndexPath: nil,
            primaryAccession: nil, accessionLength: nil
        )
    }

    func testRenamedTaxTriageBatchStillRoutesToTaxTriage() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = root.appendingPathComponent("Clinical Batch 7", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        _ = try TaxTriageDatabase.create(
            at: batch.appendingPathComponent("taxtriage.sqlite"),
            rows: [makeTaxTriageRow(sample: "sample-a", organism: "Example organism")],
            metadata: ["tool": "taxtriage"]
        )
        try writeMetadata(tool: "taxtriage", to: batch)

        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        XCTAssertNotNil(controller.viewerController.taxTriageViewController,
                         "Renamed TaxTriage batch must still route to the TaxTriage viewer")
    }

    // MARK: - Sidebar selection path (mirrors user interaction)

    func testSidebarSelectionOfRenamedBatchRoutesCorrectly() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try makeEsVirituBatch(named: "Weekly Surveillance", in: root, withMetadata: true)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let item = SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch)
        controller.displayContent(for: item)

        XCTAssertNotNil(controller.viewerController.esVirituViewController)
    }
}
