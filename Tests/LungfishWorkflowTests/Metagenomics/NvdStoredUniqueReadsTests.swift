// NvdStoredUniqueReadsTests.swift - A stored 0 beside mapped reads reads back as never counted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ESVUNIQUE, BIO review Blocker 1 (NVD counted Unique Reads on the BLAST subject's name). The import
// asked the BAM for each hit's `sseqid`, but the BAM's references are the contigs (`qseqid`). Samtools prints 0 and
// exits 0 for a reference the BAM does not hold, so a real import stored 0 on every contig. A result imported that way
// still holds the false 0. A stored 0 beside mapped reads reads back as never counted, and a 0 beside no mapped reads
// stays a true 0.

import XCTest
import LungfishIO
import LungfishTestSupport

final class NvdStoredUniqueReadsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "NvdStoredUniqueReads")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at the base, where the stored 0 beside 40 mapped reads reads back as 0.
    func testStoredZeroBesideMappedReadsReadsAsNeverCounted() throws {
        let database = try NvdDatabase.create(
            at: root.appendingPathComponent("hits.sqlite"),
            hits: [
                Self.hit(contig: "contig_false_zero", mapped: 40, unique: 0),
                Self.hit(contig: "contig_true_zero", mapped: 0, unique: 0),
                Self.hit(contig: "contig_counted", mapped: 40, unique: 31),
                Self.hit(contig: "contig_never", mapped: 40, unique: nil),
            ],
            samples: [NvdSampleMetadata(
                sampleId: "S1", bamPath: "S1.bam", fastaPath: "S1.fasta", totalReads: 1_000, contigCount: 4, hitCount: 4
            )]
        )
        let hits = try database.bestHits(forSamples: ["S1"])
        func stored(_ contig: String) throws -> Int? {
            try XCTUnwrap(hits.first { $0.qseqid == contig }, "the database holds \(contig)").uniqueReads
        }
        XCTAssertNil(try stored("contig_false_zero"),
                     "0 beside 40 mapped reads came from the old count on the subject name, so it was never counted")
        XCTAssertEqual(try stored("contig_true_zero"), 0, "0 beside no mapped reads is a true 0")
        XCTAssertEqual(try stored("contig_counted"), 31)
        XCTAssertNil(try stored("contig_never"))
    }

    private static func hit(contig: String, mapped: Int, unique: Int?) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-stored", blastTask: "blastn", sampleId: "S1", qseqid: contig, qlen: 120,
            sseqid: "NC_\(contig)", stitle: "Synthetic virus", taxRank: "species", length: 118, pident: 99.2,
            evalue: 0, bitscore: 50, sscinames: "Synthetic virus", staxids: "1234", blastDbVersion: "db",
            snakemakeRunId: "run-1", mappedReads: mapped, uniqueReads: unique, totalReads: 1_000,
            statDbVersion: "stats-1", adjustedTaxid: "1234", adjustmentMethod: "dominant",
            adjustedTaxidName: "Synthetic virus", adjustedTaxidRank: "species", hitRank: 1,
            readsPerBillion: Double(mapped) * 1_000_000
        )
    }
}
