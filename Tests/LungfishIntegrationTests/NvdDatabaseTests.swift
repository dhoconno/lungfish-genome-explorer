// NvdDatabaseTests.swift — Tests for NvdDatabase schema and queries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import Testing
import LungfishIO

struct NvdDatabaseTests {
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private final class PermissionFlip: @unchecked Sendable {
        private let directory: URL
        private let lock = NSLock()
        private var flipped = false

        init(directory: URL) {
            self.directory = directory
        }

        func flipIfFinalizing(message: String) {
            lock.lock()
            defer { lock.unlock() }
            guard message == "Finalizing...", !flipped else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            flipped = true
        }

        func restoreIfNeeded() {
            lock.lock()
            let shouldRestore = flipped
            flipped = false
            lock.unlock()

            if shouldRestore {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            }
        }
    }

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

    private func buildStateValue(at url: URL) throws -> String? {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT value FROM lungfish_database_state WHERE key = ?",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        _ = "build_state".withCString { keyPointer in
            sqlite3_bind_text(stmt, 1, keyPointer, -1, transientDestructor)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return String(cString: value)
    }

    private func database(at url: URL, hasColumn column: String, in table: String) throws -> Bool {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: name) == column { return true }
        }
        return false
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
        #expect(try buildStateValue(at: url) == "complete")
    }

    @Test
    func openRejectsIncompleteBuildState() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
            CREATE TABLE lungfish_database_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO lungfish_database_state VALUES ('build_state', 'building');
            """, nil, nil, nil) == SQLITE_OK)

        do {
            _ = try NvdDatabase(at: url)
            Issue.record("Expected incomplete build_state to be rejected")
        } catch NvdDatabaseError.openFailed(let message) {
            #expect(message.contains("build_state"))
            #expect(message.contains("building"))
        } catch {
            Issue.record("Expected NvdDatabaseError.openFailed, got \(error)")
        }
    }

    @Test
    func failedCreatePreservesExistingDatabase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-preserve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("test.sqlite")
        let originalHit = NvdBlastHit(
            experiment: "100",
            blastTask: "megablast",
            sampleId: "original",
            qseqid: "NODE_original",
            qlen: 100,
            sseqid: "NC_ORIGINAL",
            stitle: "Original",
            taxRank: "species:Original",
            length: 100,
            pident: 99,
            evalue: 0,
            bitscore: 100,
            sscinames: "Original",
            staxids: "1",
            blastDbVersion: "v1",
            snakemakeRunId: "run",
            mappedReads: 10,
            totalReads: 100,
            statDbVersion: "stat",
            adjustedTaxid: "1",
            adjustmentMethod: "dominant",
            adjustedTaxidName: "Original",
            adjustedTaxidRank: "species",
            hitRank: 1,
            readsPerBillion: 100_000_000
        )
        _ = try NvdDatabase.create(
            at: url,
            hits: [originalHit],
            samples: [NvdSampleMetadata(
                sampleId: "original",
                bamPath: "original.bam",
                fastaPath: "original.fasta",
                totalReads: 100,
                contigCount: 1,
                hitCount: 1
            )]
        )

        let permissionFlip = PermissionFlip(directory: dir)
        defer { permissionFlip.restoreIfNeeded() }
        let replacementHit = NvdBlastHit(
            experiment: "200",
            blastTask: "megablast",
            sampleId: "replacement",
            qseqid: "NODE_replacement",
            qlen: 100,
            sseqid: "NC_REPLACEMENT",
            stitle: "Replacement",
            taxRank: "species:Replacement",
            length: 100,
            pident: 99,
            evalue: 0,
            bitscore: 100,
            sscinames: "Replacement",
            staxids: "2",
            blastDbVersion: "v1",
            snakemakeRunId: "run",
            mappedReads: 10,
            totalReads: 100,
            statDbVersion: "stat",
            adjustedTaxid: "2",
            adjustmentMethod: "dominant",
            adjustedTaxidName: "Replacement",
            adjustedTaxidRank: "species",
            hitRank: 1,
            readsPerBillion: 100_000_000
        )

        #expect(throws: Error.self) {
            _ = try NvdDatabase.create(
                at: url,
                hits: [replacementHit],
                samples: [NvdSampleMetadata(
                    sampleId: "replacement",
                    bamPath: "replacement.bam",
                    fastaPath: "replacement.fasta",
                    totalReads: 100,
                    contigCount: 1,
                    hitCount: 1
                )]
            ) { _, message in
                permissionFlip.flipIfFinalizing(message: message)
            }
        }

        permissionFlip.restoreIfNeeded()

        let reopened = try NvdDatabase(at: url)
        let samples = try reopened.allSamples()
        #expect(samples.map(\.sampleId) == ["original"])
        #expect(try reopened.totalHitCount(samples: ["original"]) == 1)
        #expect(try reopened.totalHitCount(samples: ["replacement"]) == 0)
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
    func openingLegacyDatabaseWithoutReadinessMetadataFailsWithoutMutating() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try createLegacyDatabaseWithoutPostReleaseColumns(at: url)

        #expect(try buildStateValue(at: url) == nil)
        #expect(try !database(at: url, hasColumn: "unique_reads", in: "blast_hits"))
        #expect(try !database(at: url, hasColumn: "bam_index_path", in: "samples"))

        do {
            _ = try NvdDatabase(at: url)
            Issue.record("Expected legacy NVD open to fail without mutating")
        } catch NvdDatabaseError.openFailed(let message) {
            #expect(message.contains("lungfish_database_state") || message.contains("build_state"))
        } catch {
            Issue.record("Expected NvdDatabaseError.openFailed, got \(error)")
        }

        #expect(try buildStateValue(at: url) == nil)
        #expect(try !database(at: url, hasColumn: "unique_reads", in: "blast_hits"))
        #expect(try !database(at: url, hasColumn: "bam_index_path", in: "samples"))
    }

    @Test
    func openingMalformedLegacyDatabaseFailsWithoutAttemptingMigration() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try createDatabaseMissingSamplesTable(at: url)

        do {
            _ = try NvdDatabase(at: url)
            Issue.record("Expected malformed legacy NVD open to fail")
        } catch NvdDatabaseError.openFailed(let message) {
            #expect(message.contains("lungfish_database_state") || message.contains("build_state"))
        } catch {
            Issue.record("Expected NvdDatabaseError.openFailed, got \(error)")
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

    private func createLegacyDatabaseWithoutPostReleaseColumns(at url: URL) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw TestSQLiteError(message: msg)
        }
        defer { sqlite3_close(db) }

        try execute(db, """
        CREATE TABLE blast_hits (
            rowid INTEGER PRIMARY KEY,
            experiment TEXT NOT NULL,
            blast_task TEXT NOT NULL,
            sample_id TEXT NOT NULL,
            qseqid TEXT NOT NULL,
            qlen INTEGER NOT NULL,
            sseqid TEXT NOT NULL,
            stitle TEXT NOT NULL,
            tax_rank TEXT NOT NULL,
            length INTEGER NOT NULL,
            pident REAL NOT NULL,
            evalue REAL NOT NULL,
            bitscore REAL NOT NULL,
            sscinames TEXT NOT NULL,
            staxids TEXT NOT NULL,
            blast_db_version TEXT NOT NULL,
            snakemake_run_id TEXT NOT NULL,
            mapped_reads INTEGER NOT NULL,
            total_reads INTEGER NOT NULL,
            stat_db_version TEXT NOT NULL,
            adjusted_taxid INTEGER NOT NULL,
            adjustment_method TEXT NOT NULL,
            adjusted_taxid_name TEXT NOT NULL,
            adjusted_taxid_rank TEXT NOT NULL,
            hit_rank INTEGER NOT NULL,
            reads_per_billion REAL NOT NULL
        );

        CREATE TABLE samples (
            sample_id TEXT PRIMARY KEY,
            bam_path TEXT NOT NULL,
            fasta_path TEXT NOT NULL,
            total_reads INTEGER NOT NULL,
            contig_count INTEGER NOT NULL,
            hit_count INTEGER NOT NULL
        );

        INSERT INTO samples (
            sample_id, bam_path, fasta_path, total_reads, contig_count, hit_count
        ) VALUES (
            'sample_A', 'samples/sample_A/sample_A.sorted.bam',
            'samples/sample_A/sample_A_contigs.fasta', 100000, 1, 1
        );

        INSERT INTO blast_hits (
            experiment, blast_task, sample_id, qseqid, qlen,
            sseqid, stitle, tax_rank, length, pident, evalue, bitscore,
            sscinames, staxids, blast_db_version, snakemake_run_id,
            mapped_reads, total_reads, stat_db_version,
            adjusted_taxid, adjustment_method, adjusted_taxid_name,
            adjusted_taxid_rank, hit_rank, reads_per_billion
        ) VALUES (
            '100', 'megablast', 'sample_A', 'NODE_1_length_500_cov_10.0', 500,
            'NC_045512.2', 'Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1',
            'species:SARS-CoV-2', 480, 99.6, 0.0, 850.0,
            'Severe acute respiratory syndrome coronavirus 2', '2697049', 'v5.0', 'run_001',
            1000, 100000, 'stat_v1',
            2697049, 'dominant', 'SARS-CoV-2', 'species', 1, 10000000.0
        );
        """)
    }

    private func createDatabaseMissingSamplesTable(at url: URL) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw TestSQLiteError(message: msg)
        }
        defer { sqlite3_close(db) }

        try execute(db, """
        CREATE TABLE blast_hits (
            unique_reads INTEGER
        );
        """)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errMsg)
            throw TestSQLiteError(message: msg)
        }
    }

    private struct TestSQLiteError: Error {
        let message: String
    }
}
