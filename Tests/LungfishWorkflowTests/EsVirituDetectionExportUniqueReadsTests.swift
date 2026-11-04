// EsVirituDetectionExportUniqueReadsTests.swift - The Unique Reads column of the EsViritu detections export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ESVUNIQUE (row ESVIRITU-EXPORT-NO-UNIQUE-READS, owner direction O142). The viewer's Export and
// `esviritu export detections` both build the file from the database's rows with
// `EsVirituDetectionExport.batchResult(rows:selectedSamples:)` and `buildDelimitedExport`, so each test starts from
// the rows. The database stores `unique_reads` per contig, the reads of that contig that are not duplicates, and
// stores nothing (NULL) for a contig whose count was never computed.

import LungfishCore
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class EsVirituDetectionExportUniqueReadsTests: XCTestCase {
    private static func row(
        sample: String = "sample-A",
        accession: String,
        assembly: String,
        segment: String? = nil,
        readCount: Int,
        uniqueReads: Int?
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample, virusName: "virus \(assembly)", description: nil, contigLength: 1_000, segment: segment,
            accession: accession, assembly: assembly, assemblyLength: 3_000, kingdom: "Viruses",
            phylum: nil, tclass: nil, torder: nil, family: "Testviridae", genus: nil, species: nil, subspecies: nil,
            rpkmf: 1.5, readCount: readCount, uniqueReads: uniqueReads, coveredBases: 500, meanCoverage: 2,
            avgReadIdentity: 0.9, pi: nil, filteredReadsInSample: 10_000, bamPath: nil, bamIndexPath: nil
        )
    }

    /// The file the viewer's Export and the leaf write for these rows, as a header and one array of cells a line.
    private static func export(
        _ rows: [EsVirituDetectionRow],
        samples: [String] = ["sample-A"]
    ) -> (header: [String], lines: [[String]]) {
        let result = EsVirituDetectionExport.batchResult(rows: rows, selectedSamples: samples)
        let text = EsVirituDetectionExport.buildDelimitedExport(
            result: result, separator: "\t", metadataHeaders: [], metadataValuesBySample: [:]
        )
        let lines = text.split(separator: "\n").map { $0.components(separatedBy: "\t") }
        return (lines.first ?? [], Array(lines.dropFirst()))
    }

    /// The cells of one column, one a line.
    private func cells(_ column: String, in table: (header: [String], lines: [[String]])) throws -> [String] {
        let index = try XCTUnwrap(table.header.firstIndex(of: column), "the export header holds \(column): \(table.header)")
        return table.lines.map { $0.count > index ? $0[index] : "<no field>" }
    }

    /// O142. The export writes the Unique Reads column the table shows, right after Read Count, with the count the
    /// database stores for the contig.
    func testExportWritesUniqueReadsBesideReadCount() throws {
        let table = Self.export([
            Self.row(accession: "NC_1", assembly: "GCF_1", readCount: 40, uniqueReads: 31),
            Self.row(sample: "sample-B", accession: "NC_2", assembly: "GCF_2", readCount: 20, uniqueReads: 18),
        ], samples: ["sample-A", "sample-B"])

        let readCount = try XCTUnwrap(table.header.firstIndex(of: "Read Count"), "the export header holds Read Count")
        XCTAssertEqual(
            table.header.firstIndex(of: "Unique Reads"), readCount + 1,
            "Unique Reads sits right after Read Count: \(table.header)"
        )
        XCTAssertEqual(try cells("Sample ID", in: table), ["sample-A", "sample-B"])
        XCTAssertEqual(try cells("Read Count", in: table), ["40", "20"])
        XCTAssertEqual(try cells("Unique Reads", in: table), ["31", "18"])
    }

    /// O142 item 2. A count that was never computed (NULL in the database) writes an empty cell. Writing 0 would say
    /// that no read was unique, which is a false number. A count that was computed and is 0 stays 0.
    func testExportLeavesUniqueReadsEmptyWhenItWasNeverCounted() throws {
        let table = Self.export([
            Self.row(accession: "NC_1", assembly: "GCF_1", readCount: 40, uniqueReads: nil),
            Self.row(accession: "NC_2", assembly: "GCF_2", readCount: 20, uniqueReads: 15),
            Self.row(accession: "NC_3", assembly: "GCF_3", readCount: 0, uniqueReads: 0),
        ])

        XCTAssertEqual(try cells("Read Count", in: table), ["40", "20", "0"])
        XCTAssertEqual(
            try cells("Unique Reads", in: table), ["", "15", "0"],
            "never counted is empty, counted is the count, and a computed zero stays 0"
        )
    }

    /// O142 item 3. The export writes a row for each contig, and the database stores the count for each contig. A
    /// segmented virus writes each segment's own count on the segment's row, never the virus's total on every row,
    /// and a segment whose count was never computed stays empty while its sibling segments keep theirs.
    func testSegmentedVirusWritesEachSegmentsOwnCountAndLeavesAnUncountedSegmentEmpty() throws {
        let partlyCounted = Self.export([
            Self.row(accession: "NC_L", assembly: "GCF_SEG", segment: "L", readCount: 40, uniqueReads: 31),
            Self.row(accession: "NC_M", assembly: "GCF_SEG", segment: "M", readCount: 25, uniqueReads: 20),
            Self.row(accession: "NC_S", assembly: "GCF_SEG", segment: "S", readCount: 10, uniqueReads: nil),
        ])
        XCTAssertEqual(try cells("Segment", in: partlyCounted), ["L", "M", "S"])
        XCTAssertEqual(try cells("Read Count", in: partlyCounted), ["40", "25", "10"])
        XCTAssertEqual(
            try cells("Unique Reads", in: partlyCounted), ["31", "20", ""],
            "each segment writes its own count and the uncounted segment stays empty"
        )

        let counted = Self.export([
            Self.row(accession: "NC_L", assembly: "GCF_SEG", segment: "L", readCount: 40, uniqueReads: 31),
            Self.row(accession: "NC_M", assembly: "GCF_SEG", segment: "M", readCount: 25, uniqueReads: 20),
            Self.row(accession: "NC_S", assembly: "GCF_SEG", segment: "S", readCount: 10, uniqueReads: 9),
        ])
        let perSegment = try cells("Unique Reads", in: counted)
        XCTAssertEqual(perSegment, ["31", "20", "9"])
        XCTAssertEqual(perSegment.compactMap(Int.init).reduce(0, +), 60, "the segments add up to the virus's unique reads")
    }
}
