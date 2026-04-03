// NvdResultParserTests.swift - Tests for NvdResultParser
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishIO

final class NvdResultParserTests: XCTestCase {

    private let parser = NvdResultParser()

    // MARK: - 1. Full fixture parse

    func testParseFixtureCSV() async throws {
        let result = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV)

        XCTAssertEqual(result.hits.count, 10, "Expected 10 hits total")
        XCTAssertEqual(result.experiment, "100")
        XCTAssertEqual(result.sampleIds, ["SampleA", "SampleB", "SampleC"])
    }

    // MARK: - 2. All columns parsed for first hit

    func testParsesAllColumns() async throws {
        let result = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV)
        let hit = try XCTUnwrap(result.hits.first)

        XCTAssertEqual(hit.experiment, "100")
        XCTAssertEqual(hit.blastTask, "megablast")
        XCTAssertEqual(hit.sampleId, "SampleA")
        XCTAssertEqual(hit.qseqid, "NODE_1_length_500_cov_10.0")
        XCTAssertEqual(hit.qlen, 500)
        XCTAssertEqual(hit.sseqid, "NC_045512.2")
        XCTAssertEqual(hit.taxRank, "species:SARS-CoV-2")
        XCTAssertEqual(hit.length, 498)
        XCTAssertEqual(hit.pident, 99.5, accuracy: 0.001)
        XCTAssertEqual(hit.evalue, 0.0, accuracy: 1e-10)
        XCTAssertEqual(hit.bitscore, 920.0, accuracy: 0.001)
        XCTAssertEqual(hit.sscinames, "SARS-CoV-2")
        XCTAssertEqual(hit.staxids, "2697049")
        XCTAssertEqual(hit.blastDbVersion, "2.5.0")
        XCTAssertEqual(hit.snakemakeRunId, "test_run")
        XCTAssertEqual(hit.mappedReads, 50)
        XCTAssertEqual(hit.totalReads, 1_000_000)
        XCTAssertEqual(hit.statDbVersion, "2.5.0")
        XCTAssertEqual(hit.adjustedTaxid, "2697049")
        XCTAssertEqual(hit.adjustmentMethod, "dominant")
        XCTAssertEqual(hit.adjustedTaxidName, "SARS-CoV-2")
        XCTAssertEqual(hit.adjustedTaxidRank, "species")
    }

    // MARK: - 3. Hit ranking by e-value

    func testComputesHitRankByEvalue() async throws {
        let result = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV)

        // SampleA NODE_1: 3 hits, evlues 0.0, 1e-200, 1e-180 → ranks 1, 2, 3
        // Because 0.0 < 1e-200 < 1e-180 (but 0.0 and 1e-200 are not equal, 0.0 is lowest)
        let node1Hits = result.hits
            .filter { $0.sampleId == "SampleA" && $0.qseqid == "NODE_1_length_500_cov_10.0" }
            .sorted { $0.hitRank < $1.hitRank }

        XCTAssertEqual(node1Hits.count, 3)
        XCTAssertEqual(node1Hits[0].hitRank, 1)
        XCTAssertEqual(node1Hits[0].sseqid, "NC_045512.2", "Rank 1 should be the hit with evalue=0.0")
        XCTAssertEqual(node1Hits[1].hitRank, 2)
        XCTAssertEqual(node1Hits[1].sseqid, "MW123456.1", "Rank 2 should have evalue=1e-200")
        XCTAssertEqual(node1Hits[2].hitRank, 3)
        XCTAssertEqual(node1Hits[2].sseqid, "MW789012.1", "Rank 3 should have evalue=1e-180")

        // SampleA NODE_2: 5 hits with distinct evalues → ranks 1-5
        let node2Hits = result.hits
            .filter { $0.sampleId == "SampleA" && $0.qseqid == "NODE_2_length_300_cov_5.0" }
            .sorted { $0.hitRank < $1.hitRank }

        XCTAssertEqual(node2Hits.count, 5)
        XCTAssertEqual(node2Hits.map(\.hitRank), [1, 2, 3, 4, 5])
        // Ranks should be ordered by evalue ascending
        for i in 0..<(node2Hits.count - 1) {
            XCTAssertLessThanOrEqual(node2Hits[i].evalue, node2Hits[i + 1].evalue)
        }
    }

    // MARK: - 4. Single hit gets rank 1

    func testSingleHitContigGetsRankOne() async throws {
        let result = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV)

        let sampleBHits = result.hits.filter { $0.sampleId == "SampleB" }
        XCTAssertEqual(sampleBHits.count, 1)
        XCTAssertEqual(sampleBHits[0].hitRank, 1, "A contig with a single hit must get rank 1")
    }

    // MARK: - 5. Reads per billion calculation

    func testComputesReadsPerBillion() async throws {
        let result = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV)

        // SampleA NODE_1: 50 mapped / 1,000,000 total * 1e9 = 50,000
        let node1Hit = try XCTUnwrap(
            result.hits.first { $0.sampleId == "SampleA" && $0.qseqid == "NODE_1_length_500_cov_10.0" }
        )
        XCTAssertEqual(node1Hit.readsPerBillion, 50_000.0, accuracy: 0.01)

        // SampleC: 10 mapped / 500,000 total * 1e9 = 20,000
        let sampleCHit = try XCTUnwrap(result.hits.first { $0.sampleId == "SampleC" })
        XCTAssertEqual(sampleCHit.readsPerBillion, 20_000.0, accuracy: 0.01)
    }

    // MARK: - 6. blastn task parsed correctly

    func testParsesBlastnTask() async throws {
        let result = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV)

        let blastnHits = result.hits.filter { $0.blastTask == "blastn" }
        XCTAssertEqual(blastnHits.count, 1, "Expected exactly 1 blastn hit (SampleC)")
        XCTAssertEqual(blastnHits[0].sampleId, "SampleC")
        XCTAssertEqual(blastnHits[0].sseqid, "KX123456.1")
    }

    // MARK: - 7. Quoted stitle with internal commas

    func testHandlesQuotedStitle() async throws {
        let result = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV)

        let hit = try XCTUnwrap(
            result.hits.first { $0.sseqid == "NC_045512.2" }
        )
        // stitle is "SARS-CoV-2 isolate Wuhan-Hu-1, complete genome" — contains a comma
        XCTAssertTrue(
            hit.stitle.contains(","),
            "stitle should preserve the internal comma from the quoted CSV field"
        )
        XCTAssertEqual(hit.stitle, "SARS-CoV-2 isolate Wuhan-Hu-1, complete genome")
    }

    // MARK: - 8. Accession extraction from gi| format

    func testExtractsAccessionFromSseqid() async throws {
        let result = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV)

        // gi|123|gb|NC_045512.2| should become NC_045512.2
        let hit = try XCTUnwrap(result.hits.first { $0.qseqid == "NODE_1_length_500_cov_10.0" })
        XCTAssertEqual(hit.sseqid, "NC_045512.2")

        // gi|999|gb|KX123456.1| should become KX123456.1
        let cHit = try XCTUnwrap(result.hits.first { $0.sampleId == "SampleC" })
        XCTAssertEqual(cHit.sseqid, "KX123456.1")

        // Verify no raw gi| prefix remains in any hit
        for h in result.hits {
            XCTAssertFalse(h.sseqid.hasPrefix("gi|"), "sseqid should not contain raw gi| prefix")
        }
    }

    // MARK: - 9. Empty file throws

    func testEmptyFileThrows() async throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd_empty_\(UUID().uuidString).csv")
        try "".write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            _ = try await parser.parse(at: tmpURL)
            XCTFail("Expected NvdParserError to be thrown for empty file")
        } catch let error as NvdParserError {
            // Any NvdParserError is acceptable
            _ = error
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - 10. Header-only file returns empty result

    func testHeaderOnlyFileReturnsEmptyResult() async throws {
        let header = "experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd_header_only_\(UUID().uuidString).csv")
        try header.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let result = try await parser.parse(at: tmpURL)
        XCTAssertTrue(result.hits.isEmpty, "Header-only file should produce zero hits")
        XCTAssertEqual(result.experiment, "")
        XCTAssertTrue(result.sampleIds.isEmpty)
    }

    // MARK: - 11. Progress callback is invoked

    func testReportsLineProgress() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        _ = try await parser.parse(at: TestFixtures.nvd.blastConcatenatedCSV) { _ in
            callCount.withLock { $0 += 1 }
        }
        XCTAssertGreaterThan(callCount.withLock { $0 }, 0, "lineProgress callback should be called at least once")
    }
}
