// NaoMgsUniqueReadCountPairKeyTests.swift - A mate is a duplicate only when its whole pair is one (NAOMGS-DEDUP-READ-COUNT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport

/// The streaming import counts one hit for each placed mate, and its unique reads are the placed mates that no earlier
/// pair repeats. It keyed each mate on its own accession, start, strand and length, so two distinct pairs that shared one
/// mate lost that mate from the unique count, though only a whole pair that repeats is a PCR duplicate. A mate now keys on
/// its whole pair (the accession, both starts, both strands and both lengths), as `NaoMgsDatabase+Summaries.swift` keys a
/// pair for `create(at:hits:)`, so a mate is a duplicate only when its pair is one. A lone placed mate keys alone.
final class NaoMgsUniqueReadCountPairKeyTests: XCTestCase {
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

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "naomgs-pair-key")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// One paired row of 8-base mates on one accession, R1 forward and R2 reverse. A start of nil is written as NA, the
    /// file's mark for a mate with a sequence and no alignment, so the row has one placed mate.
    private static func row(_ name: String, start: Int?, startRev: Int?) -> String {
        [
            sample, name, String(taxId), "ACGTACGT", "TGCATGCA", "IIIIIIII", "JJJJJJJJ", "X86557.1",
            start.map(String.init) ?? "NA", startRev.map(String.init) ?? "NA",
            "1", "2", "8", "8", "False", "True", "CP", "90", "88", "148", "8M", "Lordsdale virus",
        ].joined(separator: "\t")
    }

    /// The taxon's hits and unique reads and its accession's unique reads, from a database built from `rows`.
    private func importCounts(_ rows: [String]) async throws -> (hits: Int, unique: Int, accessionUnique: Int) {
        let input = root.appendingPathComponent("virus_hits_final.tsv")
        let dbURL = root.appendingPathComponent("hits.sqlite")
        try Data(([Self.header] + rows).joined(separator: "\n").utf8).write(to: input)
        _ = try await NaoMgsDatabase.createStreaming(at: dbURL, from: [input])
        let db = try NaoMgsDatabase(at: dbURL)
        let taxon = try XCTUnwrap(try db.fetchTaxonSummaryRows().first, "the sample has hits")
        let accession = try XCTUnwrap(
            try db.fetchAccessionSummaries(sample: Self.sample, taxId: Self.taxId).first, "the taxon has an accession"
        )
        return (taxon.hitCount, taxon.uniqueReadCount, accession.uniqueReadCount)
    }

    /// Red at the base, with 3 unique reads. The two pairs share R1's accession, start, strand and length and differ in R2,
    /// so they are two fragments, and neither of the four mates is a duplicate.
    func testUniqueReadCountKeepsTwoFragmentsThatShareAMate() async throws {
        let counts = try await importCounts([
            Self.row("fragment_a", start: 100, startRev: 400),
            Self.row("fragment_b", start: 100, startRev: 700),
        ])

        XCTAssertEqual(counts.hits, 4, "two pairs of two placed mates")
        XCTAssertEqual(counts.unique, 4, "R1 of fragment_b shares its place with R1 of fragment_a, but its pair differs")
        XCTAssertEqual(counts.accessionUnique, 4, "the accession counts the same four reads")
    }

    /// Green at the base and after the change. A whole pair that repeats is a PCR duplicate, so its two mates are
    /// duplicates and the unique reads are the two mates of the first pair.
    func testUniqueReadCountStillCollapsesAWholePairThatRepeats() async throws {
        let counts = try await importCounts([
            Self.row("fragment_a", start: 100, startRev: 400),
            Self.row("fragment_b", start: 100, startRev: 400),
        ])

        XCTAssertEqual(counts.hits, 4, "two pairs of two placed mates")
        XCTAssertEqual(counts.unique, 2, "the second pair repeats the first, so both of its mates are duplicates")
        XCTAssertEqual(counts.accessionUnique, 2, "the accession counts the same two reads")
    }

    /// Red at the base, with 2 unique reads. A row whose R2 has no alignment has one placed mate and keys on that mate
    /// alone, so two such rows repeat each other, and neither repeats R1 of a pair, whose key holds R2 as well.
    func testALonePlacedMateKeysAlone() async throws {
        let counts = try await importCounts([
            Self.row("lone_a", start: 100, startRev: nil),
            Self.row("lone_b", start: 100, startRev: nil),
            Self.row("fragment_c", start: 100, startRev: 400),
        ])

        XCTAssertEqual(counts.hits, 4, "two lone mates and a pair of two")
        XCTAssertEqual(counts.unique, 3, "one lone mate, as lone_b repeats lone_a, and the two mates of fragment_c")
        XCTAssertEqual(counts.accessionUnique, 3, "the accession counts the same three reads")
    }
}
