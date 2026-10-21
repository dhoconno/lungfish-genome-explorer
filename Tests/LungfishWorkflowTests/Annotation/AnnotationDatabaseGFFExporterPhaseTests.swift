// AnnotationDatabaseGFFExporterPhaseTests.swift - Column 8 and the shared ID of a multi-block CDS export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.65 (V1-2, BIO ruling on 13.65 R5 and R7, QA Q5, Q-B3 of the 13.20 ruling). Each case writes a
// database through the leaf exporter (`AnnotationDatabaseGFFExporter.export`) and reads its lines back.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AnnotationDatabaseGFFExporterPhaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationDatabaseGFFExporterPhase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A database built by `createFromBED` from `lines`.
    private func bedDatabase(_ lines: String) throws -> AnnotationDatabase {
        let bed = folder.appendingPathComponent("rows.bed")
        try lines.write(to: bed, atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("bed-\(UUID().uuidString).db")
        try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: url)
        return try AnnotationDatabase(url: url)
    }

    /// The feature lines of the leaf's export of `database`, each split into its nine columns.
    private func exportedLines(_ database: AnnotationDatabase) throws -> [[String]] {
        let url = folder.appendingPathComponent("export-\(UUID().uuidString).gff3")
        try AnnotationDatabaseGFFExporter.export(database: database, to: url)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// Pin 10 (Q-B3). A one-block row whose stored pairs hold no `ID` is one feature on one line, so it writes its
    /// pairs unchanged and claims no ID.
    func testASingleLineRowWithoutAnIDKeepsItsPairs() throws {
        let database = try bedDatabase("chrB\t9\t60\torf1\t0\t+\t9\t60\t0\t1\t51\t0\tCDS\tgene=g;product=p\n")

        let lines = try exportedLines(database)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?[3], "10")
        XCTAssertEqual(lines.first?[4], "60")
        XCTAssertEqual(lines.first?[8], "gene=g;product=p")
    }

    /// The `chrR` CDS of the ruling, its 3' segment (`3 7`, phase 2) listed first and its 5' segment (`11 18`, phase
    /// 1) second, imported through `createFromGFF3` with `sizes`.
    private func reverseCDSDatabase(sizes: [(String, Int64)]?) async throws -> AnnotationDatabase {
        let gff = folder.appendingPathComponent("r-\(UUID().uuidString).gff3")
        try ("##gff-version 3\n" + "chrR\t.\tCDS\t3\t7\t.\t-\t2\tID=cds-r;Name=r\n" + "chrR\t.\tCDS\t11\t18\t.\t-\t1\tID=cds-r;Name=r\n")
            .write(to: gff, atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("gff-\(UUID().uuidString).db")
        _ = try await AnnotationDatabase.createFromGFF3(gffURL: gff, outputURL: url, chromosomeSizes: sizes)
        return try AnnotationDatabase(url: url)
    }

    /// Pin 6 (QA Q5, R5). The 5' segment `11 18` keeps phase 1 and the 3' segment, 8 coding bases later, takes
    /// (1 - 8) mod 3 = 2, on the leaf and on `GFF3Writer` through `toAnnotation`. At the base both wrote the 5'
    /// segment at phase 0 and the 3' one at 1. The database cut at 16 stores phase 2 on its first base, so `11 16`
    /// writes 2 and `3 7`, 6 bases later, writes (2 - 6) mod 3 = 2.
    func testMultiBlockCDSExportKeepsItsFirstPhase() async throws {
        let database = try await reverseCDSDatabase(sizes: nil)
        let leaf = try exportedLines(database)
        XCTAssertEqual(leaf.map { [$0[3], $0[4], $0[6], $0[7], $0[8]] }, [
            ["3", "7", "-", "2", "ID=cds-r;Name=r"], ["11", "18", "-", "1", "ID=cds-r;Name=r"],
        ], "the leaf writes the phases of the 5' phase 1")

        let url = folder.appendingPathComponent("writer.gff3")
        try await GFF3Writer.write(database.query(limit: 10).map { $0.toAnnotation() }, to: url)
        let written = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(written.map { [$0[3], $0[4], $0[7]] }, [["3", "7", "2"], ["11", "18", "1"]], "GFF3Writer")

        let cut = try exportedLines(try await reverseCDSDatabase(sizes: [("chrR", 16)]))
        XCTAssertEqual(cut.map { [$0[3], $0[4], $0[7]] }, [["3", "7", "2"], ["11", "16", "2"]], "the cut database")
    }

    /// Pin 9 (Q-B3, R7). A two-block row that `createFromBED` stores, as a GenBank download does, holds pairs and no
    /// `ID`, so its two lines share the row-key ID before the pairs and a GFF3 reader sees one feature.
    func testMultiBlockRowWithoutAnIDExportsOneFeature() throws {
        let database = try bedDatabase(
            "chrB\t9\t140\torf1\t0\t+\t9\t140\t0\t2\t51,80,\t0,51,\tCDS\tcodon_start=1;gene=orf1;product=p\n"
        )
        let rowID = try XCTUnwrap(database.query(limit: 10).first?.rowID)

        let lines = try exportedLines(database)

        XCTAssertEqual(lines.map { [$0[3], $0[4]] }, [["10", "60"], ["61", "140"]])
        XCTAssertEqual(lines.map { $0[8] }, Array(repeating: "ID=lungfish-row-\(rowID);codon_start=1;gene=orf1;product=p", count: 2))
    }
}
