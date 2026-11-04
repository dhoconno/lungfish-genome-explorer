// EsVirituUncountedUniqueReadsTests.swift - A count never computed shows no number in the EsViritu viewer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ESVUNIQUE, BIO review Blocker 2 (S1) and should-fix 1. A contig whose Unique Reads was never computed
// (the BAM is missing, markdup failed or a count failed) used to show 1 on its virus row, so 5,000 reads beside a
// Unique Reads of 1 read as nearly all PCR duplicates. The screen and the export now agree through
// `ClassifierUniqueReads.normalized`. A virus row holds a total only when every contig was counted, an uncounted row
// leaves no entry that another sample's row could fall back on, and a segment row shows its stored count. The view is
// configured as the app's route configures it, and the checks read what the table holds.

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishEsVirituUI

@MainActor
final class EsVirituUncountedUniqueReadsTests: XCTestCase {
    private var folder: URL!
    private var layouts: TestDefaultsSuite!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituUncountedUniqueReads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        layouts = TestDefaultsSuite(prefix: "EsVirituUncountedUniqueReadsTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func row(
        sample: String = "sample-A",
        accession: String,
        assembly: String,
        readCount: Int,
        uniqueReads: Int?
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample, virusName: "virus \(assembly)", description: nil, contigLength: 1_000, segment: nil,
            accession: accession, assembly: assembly, assemblyLength: 3_000, kingdom: "Viruses",
            phylum: nil, tclass: nil, torder: nil, family: "Testviridae", genus: nil, species: nil, subspecies: nil,
            rpkmf: 1.5, readCount: readCount, uniqueReads: uniqueReads, coveredBases: 500, meanCoverage: 2,
            avgReadIdentity: 0.9, pi: nil, filteredReadsInSample: 10_000, bamPath: nil, bamIndexPath: nil
        )
    }

    private func configuredView(
        rows: [EsVirituDetectionRow],
        samples: Set<String> = ["sample-A"]
    ) throws -> EsVirituResultViewController {
        let resultURL = folder.appendingPathComponent("esviritu-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        try EsVirituDatabase.create(
            at: resultURL.appendingPathComponent(EsVirituDetectionExport.databaseFileName),
            rows: rows,
            metadata: ["tool": "test"]
        )
        try Data("{}".utf8).write(to: resultURL.appendingPathComponent(EsVirituBatchAggregatedManifest.filename))
        let database = try EsVirituDatabase(at: resultURL.appendingPathComponent(EsVirituDetectionExport.databaseFileName))
        let view = EsVirituResultViewController()
        view.testDetectionTableView.metadataColumns.userDefaults = layouts.defaults
        view.testBatchTableView.metadataColumns.userDefaults = layouts.defaults
        _ = view.view
        view.configureFromDatabase(database, resultURL: resultURL)
        view.samplePickerState.selectedSamples = samples
        view.applyBatchSampleFilter()
        return view
    }

    private func batchRow(
        _ view: EsVirituResultViewController,
        _ assembly: String,
        sample: String = "sample-A"
    ) throws -> BatchEsVirituRow {
        try XCTUnwrap(
            view.allBatchRows.first { $0.assembly == assembly && $0.sample == sample },
            "the table holds a row for \(assembly)"
        )
    }

    /// Red at the base, where the virus row shows 1 for 5,000 reads.
    func testVirusRowOfAnUncountedContigHoldsNoNumber() throws {
        let view = try configuredView(rows: [
            Self.row(accession: "NC_Y", assembly: "GCF_NEVER", readCount: 5_000, uniqueReads: nil),
        ])
        let row = try batchRow(view, "GCF_NEVER")
        XCTAssertNil(row.uniqueReads, "5,000 reads beside a count never computed hold no number, never 1")
        XCTAssertEqual(
            view.testBatchTableView.cellContent(for: NSUserInterfaceItemIdentifier("uniqueReads"), row: row).text, "\u{2014}",
            "the cell shows a dash"
        )
    }

    /// Red at the base, where the virus row adds 1 for the segment that was never counted and shows 52.
    func testVirusRowWithOneUncountedSegmentHoldsNoTotal() throws {
        let view = try configuredView(rows: [
            Self.row(accession: "NC_L", assembly: "GCF_SEG", readCount: 40, uniqueReads: 31),
            Self.row(accession: "NC_M", assembly: "GCF_SEG", readCount: 25, uniqueReads: 20),
            Self.row(accession: "NC_S", assembly: "GCF_SEG", readCount: 10, uniqueReads: nil),
        ])
        XCTAssertNil(try batchRow(view, "GCF_SEG").uniqueReads,
                     "31 and 20 beside a segment never counted are not the virus's total")
    }

    func testVirusRowSumsCountedSegments() throws {
        let view = try configuredView(rows: [
            Self.row(accession: "NC_L", assembly: "GCF_SEG", readCount: 40, uniqueReads: 31),
            Self.row(accession: "NC_M", assembly: "GCF_SEG", readCount: 25, uniqueReads: 20),
            Self.row(accession: "NC_S", assembly: "GCF_SEG", readCount: 10, uniqueReads: 9),
        ])
        XCTAssertEqual(try batchRow(view, "GCF_SEG").uniqueReads, 60)
    }

    /// Red at the base, where sample A's uncounted row is raised to 1 and left in both maps.
    func testAnUncountedVirusDoesNotBorrowAnotherSamplesCount() throws {
        let view = try configuredView(rows: [
            Self.row(sample: "sample-A", accession: "NC_X", assembly: "GCF_X", readCount: 5_000, uniqueReads: nil),
            Self.row(sample: "sample-B", accession: "NC_X", assembly: "GCF_X", readCount: 40, uniqueReads: 18),
        ], samples: ["sample-A", "sample-B"])
        let rows = view.allBatchRows
        for (order, label) in [(rows, "rows as loaded"), (Array(rows.reversed()), "rows reversed")] {
            view.allBatchRows = order
            view.applyBatchSampleFilter()
            let table = view.testDetectionTableView
            XCTAssertNil(table.uniqueReadCountsByAssembly["GCF_X"],
                         "\(label), no row of the virus may fall back on one sample's count")
            XCTAssertNil(table.uniqueReadCountsBySampleAssembly["sample-A\tGCF_X"], "\(label), sample A was never counted")
            XCTAssertEqual(table.uniqueReadCountsBySampleAssembly["sample-B\tGCF_X"], 18, "\(label), sample B was counted")
        }
    }

    /// Should-fix 1, red at the base, where the segment rows hold no count and show an ellipsis for ever.
    func testSegmentRowsShowTheirStoredCounts() throws {
        let view = try configuredView(rows: [
            Self.row(accession: "NC_L", assembly: "GCF_SEG", readCount: 40, uniqueReads: 31),
            Self.row(accession: "NC_M", assembly: "GCF_SEG", readCount: 25, uniqueReads: 20),
            Self.row(accession: "NC_S", assembly: "GCF_SEG", readCount: 10, uniqueReads: 9),
            Self.row(accession: "NC_Y", assembly: "GCF_NEVER", readCount: 15, uniqueReads: nil),
        ])
        XCTAssertEqual(
            view.testDetectionTableView.uniqueReadCountsBySampleContig,
            ["sample-A\tNC_L": 31, "sample-A\tNC_M": 20, "sample-A\tNC_S": 9],
            "each segment holds its stored count and the contig never counted holds none"
        )
    }
}
