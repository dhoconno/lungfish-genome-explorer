// NaoMgsMateAtBaseZeroTests.swift — A mate placed at the first reference base is a placed mate (NAOMGS-UNALIGNED-MATE-HIT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import Testing
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// `prim_align_ref_start` and `prim_align_ref_start_rev` are 0-based, so 0 is the first base of a reference and `NA` is
/// the file's mark for no alignment. BIO measured 753 of 4,531,741 R2 and 680 of 4,529,490 R1 at base 0 in 30 saved BAMs
/// of one walk clone, and 133 of the 215 R2 in `SRR35517703.third.filt.sorted.bam` (R1-BIO.md, Lane NAO-R2-BASE0).
/// These tests hold what a result built from such rows reads: a mate at base 0 counts, keeps its signature and its
/// interval, and has a BAM record, and a mate with no start counts nothing and has no record.
struct NaoMgsMateAtBaseZeroTests {

    private static let sample = "walk_sample"
    private static let taxId = 82658

    private static let header = [
        "sample", "seq_id", "aligner_taxid_lca", "query_seq", "query_seq_rev", "query_qual", "query_qual_rev",
        "prim_align_genome_id_all", "prim_align_ref_start", "prim_align_ref_start_rev",
        "prim_align_edit_distance", "prim_align_edit_distance_rev", "query_len", "query_len_rev",
        "prim_align_query_rc", "prim_align_query_rc_rev", "prim_align_pair_status",
        "prim_align_best_alignment_score", "prim_align_best_alignment_score_rev", "prim_align_fragment_length",
        "prim_align_cigar", "prim_align_subject_title",
    ].joined(separator: "\t")

    /// One paired row of 8-base mates. A start of nil is written as NA, the file's mark for no alignment.
    private static func row(_ name: String, start: Int?, startRev: Int?) -> String {
        [
            sample, name, String(taxId), "ACGTACGT", "TGCATGCA", "IIIIIIII", "JJJJJJJJ", "X86557.1",
            start.map(String.init) ?? "NA", startRev.map(String.init) ?? "NA",
            "1", "2", "8", "8", "False", "True", "CP", "90", "88", "148", "8M", "Lordsdale virus",
        ].joined(separator: "\t")
    }

    private static func importRows(_ rows: [String], in workspace: URL) async throws -> (db: NaoMgsDatabase, dbURL: URL) {
        let input = workspace.appendingPathComponent("virus_hits_final.tsv")
        let dbURL = workspace.appendingPathComponent("hits.sqlite")
        try ([header] + rows).joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        _ = try await NaoMgsDatabase.createStreaming(at: dbURL, from: [input])
        return (try NaoMgsDatabase(at: dbURL), dbURL)
    }

    /// The stored value of a start column in every row, nil where the column holds NULL.
    private static func startColumn(_ column: String, in dbURL: URL) throws -> [Int?] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsMateAtBaseZeroTests", code: 1)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT \(column) FROM virus_hits ORDER BY seq_id", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsMateAtBaseZeroTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        var values: [Int?] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 0)))
        }
        return values
    }

    /// The `pos` of every record that `samtools view` prints for the sample's BAM, built from the stored rows.
    private static func bamPositions(dbURL: URL, workspace: URL, samtools: String) throws -> [Int] {
        let materialized = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: dbURL.path, resultURL: workspace, samtoolsPath: samtools, lungfishVersion: "test"
        )
        let bam = try #require(materialized.bamURLs.first, "the sample has hits, so a BAM is written")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtools)
        process.arguments = ["view", bam.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            return columns.count > 3 ? Int(columns[3]) : nil
        }
    }

    /// BIO's first red test. The pair has R1 at 0-based 10 and R2 at base 0.
    @Test
    func testPairedRowWithR2AtReferenceBaseZeroKeepsItsSignatureIntervalAndBamRecord() async throws {
        let workspace = try TestTempDirectory.make(prefix: "naomgs-r2-base0")
        defer { TestTempDirectory.cleanup(workspace) }
        let (db, dbURL) = try await Self.importRows([Self.row("read_001", start: 10, startRev: 0)], in: workspace)

        let taxa = try db.fetchTaxonSummaryRows()
        let taxon = try #require(taxa.first)
        #expect(taxon.hitCount == 2, "A mate at the first base is placed, so the pair counts two hits")
        #expect(taxon.uniqueReadCount == 2, "Each placed mate has its own signature, so the pair has two")
        let accessions = try db.fetchAccessionSummaries(sample: Self.sample, taxId: Self.taxId)
        let accession = try #require(accessions.first)
        #expect(accession.readCount == 2, "The accession counts both mates")
        #expect(accession.coveredBasePairs == 16, "R1 covers bases 10 to 18 and R2 covers 0 to 8")
        let stored = try Self.startColumn("ref_start_rev", in: dbURL)
        #expect(stored == [0], "A start of 0 is the first base and is stored, not NULL")

        if let samtools = SamtoolsLocator.locate() {
            let positions = try Self.bamPositions(dbURL: dbURL, workspace: workspace, samtools: samtools)
            #expect(positions.sorted() == [1, 11], "The BAM holds both mates, at POS 11 and POS 1")
        }
    }

    /// BIO's second red test. R2 has a sequence and no alignment, so the row counts one alignment.
    @Test
    func testPairedRowWithSequencedButUnalignedR2CountsOneAlignment() async throws {
        let workspace = try TestTempDirectory.make(prefix: "naomgs-r2-unaligned")
        defer { TestTempDirectory.cleanup(workspace) }
        let (db, dbURL) = try await Self.importRows([Self.row("read_002", start: 10, startRev: nil)], in: workspace)

        let taxa = try db.fetchTaxonSummaryRows()
        let taxon = try #require(taxa.first)
        #expect(taxon.hitCount == 1, "Only R1 is aligned, so the row counts one hit")
        #expect(taxon.uniqueReadCount == 1)
        let stored = try Self.startColumn("ref_start_rev", in: dbURL)
        #expect(stored == [nil], "No start is NULL")

        if let samtools = SamtoolsLocator.locate() {
            let positions = try Self.bamPositions(dbURL: dbURL, workspace: workspace, samtools: samtools)
            #expect(positions == [11], "Only R1 has a BAM record")
        }
    }

    /// SWIFT's mirror for R1. An R1 with a sequence and an NA start must not be counted or written at POS 1.
    @Test
    func testPairedRowWithSequencedButUnalignedR1CountsOneAlignment() async throws {
        let workspace = try TestTempDirectory.make(prefix: "naomgs-r1-unaligned")
        defer { TestTempDirectory.cleanup(workspace) }
        let (db, dbURL) = try await Self.importRows([Self.row("read_003", start: nil, startRev: 240)], in: workspace)

        let taxa = try db.fetchTaxonSummaryRows()
        let taxon = try #require(taxa.first)
        #expect(taxon.hitCount == 1, "Only R2 is aligned, so the row counts one hit")
        let stored = try Self.startColumn("ref_start", in: dbURL)
        #expect(stored == [nil], "No start is NULL, where it was stored as 0")

        if let samtools = SamtoolsLocator.locate() {
            let positions = try Self.bamPositions(dbURL: dbURL, workspace: workspace, samtools: samtools)
            #expect(positions == [241], "Only R2 has a BAM record and none sits at POS 1")
        }
    }

    /// The shape of BIO's measure in `SRR35517703.third.filt.sorted.bam`, 133 of 215 R2 at base 0.
    @Test
    func testSampleWithMostSecondMatesAtBaseZeroKeepsEveryMate() async throws {
        let workspace = try TestTempDirectory.make(prefix: "naomgs-r2-base0-many")
        defer { TestTempDirectory.cleanup(workspace) }
        let rows = (0..<215).map { index in
            Self.row("read_\(index)", start: 1000 + 3 * index, startRev: index < 133 ? 0 : 4000 + 3 * index)
        }
        let (db, dbURL) = try await Self.importRows(rows, in: workspace)

        let taxa = try db.fetchTaxonSummaryRows()
        let taxon = try #require(taxa.first)
        #expect(taxon.hitCount == 430, "215 pairs are 430 mates, the 133 at base 0 included")
        // 215 R1 signatures, one shared by the 133 R2 at base 0, and 82 more for the R2 elsewhere.
        #expect(taxon.uniqueReadCount == 298)
        let accessions = try db.fetchAccessionSummaries(sample: Self.sample, taxId: Self.taxId)
        let accession = try #require(accessions.first)
        #expect(accession.readCount == 430, "Hits and the accession's reads agree")
        let stored = try Self.startColumn("ref_start_rev", in: dbURL)
        #expect(stored.filter { $0 == nil }.isEmpty, "Every R2 has a start")
        #expect(stored.filter { $0 == 0 }.count == 133)

        if let samtools = SamtoolsLocator.locate() {
            let positions = try Self.bamPositions(dbURL: dbURL, workspace: workspace, samtools: samtools)
            #expect(positions.count == 430, "Every mate is in the BAM")
            #expect(positions.filter { $0 == 1 }.count == 133, "133 mates sit at POS 1")
        }
    }
}
