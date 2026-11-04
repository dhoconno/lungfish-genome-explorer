// NvdContigsExportUniqueReadsTests.swift - The NVD contigs export writes Unique Reads and the alignment length
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ESVUNIQUE, owner direction O143 and BIO review Blocker 3 and Ruling 3. The NVD table shows Mapped
// Reads, Unique Reads and Aln Length, and the contigs export wrote the first and neither of the other two. The export
// writes `unique_reads` right after `mapped_reads`, empty when the count was never computed, and `aln_length` right
// after `pident`. The file's `length` is the contig's length and keeps its name.

import XCTest
import LungfishIO
import LungfishWorkflow

final class NvdContigsExportUniqueReadsTests: XCTestCase {
    private static func hit(
        contig: String,
        mapped: Int,
        unique: Int?,
        alignmentLength: Int = 118,
        contigLength: Int = 120
    ) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-unique", blastTask: "blastn", sampleId: "S1", qseqid: contig, qlen: contigLength,
            sseqid: "NC_\(contig)", stitle: "Synthetic virus", taxRank: "species", length: alignmentLength,
            pident: 99.2, evalue: 0, bitscore: 50, sscinames: "Synthetic virus", staxids: "1234",
            blastDbVersion: "db", snakemakeRunId: "run-1", mappedReads: mapped, uniqueReads: unique,
            totalReads: 1_000, statDbVersion: "stats-1", adjustedTaxid: "1234", adjustmentMethod: "dominant",
            adjustedTaxidName: "Synthetic virus", adjustedTaxidRank: "species", hitRank: 1,
            readsPerBillion: Double(mapped) * 1_000_000
        )
    }

    /// The file the viewer's Export and the leaf write for `hits`, split into the header and the cells of each row.
    private func exported(_ hits: [NvdBlastHit]) -> (header: [String], lines: [[String]]) {
        let text = NvdContigsExport.contigsTSV(hits: hits, metadataHeaders: [], metadataValuesBySample: [:])
        let rows = text.split(separator: "\n").map { $0.components(separatedBy: "\t") }
        return (rows.first ?? [], Array(rows.dropFirst()))
    }

    func testContigsExportWritesUniqueReadsBesideMappedReads() throws {
        let table = exported([Self.hit(contig: "contig-1", mapped: 40, unique: 31)])
        let mapped = try XCTUnwrap(table.header.firstIndex(of: "mapped_reads"), "the export header holds mapped_reads")
        let unique = try XCTUnwrap(table.header.firstIndex(of: "unique_reads"), "the export header holds unique_reads")
        XCTAssertEqual(unique, mapped + 1, "unique_reads sits right after mapped_reads")
        let line = try XCTUnwrap(table.lines.first)
        XCTAssertEqual(line[mapped], "40")
        XCTAssertEqual(line[unique], "31", "the contig's own count, not its mapped reads")
    }

    func testContigsExportLeavesUniqueReadsEmptyWhenItWasNeverCounted() throws {
        let table = exported([
            Self.hit(contig: "contig-never", mapped: 40, unique: nil),
            Self.hit(contig: "contig-none", mapped: 0, unique: 0),
        ])
        let unique = try XCTUnwrap(table.header.firstIndex(of: "unique_reads"), "the export header holds unique_reads")
        let byContig = Dictionary(uniqueKeysWithValues: table.lines.map { ($0[1], $0[unique]) })
        XCTAssertEqual(byContig["contig-never"], "", "a count never computed writes an empty cell, never 0 or 1")
        XCTAssertEqual(byContig["contig-none"], "0", "a computed 0 beside no mapped reads writes 0")
    }

    func testContigsExportWritesTheAlignmentLength() throws {
        let table = exported([
            Self.hit(contig: "contig-1", mapped: 40, unique: 31, alignmentLength: 118, contigLength: 120),
        ])
        let pident = try XCTUnwrap(table.header.firstIndex(of: "pident"))
        let alignment = try XCTUnwrap(table.header.firstIndex(of: "aln_length"), "the export header holds aln_length")
        let length = try XCTUnwrap(table.header.firstIndex(of: "length"))
        XCTAssertEqual(alignment, pident + 1, "aln_length sits right after pident")
        let line = try XCTUnwrap(table.lines.first)
        XCTAssertEqual(line[alignment], "118", "aln_length is the BLAST alignment length of the row's hit")
        XCTAssertEqual(line[length], "120", "length keeps its name and holds the contig's length")
    }
}
