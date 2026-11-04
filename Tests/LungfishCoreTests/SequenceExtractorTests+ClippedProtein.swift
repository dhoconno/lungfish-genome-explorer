// SequenceExtractorTests+ClippedProtein.swift - A protein copied from a CDS that the sequence end clips says so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// Phase 3.2 row FASTA-CLAMPED-TRUNCATED, the extractor's two clipboard routes (the annotation menu's copy
/// translation as FASTA and the extraction dialog's protein to clipboard). Both put `formatProteinFASTA` on the
/// pasteboard, so the note about a clip rides in the header of that record. The letters of the protein do not change.
///
/// The CDS names 30 plus-strand bases, ATG GCT AAA CGT TGG CAT GAA TTC CCG GAT, which read whole give MAKRWHEFPD.
/// This extension has its own file because `SequenceExtractorTests.swift` is 17 lines short of the 800 line limit.
extension SequenceExtractorTests {

    private static let thirtyCodingBases = "ATGGCTAAACGTTGGCATGAATTCCCGGAT"

    /// Extracts the 30 base CDS from a chromosome that holds only its first `chromosomeLength` bases.
    private func extractTheCDS(chromosomeLength: Int) throws -> ExtractionResult {
        let genome = Array(Self.thirtyCodingBases.prefix(chromosomeLength))
        let provider: SequenceExtractor.SequenceProvider = { _, start, end in
            guard start >= 0, start < end, end <= genome.count else { return nil }
            return String(genome[start..<end])
        }
        let cds = SequenceAnnotation(
            type: .cds, name: "ClippedCDS", chromosome: "chr1", start: 0, end: 30, strand: .forward
        )
        return try SequenceExtractor.extract(
            request: ExtractionRequest(source: .annotation(cds)),
            sequenceProvider: provider,
            chromosomeLength: chromosomeLength
        )
    }

    /// The first line of the protein record and the letters under it.
    private func proteinRecord(of result: ExtractionResult) throws -> (header: String, letters: String) {
        let fasta = try XCTUnwrap(SequenceExtractor.formatProteinFASTA(result))
        let lines = fasta.split(separator: "\n")
        let header = try XCTUnwrap(lines.first)
        return (String(header), lines.dropFirst().joined())
    }

    func testProteinFASTASaysWhenTheSequenceEndClipsTheCDS() throws {
        let result = try extractTheCDS(chromosomeLength: 20)
        let record = try proteinRecord(of: result)

        XCTAssertTrue(record.header.contains("translated from 20 of 30 coding bases"), record.header)
        XCTAssertEqual(result.proteinSequence, "MAKRWH")
        XCTAssertEqual(record.letters, "MAKRWH", "The letters are those of the bases that were read")
    }

    func testProteinFASTAHeaderIsUnchangedForACDSReadWhole() throws {
        let result = try extractTheCDS(chromosomeLength: 30)
        let record = try proteinRecord(of: result)

        XCTAssertEqual(record.header, ">" + result.fastaHeader + " [protein]")
        XCTAssertEqual(record.letters, "MAKRWHEFPD")
    }
}
