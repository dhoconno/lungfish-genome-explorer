// DatabaseRowsByIDTests.swift - The reads by row id that the annotation table export leaf makes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 item 5 and section 7 step 10. `bundle export-annotation-table`
/// reads the rows the table showed by the row ids in its selection file, in the selection's order.
final class DatabaseRowsByIDTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rows-by-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testVariantsForExportReturnsTheRowsInTheGivenOrder() throws {
        let vcf = directory.appendingPathComponent("calls.vcf")
        try """
        ##fileformat=VCFv4.2
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t50\tPASS\tDP=10
        chr1\t200\trs2\tC\tT\t40\tPASS\tDP=20
        chr2\t300\trs3\tG\tA\t30\tPASS\tDP=30

        """.write(to: vcf, atomically: true, encoding: .utf8)
        let databaseURL = directory.appendingPathComponent("calls.db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: databaseURL)
        let database = try VariantDatabase(url: databaseURL)
        let all = try database.queryForTableExport(limit: 10)
        XCTAssertEqual(all.map(\.variantID), ["rs1", "rs2", "rs3"])
        let ids = all.compactMap(\.id)
        XCTAssertEqual(ids.count, 3)

        let rows = try database.variantsForExport(rowIDs: [ids[2], ids[0], 9_999, ids[2]])

        XCTAssertEqual(rows, [all[2], all[0], all[2]], "the given order, a missing id left out, a repeat kept")
        XCTAssertEqual(try database.variantsForExport(rowIDs: []), [])
    }

    func testVariantsForExportReadsMoreRowsThanOneStatementBinds() throws {
        let vcf = directory.appendingPathComponent("many.vcf")
        var text = "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
        for position in 1...(VariantDatabase.rowsByIDChunkSize + 7) {
            text += "chr1\t\(position)\tv\(position)\tA\tG\t50\tPASS\t.\n"
        }
        try text.write(to: vcf, atomically: true, encoding: .utf8)
        let databaseURL = directory.appendingPathComponent("many.db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: databaseURL)
        let database = try VariantDatabase(url: databaseURL)
        let all = try database.queryForTableExport(limit: 10_000)

        let rows = try database.variantsForExport(rowIDs: all.compactMap(\.id).reversed())

        XCTAssertEqual(rows, Array(all.reversed()))
    }

    func testAnnotationsForExportReturnsTheRowsInTheGivenOrder() throws {
        let bed = directory.appendingPathComponent("genes.bed")
        try "chr1\t10\t50\tgeneA\t0\t+\nchr1\t60\t90\tgeneB\t0\t-\nchr2\t5\t25\tgeneC\t0\t+\n"
            .write(to: bed, atomically: true, encoding: .utf8)
        let databaseURL = directory.appendingPathComponent("genes.db")
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: databaseURL)
        let database = try AnnotationDatabase(url: databaseURL)
        let all = try database.queryForTableExport(limit: 10)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        let ids = try ["geneC", "geneA"].map { try XCTUnwrap(byName[$0]?.rowID) }

        let rows = try database.annotationsForExport(rowIDs: ids + [9_999])

        XCTAssertEqual(rows.map(\.name), ["geneC", "geneA"])
        XCTAssertEqual(rows.map(\.rowID), ids)
        XCTAssertEqual(rows.map(\.chromosome), ["chr2", "chr1"])
        XCTAssertEqual(rows.map(\.start), [5, 10])
        XCTAssertEqual(rows.map(\.end), [25, 50])
        XCTAssertEqual(rows.map(\.strand), ["+", "+"])
        XCTAssertEqual(try database.annotationsForExport(rowIDs: []).count, 0)
    }
}
