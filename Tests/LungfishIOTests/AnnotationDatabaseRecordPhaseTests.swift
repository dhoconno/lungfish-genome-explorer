// AnnotationDatabaseRecordPhaseTests.swift - The 5' phase a bundle CDS row carries into its annotation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.65 (V1-2, BIO ruling on 13.65 R1 to R3, ARCH 4). `AnnotationDatabaseRecord.toAnnotation` is the
// one reader that sets the phase of a bundle CDS, on the interval that is first in transcription order.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class AnnotationDatabaseRecordPhaseTests: XCTestCase {
    /// The `chrR` CDS of the ruling as a database built before the lane stores it. The two GFF3 lines list the 3'
    /// segment first (`3 7`, phase 2) and the 5' segment second (`11 18`, phase 1), so the merged row keeps the first
    /// line's `lungfish_gff_phase=2`, which is the 3' segment's phase.
    static let reverseRowAtTheBase = AnnotationDatabaseRecord(
        rowID: 1, name: "r", type: "CDS", chromosome: "chrR", start: 2, end: 18, strand: "-",
        attributes: "ID=cds-r;Name=r;lungfish_gff_phase=2", blockCount: 2, blockSizes: "5,8", blockStarts: "0,8"
    )

    /// Pin 10 (ARCH 4). A merged CDS row that holds no `lungfish_cds_phase` reads with no phase on any interval, as
    /// it did before the lane, since its `lungfish_gff_phase` is the first line's in file order and not the 5' one.
    func testABundleBuiltBeforeTheLaneReadsAMergedCDSWithoutAPhase() {
        let annotation = Self.reverseRowAtTheBase.toAnnotation()

        XCTAssertEqual(annotation.intervals.map(\.start), [2, 10])
        XCTAssertEqual(annotation.intervals.map(\.end), [7, 18])
        XCTAssertEqual(annotation.intervals.map(\.phase), [nil, nil])
    }

    /// Pin 8 (R1 to R3). The interval first in transcription order carries the row's 5' phase and every other interval
    /// none. The `chrR` CDS imported through `createFromGFF3` puts phase 1 on [10,18), its 5' segment on the reverse
    /// strand. A one-line CDS row reads its own `lungfish_gff_phase`, and a two-block row that `createFromBED` stores
    /// from a GenBank download reads its `codon_start` less 1 on its lowest interval.
    func testBundleCDSReadCarriesItsFivePrimePhase() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationDatabaseRecordPhase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gff = folder.appendingPathComponent("r.gff3")
        try ("##gff-version 3\n" + "chrR\t.\tCDS\t3\t7\t.\t-\t2\tID=cds-r;Name=r\n" + "chrR\t.\tCDS\t11\t18\t.\t-\t1\tID=cds-r;Name=r\n")
            .write(to: gff, atomically: true, encoding: .utf8)
        let gffDatabase = folder.appendingPathComponent("r.db")
        _ = try await AnnotationDatabase.createFromGFF3(gffURL: gff, outputURL: gffDatabase)
        let merged = try XCTUnwrap(try AnnotationDatabase(url: gffDatabase).query(limit: 10).first).toAnnotation()
        XCTAssertEqual(merged.intervals.map(\.start), [2, 10])
        XCTAssertEqual(merged.intervals.map(\.phase), [nil, 1], "the 5' segment of the reverse CDS carries phase 1")

        let oneLine = AnnotationDatabaseRecord(
            rowID: 2, name: "f", type: "CDS", chromosome: "chrF", start: 0, end: 13, strand: "+",
            attributes: "ID=cds-f;Name=f;lungfish_gff_phase=1"
        )
        XCTAssertEqual(oneLine.toAnnotation().intervals.map(\.phase), [1], "a one-line CDS reads its own column 8")

        let bed = folder.appendingPathComponent("b.bed")
        try "chrB\t9\t140\torf1\t0\t+\t9\t140\t0\t2\t51,80,\t0,51,\tCDS\tcodon_start=2;gene=orf1;product=p\n"
            .write(to: bed, atomically: true, encoding: .utf8)
        let bedDatabase = folder.appendingPathComponent("b.db")
        try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bedDatabase)
        let joined = try XCTUnwrap(try AnnotationDatabase(url: bedDatabase).query(limit: 10).first).toAnnotation()
        XCTAssertEqual(joined.intervals.map(\.start), [9, 60])
        XCTAssertEqual(joined.intervals.map(\.phase), [1, nil], "codon_start=2 is phase 1 on the 5' interval")
    }

    /// 13.65-BIO Fix 1 (R2, the one-line branch of `AnnotationDatabase+Building.swift`). A one-line reverse CDS that the
    /// clip cut at the end of its sequence stores the phase of its first stored base: 16 bases cut to 14 lose 2, and
    /// (1 - 2) mod 3 is 2. A line the clip left whole, and a forward line whose clip cut its 3' end, read their own
    /// column 8 and store no `lungfish_cds_phase`.
    func testAClippedOneLineReverseCDSStoresItsPhaseAtTheCut() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationDatabaseRecordPhase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        /// The one row of a fresh database built from the same CDS line on `strand`, with `chrS` of `size` bases.
        func onlyRow(strand: String, size: Int64, name: String) async throws -> AnnotationDatabaseRecord {
            let gff = folder.appendingPathComponent("\(name).gff3")
            try "##gff-version 3\nchrS\t.\tCDS\t3\t18\t.\t\(strand)\t1\tID=cds-s;Name=s\n"
                .write(to: gff, atomically: true, encoding: .utf8)
            let database = folder.appendingPathComponent("\(name).db")
            _ = try await AnnotationDatabase.createFromGFF3(
                gffURL: gff, outputURL: database, chromosomeSizes: [("chrS", size)]
            )
            return try XCTUnwrap(try AnnotationDatabase(url: database).query(limit: 10).first)
        }

        let cut = try await onlyRow(strand: "-", size: 16, name: "cut")
        XCTAssertEqual([cut.start, cut.end], [2, 16], "the clip cut the line at the end of its sequence")
        XCTAssertEqual(AnnotationDatabase.parseAttributes(cut.attributes ?? "")["lungfish_cds_phase"], "2")
        XCTAssertEqual(cut.fivePrimePhase, 2)
        XCTAssertEqual(cut.toAnnotation().intervals.map(\.phase), [2])

        let whole = try await onlyRow(strand: "-", size: 20, name: "whole")
        XCTAssertNil(AnnotationDatabase.parseAttributes(whole.attributes ?? "")["lungfish_cds_phase"], "nothing was cut")
        XCTAssertEqual(whole.fivePrimePhase, 1)

        let forward = try await onlyRow(strand: "+", size: 16, name: "forward")
        XCTAssertNil(
            AnnotationDatabase.parseAttributes(forward.attributes ?? "")["lungfish_cds_phase"], "the clip cut the 3' end"
        )
        XCTAssertEqual(forward.fivePrimePhase, 1)
    }
}
