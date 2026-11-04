// TaxonomyBlastRowPaneTests.swift - The Kraken2 BLAST pane shows the selected row's search, or nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ROWPANE (KRAKEN2-RESTORE-TAXID-ONLY, BLAST-STALE-PANE-TAXON-ONLY). A merged display lists one taxon
// under each sample, so a row is a sample and a taxon. The pane compared the taxon alone, so one sample's verdict stayed
// under another sample's row of the same taxon, and a row with no saved search left the pane as it was.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
import LungfishTestSupport
@testable import LungfishTaxonomyUI

@MainActor
final class TaxonomyBlastRowPaneTests: XCTestCase {
    private var scratch: URL!
    private var host: NSWindow?

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "kraken2-row-pane")
    }

    override func tearDownWithError() throws {
        host?.contentView = nil
        host = nil
        TestTempDirectory.cleanup(scratch)
    }

    /// BIO's real case. Two samples hold one taxon (Viruses, 10239), and each sample's folder holds its own saved
    /// search of it. Selecting the second sample's row must show the second sample's search. At the base the taxon
    /// matched, so the first sample's verdict stayed under the second sample's row.
    func testSelectingOneTaxonInAnotherSampleShowsThatSamplesOwnSearch() async throws {
        let display = try makeDisplay(savedIn: ["S1", "S2"])
        let vc = display.controller

        vc.testSunburstView.onNodeSelected?(display.virusesInS1)
        await vc.scheduleSavedBlastVerificationRestore(for: display.virusesInS1)?.value
        XCTAssertEqual(vc.lastBlastResult?.rid, "RID-S1", "sample S1's row shows S1's search")

        vc.testSunburstView.onNodeSelected?(display.virusesInS2)
        await vc.scheduleSavedBlastVerificationRestore(for: display.virusesInS2)?.value

        XCTAssertEqual(vc.lastBlastResult?.rid, "RID-S2", "sample S2's row shows S2's own search")
        XCTAssertEqual(vc.testBlastResultsTab?.currentResult?.rid, "RID-S2", "the pane shows what the view holds")
        XCTAssertEqual(vc.lastBlastRecordURL?.pathComponents.contains("S2"), true, "the record is the one in S2's folder")
        XCTAssertEqual(vc.lastBlastNode === display.virusesInS2, true, "Re-run BLAST targets the S2 row")
        let summary = try XCTUnwrap(vc.testBlastResultsTab?.summaryLabel.stringValue)
        XCTAssertTrue(summary.contains("S2"), "the summary names the sample whose search it shows: \(summary)")
        XCTAssertFalse(summary.contains("S1"), summary)
    }

    /// A run finishes after the person moved to the same taxon in another sample (BIO, review blocker 1). The restore
    /// for the new row never ran, since a run was in flight, so the verdict lands under S2's row. It is about S1's reads
    /// and the summary says so.
    func testARunsVerdictNamesItsSampleWhenAnotherSamplesRowIsSelected() async throws {
        let display = try makeDisplay(savedIn: [])
        let vc = display.controller

        let runID = vc.beginBlastVerification(for: display.virusesInS1)
        vc.testSunburstView.onNodeSelected?(display.virusesInS2)
        vc.showBlastResults(Self.verification(rid: "RID-RUN"), recordURL: nil, runID: runID)

        let summary = try XCTUnwrap(vc.testBlastResultsTab?.summaryLabel.stringValue)
        XCTAssertTrue(summary.contains("S1"), "the summary names the sample the run ran on: \(summary)")
        XCTAssertFalse(summary.contains("S2"), summary)
    }

    /// A row with no saved search after a row with one. The pane shows the selected row's search or nothing, so the
    /// earlier row's verdict does not stay under it, whether the row is the same taxon in another sample or another
    /// taxon of the same sample.
    func testSelectingOneTaxonInASampleWithNoSearchEmptiesThePane() async throws {
        let display = try makeDisplay(savedIn: ["S1"])
        let vc = display.controller

        vc.testSunburstView.onNodeSelected?(display.virusesInS1)
        await vc.scheduleSavedBlastVerificationRestore(for: display.virusesInS1)?.value
        XCTAssertEqual(vc.lastBlastResult?.rid, "RID-S1")

        vc.testSunburstView.onNodeSelected?(display.virusesInS2)
        await vc.scheduleSavedBlastVerificationRestore(for: display.virusesInS2)?.value

        XCTAssertNil(vc.lastBlastResult, "S2 has no saved search, so S1's verdict does not stay under S2's row")
        XCTAssertNil(vc.lastBlastRecordURL)
        XCTAssertNil(vc.testBlastResultsTab?.currentResult, "the pane shows its empty state")

        vc.testSunburstView.onNodeSelected?(display.virusesInS1)
        await vc.scheduleSavedBlastVerificationRestore(for: display.virusesInS1)?.value
        XCTAssertEqual(vc.lastBlastResult?.rid, "RID-S1", "S1's row gets its search back")

        vc.testSunburstView.onNodeSelected?(display.betacoronavirusInS1)
        await vc.scheduleSavedBlastVerificationRestore(for: display.betacoronavirusInS1)?.value
        XCTAssertNil(vc.lastBlastResult, "another taxon of S1 has no saved search, so Viruses' verdict does not stay")
        XCTAssertNil(vc.testBlastResultsTab?.currentResult)
    }

    // MARK: - Fixtures

    private struct Display {
        let controller: TaxonomyViewController
        let virusesInS1: TaxonNode
        let virusesInS2: TaxonNode
        let betacoronavirusInS1: TaxonNode
    }

    /// A merged two-sample display with Viruses under both samples, a resolver that maps a row to its sample's folder
    /// and a BLAST tab to read. Each sample in `savedIn` holds a saved search of Viruses named `RID-<sample>`.
    private func makeDisplay(savedIn samples: [String]) throws -> Display {
        let database = try makeMultiSampleDatabase()
        let vc = TaxonomyViewController()
        isolateLayouts(vc)
        _ = vc.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(vc.view)
        host = window
        vc.batchURL = scratch
        vc.configureFromDatabase(database)
        vc.testTableView.expandAll()
        vc.testTableView.outlineView.layoutSubtreeIfNeeded()

        for sample in samples {
            try BlastVerificationArchive.save(
                Self.verification(rid: "RID-\(sample)"),
                request: nil,
                in: scratch.appendingPathComponent(sample, isDirectory: true),
                toolName: "lungfish-cli",
                toolKind: "cli"
            )
        }
        let scratch = scratch!
        vc.blastVerificationDirectoryResolver = { [unowned vc] node in
            scratch.appendingPathComponent(vc.owningSampleId(for: node) ?? "none", isDirectory: true)
        }
        vc.toggleTaxaCollectionsDrawer()

        let root = try XCTUnwrap(vc.testTableView.tree).root
        func node(_ taxId: Int, in sample: String) throws -> TaxonNode {
            let sampleNode = try XCTUnwrap(root.children.first { $0.taxId < 0 && $0.name == sample }, "sample \(sample)")
            return try XCTUnwrap(Self.find(taxId, in: sampleNode), "taxon \(taxId) in \(sample)")
        }
        let viruses = try node(10239, in: "S1")
        XCTAssertEqual(vc.owningSampleId(for: viruses), "S1")
        return Display(
            controller: vc,
            virusesInS1: viruses,
            virusesInS2: try node(10239, in: "S2"),
            betacoronavirusInS1: try node(694002, in: "S1")
        )
    }

    private static func find(_ taxId: Int, in node: TaxonNode) -> TaxonNode? {
        if node.taxId == taxId { return node }
        for child in node.children {
            if let hit = find(taxId, in: child) { return hit }
        }
        return nil
    }

    private static func verification(rid: String) -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: "Viruses",
            taxId: 10239,
            readResults: [
                BlastReadResult(
                    id: "read-1", verdict: .verified, topHitOrganism: "Viruses", topHitAccession: "NC_000001.1",
                    percentIdentity: 99.0, eValue: 0.0, matchesQueriedTaxon: true
                )
            ],
            submittedAt: Date(),
            completedAt: Date(),
            rid: rid,
            blastProgram: "megablast",
            database: "core_nt"
        )
    }

    /// S1 holds Viruses and Betacoronavirus, S2 holds Viruses and Influenza A virus.
    private func makeMultiSampleDatabase() throws -> Kraken2Database {
        let rows = [
            Kraken2ClassificationRow(sample: "S1", taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root", readsDirect: 0, readsClade: 100, percentage: 100.0, parentTaxId: nil, depth: 0, fractionDirect: 0),
            Kraken2ClassificationRow(sample: "S1", taxonName: "Viruses", taxId: 10239, rank: "D", rankDisplayName: "Domain", readsDirect: 0, readsClade: 60, percentage: 60.0, parentTaxId: 1, depth: 1, fractionDirect: 0),
            Kraken2ClassificationRow(sample: "S1", taxonName: "Coronaviridae", taxId: 11118, rank: "F", rankDisplayName: "Family", readsDirect: 10, readsClade: 40, percentage: 40.0, parentTaxId: 10239, depth: 2, fractionDirect: 0.1),
            Kraken2ClassificationRow(sample: "S1", taxonName: "Betacoronavirus", taxId: 694002, rank: "G", rankDisplayName: "Genus", readsDirect: 8, readsClade: 20, percentage: 20.0, parentTaxId: 11118, depth: 3, fractionDirect: 0.08),
            Kraken2ClassificationRow(sample: "S2", taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root", readsDirect: 0, readsClade: 90, percentage: 100.0, parentTaxId: nil, depth: 0, fractionDirect: 0),
            Kraken2ClassificationRow(sample: "S2", taxonName: "Viruses", taxId: 10239, rank: "D", rankDisplayName: "Domain", readsDirect: 0, readsClade: 40, percentage: 44.4, parentTaxId: 1, depth: 1, fractionDirect: 0),
            Kraken2ClassificationRow(sample: "S2", taxonName: "Influenza A virus", taxId: 11320, rank: "S", rankDisplayName: "Species", readsDirect: 12, readsClade: 12, percentage: 13.3, parentTaxId: 10239, depth: 2, fractionDirect: 0.13),
        ]
        return try Kraken2Database.create(
            at: scratch.appendingPathComponent("kraken2.sqlite"),
            rows: rows,
            metadata: [
                "total_reads_S1": "100", "classified_reads_S1": "100", "unclassified_reads_S1": "0",
                "total_reads_S2": "90", "classified_reads_S2": "90", "unclassified_reads_S2": "0",
            ]
        )
    }
}
