// EsVirituExportUniqueReadsTests.swift - The viewer's table and its export agree on Unique Reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ESVUNIQUE (row ESVIRITU-EXPORT-NO-UNIQUE-READS, owner direction O142, item 3). The viewer shows one
// row for each virus (assembly) and the export writes one row for each contig. The database stores the count for
// each contig, and the viewer's row for a virus shows the sum of its contigs. So the export's rows for a virus must
// add up to the number the table shows for that virus. The view is configured as the app's route configures it
// (`ViewerViewController+EsViritu.swift`), and the export is built as the viewer's Export and the leaf build it, from
// the database's rows.

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishEsVirituUI

@MainActor
final class EsVirituExportUniqueReadsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituExportUniqueReads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func row(
        accession: String,
        assembly: String,
        segment: String?,
        readCount: Int,
        uniqueReads: Int?
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: "sample-A", virusName: "virus \(assembly)", description: nil, contigLength: 1_000, segment: segment,
            accession: accession, assembly: assembly, assemblyLength: 3_000, kingdom: "Viruses",
            phylum: nil, tclass: nil, torder: nil, family: "Testviridae", genus: nil, species: nil, subspecies: nil,
            rpkmf: 1.5, readCount: readCount, uniqueReads: uniqueReads, coveredBases: 500, meanCoverage: 2,
            avgReadIdentity: 0.9, pi: nil, filteredReadsInSample: 10_000, bamPath: nil, bamIndexPath: nil
        )
    }

    private func configuredView(rows: [EsVirituDetectionRow]) throws -> (EsVirituResultViewController, [EsVirituDetectionRow]) {
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
        let layouts = TestDefaultsSuite(prefix: "EsVirituExportUniqueReadsTests")
        view.testDetectionTableView.metadataColumns.userDefaults = layouts.defaults
        view.testBatchTableView.metadataColumns.userDefaults = layouts.defaults
        _ = view.view
        view.configureFromDatabase(database, resultURL: resultURL)
        view.samplePickerState.selectedSamples = ["sample-A"]
        view.applyBatchSampleFilter()
        return (view, try database.fetchRows(samples: ["sample-A"]))
    }

    /// The file the viewer's Export and the leaf write for the database's rows.
    private func exported(rows: [EsVirituDetectionRow]) -> (header: [String], lines: [[String]]) {
        let result = EsVirituDetectionExport.batchResult(rows: rows, selectedSamples: ["sample-A"])
        let text = EsVirituDetectionExport.buildDelimitedExport(
            result: result, separator: "\t", metadataHeaders: [], metadataValuesBySample: [:]
        )
        let lines = text.split(separator: "\n").map { $0.components(separatedBy: "\t") }
        return (lines.first ?? [], Array(lines.dropFirst()))
    }

    /// A segmented virus of three segments, a virus of one contig, and a virus whose count was never computed. The
    /// export's rows for the segmented virus add up to the number its table row shows, the single contig's row equals
    /// its table row, and the uncounted contig writes an empty cell.
    func testExportRowsAddUpToTheVirusRowTheTableShows() throws {
        let (view, rows) = try configuredView(rows: [
            Self.row(accession: "NC_L", assembly: "GCF_SEG", segment: "L", readCount: 40, uniqueReads: 31),
            Self.row(accession: "NC_M", assembly: "GCF_SEG", segment: "M", readCount: 25, uniqueReads: 20),
            Self.row(accession: "NC_S", assembly: "GCF_SEG", segment: "S", readCount: 10, uniqueReads: 9),
            Self.row(accession: "NC_X", assembly: "GCF_ONE", segment: nil, readCount: 50, uniqueReads: 44),
            Self.row(accession: "NC_Y", assembly: "GCF_NEVER", segment: nil, readCount: 15, uniqueReads: nil),
        ])
        let table = exported(rows: rows)

        let accession = try XCTUnwrap(table.header.firstIndex(of: "Accession"), "the export header holds Accession")
        let assembly = try XCTUnwrap(table.header.firstIndex(of: "Assembly"), "the export header holds Assembly")
        let readCount = try XCTUnwrap(table.header.firstIndex(of: "Read Count"), "the export header holds Read Count")
        let unique = try XCTUnwrap(table.header.firstIndex(of: "Unique Reads"), "the export header holds Unique Reads")
        XCTAssertEqual(unique, readCount + 1, "Unique Reads sits right after Read Count")

        var uniqueByContig: [String: String] = [:]
        var sumByAssembly: [String: Int] = [:]
        for line in table.lines where line.count > unique {
            uniqueByContig[line[accession]] = line[unique]
            sumByAssembly[line[assembly], default: 0] += Int(line[unique]) ?? 0
        }
        XCTAssertEqual(uniqueByContig["NC_L"], "31")
        XCTAssertEqual(uniqueByContig["NC_M"], "20")
        XCTAssertEqual(uniqueByContig["NC_S"], "9")
        XCTAssertEqual(uniqueByContig["NC_Y"], "", "a contig whose count was never computed writes an empty cell")

        let screen = view.testDetectionTableView.uniqueReadCountsBySampleAssembly
        XCTAssertEqual(screen["sample-A\tGCF_SEG"], 60, "the table's row for the segmented virus shows the sum of its segments")
        XCTAssertEqual(sumByAssembly["GCF_SEG"], screen["sample-A\tGCF_SEG"], "the segmented virus's export rows add up to its table row")
        XCTAssertEqual(sumByAssembly["GCF_ONE"], screen["sample-A\tGCF_ONE"], "a virus of one contig writes its table row's number")
    }
}
