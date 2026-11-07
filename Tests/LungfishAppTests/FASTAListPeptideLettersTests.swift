// FASTAListPeptideLettersTests.swift - A peptide of nucleotide letters shows a dash in the FASTA list (Phase 3.3 lane FASTAGC)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// FASTA-PEPTIDE-NUCLEOTIDE-LETTERS (S3, BIO): the reader typed a peptide DNA when every letter was an IUPAC nucleotide
/// code, so the list's GC pass counted its G, C, A and T letters and showed a GC percent for it (33.3% for `MKTAYGHSSRV`).
/// The reader now types it protein and the pass, which gives a protein record no GC percent, shows a dash. This test runs
/// the file through the reader and the list's own GC pass, the two steps the list takes before it draws a cell.
final class FASTAListPeptideLettersTests: XCTestCase {
    func testPeptideOfNucleotideLettersShowsADashAndNucleotideRecordsKeepTheirGC() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTAListPeptideLetters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mixed.fasta")
        try """
        >peptide1
        MKTAYGHSSRV
        >peptide2
        AGTHSRKDVMC
        >peptide3
        NDGHKSRVWYM
        >dna
        ACGTACGTGG
        >rna
        AUGGCUACGU
        """.write(to: url, atomically: true, encoding: .utf8)

        let sequences = try FASTAReader(url: url).readAllSync()
        let result = try XCTUnwrap(FASTACollectionGC.count(sequences))
        func composition(_ name: String) throws -> FASTACollectionGC.Composition {
            let sequence = try XCTUnwrap(sequences.first { $0.name == name }, "\(name) is in the file")
            return try XCTUnwrap(result.compositions[sequence.id], "\(name) has a count")
        }

        for name in ["peptide1", "peptide2", "peptide3"] {
            let peptide = try composition(name)
            XCTAssertFalse(peptide.isNucleotide, "\(name) is a protein record")
            XCTAssertNil(peptide.percent, "\(name) reads a dash, not a GC percent")
            XCTAssertNotNil(peptide.dashToolTip)
        }
        XCTAssertEqual(result.proteinRecordCount, 3)

        // ACGTACGTGG holds 6 G or C of 10, and AUGGCUACGU is stored with T and holds 5 of 10, so the card pools 11 of 20.
        XCTAssertEqual(try XCTUnwrap(composition("dna").percent), 60, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(composition("rna").percent), 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.listPercent), 55, accuracy: 0.0001)
    }
}
