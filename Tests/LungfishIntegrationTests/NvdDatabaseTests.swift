// NvdDatabaseTests.swift — Tests for NvdDatabase schema and queries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO

struct NvdDatabaseTests {

    // MARK: - Test Data

    /// Builds synthetic test data: 2 samples × 3 contigs, 6 total hits (2 per contig, hit_rank 1 and 2).
    ///
    /// Layout:
    ///   sample_A: NODE_1 (SARS-CoV-2, rank1 + rank2), NODE_2 (Influenza A, rank1 only)
    ///   sample_B: NODE_3 (SARS-CoV-2, rank1 + rank2)
    private func makeSyntheticHits() -> [NvdBlastHit] {
        [
            // sample_A / NODE_1 — rank 1 (better evalue)
            NvdBlastHit(
                experiment: "100",
                blastTask: "megablast",
                sampleId: "sample_A",
                qseqid: "NODE_1_length_500_cov_10.0",
                qlen: 500,
                sseqid: "NC_045512.2",
                stitle: "Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1",
                taxRank: "species:SARS-CoV-2",
                length: 480,
                pident: 99.6,
                evalue: 0.0,
                bitscore: 850.0,
                sscinames: "Severe acute respiratory syndrome coronavirus 2",
                staxids: "2697049",
                blastDbVersion: "v5.0",
                snakemakeRunId: "run_001",
                mappedReads: 1000,
                totalReads: 100_000,
                statDbVersion: "stat_v1",
                adjustedTaxid: "2697049",
                adjustmentMethod: "dominant",
                adjustedTaxidName: "SARS-CoV-2",
                adjustedTaxidRank: "species",
                hitRank: 1,
                readsPerBillion: 10_000_000.0
            ),
            // sample_A / NODE_1 — rank 2 (worse evalue)
            NvdBlastHit(
                experiment: "100",
                blastTask: "megablast",
                sampleId: "sample_A",
                qseqid: "NODE_1_length_500_cov_10.0",
                qlen: 500,
                sseqid: "MN908947.3",
                stitle: "Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1 complete genome",
                taxRank: "species:SARS-CoV-2",
                length: 450,
                pident: 98.0,
                evalue: 1e-50,
                bitscore: 700.0,
                sscinames: "Severe acute respiratory syndrome coronavirus 2",
                staxids: "2697049",
                blastDbVersion: "v5.0",
                snakemakeRunId: "run_001",
                mappedReads: 1000,
                totalReads: 100_000,
                statDbVersion: "stat_v1",
                adjustedTaxid: "2697049",
                adjustmentMethod: "dominant",
                adjustedTaxidName: "SARS-CoV-2",
                adjustedTaxidRank: "species",
                hitRank: 2,
                readsPerBillion: 10_000_000.0
            ),
            // sample_A / NODE_2 — rank 1 only (different taxon)
            NvdBlastHit(
                experiment: "100",
                blastTask: "megablast",
                sampleId: "sample_A",
                qseqid: "NODE_2_length_300_cov_5.0",
                qlen: 300,
                sseqid: "CY114381.1",
                stitle: "Influenza A virus (A/California/07/2009(H1N1)) segment 4",
                taxRank: "species:Influenza A",
                length: 290,
                pident: 97.5,
                evalue: 1e-100,
                bitscore: 550.0,
                sscinames: "Influenza A virus",
                staxids: "11520",
                blastDbVersion: "v5.0",
                snakemakeRunId: "run_001",
                mappedReads: 500,
                totalReads: 100_000,
                statDbVersion: "stat_v1",
                adjustedTaxid: "11520",
                adjustmentMethod: "dominant",
                adjustedTaxidName: "Influenza A virus",
                adjustedTaxidRank: "species",
                hitRank: 1,
                readsPerBillion: 5_000_000.0
            ),
            // sample_B / NODE_3 — rank 1
            NvdBlastHit(
                experiment: "100",
                blastTask: "megablast",
                sampleId: "sample_B",
                qseqid: "NODE_3_length_400_cov_8.0",
                qlen: 400,
                sseqid: "NC_045512.2",
                stitle: "Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1",
                taxRank: "species:SARS-CoV-2",
                length: 390,
                pident: 99.0,
                evalue: 0.0,
                bitscore: 780.0,
                sscinames: "Severe acute respiratory syndrome coronavirus 2",
                staxids: "2697049",
                blastDbVersion: "v5.0",
                snakemakeRunId: "run_001",
                mappedReads: 800,
                totalReads: 80_000,
                statDbVersion: "stat_v1",
                adjustedTaxid: "2697049",
                adjustmentMethod: "dominant",
                adjustedTaxidName: "SARS-CoV-2",
                adjustedTaxidRank: "species",
                hitRank: 1,
                readsPerBillion: 10_000_000.0
            ),
            // sample_B / NODE_3 — rank 2
            NvdBlastHit(
                experiment: "100",
                blastTask: "megablast",
                sampleId: "sample_B",
                qseqid: "NODE_3_length_400_cov_8.0",
                qlen: 400,
                sseqid: "MN908947.3",
                stitle: "Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1 complete genome",
                taxRank: "species:SARS-CoV-2",
                length: 360,
                pident: 97.0,
                evalue: 1e-80,
                bitscore: 620.0,
                sscinames: "Severe acute respiratory syndrome coronavirus 2",
                staxids: "2697049",
                blastDbVersion: "v5.0",
                snakemakeRunId: "run_001",
                mappedReads: 800,
                totalReads: 80_000,
                statDbVersion: "stat_v1",
                adjustedTaxid: "2697049",
                adjustmentMethod: "dominant",
                adjustedTaxidName: "SARS-CoV-2",
                adjustedTaxidRank: "species",
                hitRank: 2,
                readsPerBillion: 10_000_000.0
            ),
            // Extra hit: sample_A / NODE_2 rank 2 (to give NODE_2 a child hit)
            NvdBlastHit(
                experiment: "100",
                blastTask: "blastn",
                sampleId: "sample_A",
                qseqid: "NODE_2_length_300_cov_5.0",
                qlen: 300,
                sseqid: "NC_026433.1",
                stitle: "Influenza A virus segment 4, partial",
                taxRank: "species:Influenza A",
                length: 270,
                pident: 95.0,
                evalue: 1e-60,
                bitscore: 430.0,
                sscinames: "Influenza A virus",
                staxids: "11520",
                blastDbVersion: "v5.0",
                snakemakeRunId: "run_001",
                mappedReads: 500,
                totalReads: 100_000,
                statDbVersion: "stat_v1",
                adjustedTaxid: "11520",
                adjustmentMethod: "dominant",
                adjustedTaxidName: "Influenza A virus",
                adjustedTaxidRank: "species",
                hitRank: 2,
                readsPerBillion: 5_000_000.0
            ),
        ]
    }

    private func makeSyntheticSamples() -> [NvdSampleMetadata] {
        [
            NvdSampleMetadata(
                sampleId: "sample_A",
                bamPath: "samples/sample_A/sample_A.sorted.bam",
                fastaPath: "samples/sample_A/sample_A_contigs.fasta",
                totalReads: 100_000,
                contigCount: 2,
                hitCount: 4
            ),
            NvdSampleMetadata(
                sampleId: "sample_B",
                bamPath: "samples/sample_B/sample_B.sorted.bam",
                fastaPath: "samples/sample_B/sample_B_contigs.fasta",
                totalReads: 80_000,
                contigCount: 1,
                hitCount: 2
            ),
        ]
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd_test_\(UUID().uuidString).sqlite")
    }

    // MARK: - Tests

    @Test
    func createDatabaseInsertsAllHits() throws {
        let hits = makeSyntheticHits()
        #expect(hits.count == 6)

        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(at: url, hits: hits, samples: makeSyntheticSamples())
        let count = try db.totalHitCount()
        #expect(count == 6, "All 6 hits should be in the database")
    }

    @Test
    func createDatabaseInsertsSampleMetadata() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        let samples = try db.allSamples()
        #expect(samples.count == 2)

        let sampleA = try #require(samples.first(where: { $0.sampleId == "sample_A" }))
        #expect(sampleA.totalReads == 100_000)
        #expect(sampleA.contigCount == 2)
        #expect(sampleA.hitCount == 4)

        let sampleB = try #require(samples.first(where: { $0.sampleId == "sample_B" }))
        #expect(sampleB.totalReads == 80_000)
        #expect(sampleB.contigCount == 1)
        #expect(sampleB.hitCount == 2)
    }

    @Test
    func queryBestHitsReturnsRankOne() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        // All samples: 3 contigs total, each should have exactly one best hit
        let best = try db.bestHits(forSamples: ["sample_A", "sample_B"])
        #expect(best.count == 3, "3 distinct contigs → 3 best hits")
        #expect(best.allSatisfy { $0.hitRank == 1 }, "All returned hits must be rank 1")
    }

    @Test
    func queryChildHitsForContig() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        let children = try db.childHits(
            sampleId: "sample_A",
            qseqid: "NODE_1_length_500_cov_10.0"
        )
        #expect(children.count == 2, "NODE_1 should have 2 hits (rank 1 and rank 2)")

        // Ordered by evalue ascending: rank 1 (0.0) before rank 2 (1e-50)
        #expect(children[0].hitRank == 1)
        #expect(children[1].hitRank == 2)
        #expect(children[0].evalue <= children[1].evalue)
    }

    @Test
    func querySampleFiltering() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        let countA = try db.totalHitCount(samples: ["sample_A"])
        #expect(countA == 4, "sample_A has 4 hits (NODE_1 rank1+2, NODE_2 rank1+2)")

        let countB = try db.totalHitCount(samples: ["sample_B"])
        #expect(countB == 2, "sample_B has 2 hits (NODE_3 rank1+2)")

        let countBoth = try db.totalHitCount(samples: ["sample_A", "sample_B"])
        #expect(countBoth == 6)
    }

    @Test
    func queryTaxonGrouping() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        let groups = try db.taxonGroups(forSamples: ["sample_A", "sample_B"])
        // Best hits: NODE_1→SARS-CoV-2, NODE_2→Influenza A, NODE_3→SARS-CoV-2
        // Grouped: SARS-CoV-2 (2 contigs), Influenza A (1 contig)
        #expect(groups.count == 2)

        let sarsCov2 = try #require(groups.first(where: { $0.adjustedTaxidName == "SARS-CoV-2" }))
        #expect(sarsCov2.contigCount == 2, "SARS-CoV-2 has NODE_1 and NODE_3")
        #expect(sarsCov2.totalMappedReads == 1800, "1000 (NODE_1) + 800 (NODE_3)")

        let influenza = try #require(groups.first(where: { $0.adjustedTaxidName == "Influenza A virus" }))
        #expect(influenza.contigCount == 1)
        #expect(influenza.totalMappedReads == 500)
    }

    @Test
    func searchByTaxonName() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        let results = try db.searchBestHits(query: "SARS", samples: ["sample_A", "sample_B"])
        // 2 best hits with SARS-CoV-2: NODE_1 (sample_A) and NODE_3 (sample_B)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.adjustedTaxidName.contains("SARS") })
    }

    @Test
    func searchByAccession() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        // NC_045512.2 is the best hit for NODE_1 and NODE_3
        let results = try db.searchBestHits(query: "NC_045512", samples: ["sample_A", "sample_B"])
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.sseqid.contains("NC_045512") })
    }

    @Test
    func searchBestHitsEscapesLikeWildcards() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let hits = makeSyntheticHits() + [
            NvdBlastHit(
                experiment: "100",
                blastTask: "megablast",
                sampleId: "sample_A",
                qseqid: "NODEX1_length_250_cov_1.0",
                qlen: 250,
                sseqid: "NCX045512.2",
                stitle: "Wildcard impostor for NCX045512.2",
                taxRank: "species:Wildcard",
                length: 240,
                pident: 92.0,
                evalue: 1e-20,
                bitscore: 300.0,
                sscinames: "Wildcard virus",
                staxids: "999001",
                blastDbVersion: "v5.0",
                snakemakeRunId: "run_001",
                mappedReads: 50,
                totalReads: 100_000,
                statDbVersion: "stat_v1",
                adjustedTaxid: "999001",
                adjustmentMethod: "dominant",
                adjustedTaxidName: "NCX045512 impostor",
                adjustedTaxidRank: "species",
                hitRank: 1,
                readsPerBillion: 500_000.0
            ),
            NvdBlastHit(
                experiment: "100",
                blastTask: "megablast",
                sampleId: "sample_A",
                qseqid: #"path\contig"#,
                qlen: 200,
                sseqid: "BK000001.1",
                stitle: #"Backslash path\contig virus"#,
                taxRank: "species:Backslash",
                length: 190,
                pident: 91.0,
                evalue: 1e-10,
                bitscore: 250.0,
                sscinames: "Backslash virus",
                staxids: "999002",
                blastDbVersion: "v5.0",
                snakemakeRunId: "run_001",
                mappedReads: 40,
                totalReads: 100_000,
                statDbVersion: "stat_v1",
                adjustedTaxid: "999002",
                adjustmentMethod: "dominant",
                adjustedTaxidName: #"Path\Virus"#,
                adjustedTaxidRank: "species",
                hitRank: 1,
                readsPerBillion: 400_000.0
            ),
        ]

        let db = try NvdDatabase.create(
            at: url,
            hits: hits,
            samples: makeSyntheticSamples()
        )

        let accessionResults = try db.searchBestHits(query: "NC_045512", samples: ["sample_A", "sample_B"])
        #expect(accessionResults.count == 2)
        #expect(accessionResults.allSatisfy { $0.sseqid == "NC_045512.2" })

        let contigResults = try db.searchBestHits(query: "NODE_1", samples: ["sample_A"])
        #expect(contigResults.map(\.qseqid) == ["NODE_1_length_500_cov_10.0"])

        let percentResults = try db.searchBestHits(query: "%", samples: ["sample_A", "sample_B"])
        #expect(percentResults.isEmpty)

        let backslashResults = try db.searchBestHits(query: #"path\contig"#, samples: ["sample_A"])
        #expect(backslashResults.map(\.qseqid) == [#"path\contig"#])
    }

    @Test
    func searchByContigName() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        let results = try db.searchBestHits(query: "NODE_2", samples: ["sample_A"])
        #expect(results.count == 1)
        #expect(results[0].qseqid.contains("NODE_2"))
    }

    @Test
    func sampleBamPath() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        let bamA = try db.bamPath(forSample: "sample_A")
        #expect(bamA == "samples/sample_A/sample_A.sorted.bam")

        let bamB = try db.bamPath(forSample: "sample_B")
        #expect(bamB == "samples/sample_B/sample_B.sorted.bam")

        let bamMissing = try db.bamPath(forSample: "nonexistent")
        #expect(bamMissing == nil)
    }

    @Test
    func readsPerBillionStoredCorrectly() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        // NODE_1 sample_A: 1000 mapped / 100_000 total × 1e9 = 10_000_000.0
        let nodeOneHits = try db.childHits(
            sampleId: "sample_A",
            qseqid: "NODE_1_length_500_cov_10.0"
        )
        #expect(!nodeOneHits.isEmpty)
        for hit in nodeOneHits {
            #expect(hit.readsPerBillion == 10_000_000.0)
        }

        // NODE_2 sample_A: 500 / 100_000 × 1e9 = 5_000_000.0
        let nodeTwoHits = try db.childHits(
            sampleId: "sample_A",
            qseqid: "NODE_2_length_300_cov_5.0"
        )
        #expect(!nodeTwoHits.isEmpty)
        for hit in nodeTwoHits {
            #expect(hit.readsPerBillion == 5_000_000.0)
        }
    }

    @Test
    func reopensDatabaseReadOnly() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Create and immediately discard the write-mode instance
        _ = try NvdDatabase.create(
            at: url,
            hits: makeSyntheticHits(),
            samples: makeSyntheticSamples()
        )

        // Reopen read-only
        let readDb = try NvdDatabase(at: url)

        let count = try readDb.totalHitCount()
        #expect(count == 6, "Read-only reopen should see all 6 hits")

        let samples = try readDb.allSamples()
        #expect(samples.count == 2)

        let best = try readDb.bestHits(forSamples: ["sample_A", "sample_B"])
        #expect(best.count == 3)
    }
}
