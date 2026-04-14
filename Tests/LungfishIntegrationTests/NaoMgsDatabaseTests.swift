// NaoMgsDatabaseTests.swift — Tests for NaoMgsDatabase schema and creation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import Testing
import LungfishIO

struct NaoMgsDatabaseTests {

    // MARK: - Test Data

    /// Builds synthetic test hits: 2 samples x 2 taxa x 3 accessions with varying read counts.
    private func makeSyntheticHits() -> [NaoMgsVirusHit] {
        var hits: [NaoMgsVirusHit] = []
        let samples = ["sample_A", "sample_B"]
        let taxa = [(taxId: 2697049, title: "SARS-CoV-2"), (taxId: 11676, title: "HIV-1")]
        let accessions = ["NC_045512.2", "NC_001802.1", "NC_009334.1"]

        for sample in samples {
            for taxon in taxa {
                for (accIdx, accession) in accessions.enumerated() {
                    // Varying read counts per accession: 1, 2, 3
                    let readCount = accIdx + 1
                    for readNum in 0..<readCount {
                        hits.append(NaoMgsVirusHit(
                            sample: sample,
                            seqId: "\(sample)_\(taxon.taxId)_\(accession)_read\(readNum)",
                            taxId: taxon.taxId,
                            bestAlignmentScore: 120.0 + Double(readNum),
                            cigar: "150M",
                            queryStart: 0,
                            queryEnd: 150,
                            refStart: readNum * 200,
                            refEnd: readNum * 200 + 150,
                            readSequence: String(repeating: "A", count: 150),
                            readQuality: String(repeating: "I", count: 150),
                            subjectSeqId: accession,
                            subjectTitle: taxon.title,
                            bitScore: 250.0,
                            eValue: 1e-50,
                            percentIdentity: 98.5,
                            editDistance: 2,
                            fragmentLength: 300,
                            isReverseComplement: readNum % 2 == 1,
                            pairStatus: "CP",
                            queryLength: 150
                        ))
                    }
                }
            }
        }
        return hits
    }

    private func temporaryDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("naomgs_test_\(UUID().uuidString).sqlite")
    }

    // MARK: - Tests

    @Test
    func createDatabaseInsertsAllHits() throws {
        let hits = makeSyntheticHits()
        // 2 samples x 2 taxa x (1+2+3) reads = 2 x 2 x 6 = 24 hits
        #expect(hits.count == 24)

        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        let count = try db.totalHitCount()
        #expect(count == 24, "All 24 hits should be in the database")

        // Verify sample filtering
        let countA = try db.totalHitCount(samples: ["sample_A"])
        #expect(countA == 12, "sample_A should have 12 hits")

        let countBoth = try db.totalHitCount(samples: ["sample_A", "sample_B"])
        #expect(countBoth == 24, "Both samples together should have 24 hits")
    }

    @Test
    func createDatabaseWithEmptyHits() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: [])
        let count = try db.totalHitCount()
        #expect(count == 0, "Empty database should have 0 hits")
    }

    @Test
    func openExistingDatabase() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Create and immediately discard the returned handle
        _ = try NaoMgsDatabase.create(at: url, hits: hits)

        // Re-open read-only
        let reopened = try NaoMgsDatabase(at: url)
        let count = try reopened.totalHitCount()
        #expect(count == 24, "Re-opened database should still contain 24 hits")
    }

    // MARK: - fetchSamples

    @Test
    func fetchSamplesReturnsDistinctSamplesWithCounts() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        let samples = try db.fetchSamples()

        #expect(samples.count == 2, "Should have 2 distinct samples")
        // Each sample: 2 taxa x (1+2+3) = 12 hits
        #expect(samples[0].sample == "sample_A")
        #expect(samples[0].hitCount == 12)
        #expect(samples[1].sample == "sample_B")
        #expect(samples[1].hitCount == 12)
    }

    // MARK: - fetchTaxonSummaryRows

    @Test
    func fetchTaxonSummaryRowsReturnsPerSampleTaxonPairs() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)

        // All samples: 2 samples x 2 taxa = 4 rows
        let allRows = try db.fetchTaxonSummaryRows()
        #expect(allRows.count == 4, "Should have 4 taxon summary rows (2 samples x 2 taxa)")

        // Single sample: 2 taxa
        let singleRows = try db.fetchTaxonSummaryRows(samples: ["sample_A"])
        #expect(singleRows.count == 2, "Single sample should have 2 taxon summary rows")

        // Sorted by hit_count DESC — each (sample, taxon) pair has 6 hits so order is stable
        // but all have same count; just verify descending
        for i in 0..<(allRows.count - 1) {
            #expect(allRows[i].hitCount >= allRows[i + 1].hitCount,
                    "Rows should be sorted by hit count descending")
        }
    }

    @Test
    func taxonSummaryHasCorrectUniqueReadCount() throws {
        // Create hits with known duplicates: same accession + position + strand + length
        var hits: [NaoMgsVirusHit] = []
        // 3 reads at same position (duplicates) + 2 reads at different positions (unique)
        for i in 0..<3 {
            hits.append(NaoMgsVirusHit(
                sample: "dup_sample",
                seqId: "dup_read_\(i)",
                taxId: 999,
                bestAlignmentScore: 100.0,
                cigar: "100M",
                queryStart: 0,
                queryEnd: 100,
                refStart: 0,  // same position = duplicate
                refEnd: 100,
                readSequence: String(repeating: "A", count: 100),
                readQuality: String(repeating: "I", count: 100),
                subjectSeqId: "ACC_001",
                subjectTitle: "Test Virus",
                bitScore: 200.0,
                eValue: 1e-40,
                percentIdentity: 99.0,
                editDistance: 1,
                fragmentLength: 200,
                isReverseComplement: false,  // same strand
                pairStatus: "CP",
                queryLength: 100  // same length
            ))
        }
        for i in 0..<2 {
            hits.append(NaoMgsVirusHit(
                sample: "dup_sample",
                seqId: "unique_read_\(i)",
                taxId: 999,
                bestAlignmentScore: 100.0,
                cigar: "100M",
                queryStart: 0,
                queryEnd: 100,
                refStart: (i + 1) * 200,  // different positions = unique
                refEnd: (i + 1) * 200 + 100,
                readSequence: String(repeating: "A", count: 100),
                readQuality: String(repeating: "I", count: 100),
                subjectSeqId: "ACC_001",
                subjectTitle: "Test Virus",
                bitScore: 200.0,
                eValue: 1e-40,
                percentIdentity: 99.0,
                editDistance: 1,
                fragmentLength: 200,
                isReverseComplement: false,
                pairStatus: "CP",
                queryLength: 100
            ))
        }

        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        let rows = try db.fetchTaxonSummaryRows()

        #expect(rows.count == 1)
        #expect(rows[0].hitCount == 5, "Total hit count should be 5")
        // 3 reads at position 0 (same signature) + 2 at different positions = 3 unique
        #expect(rows[0].uniqueReadCount == 3, "Unique read count should be 3 (3 duplicates at pos 0 count as 1)")
        #expect(rows[0].pcrDuplicateCount == 2, "PCR duplicate count should be 2")
    }

    @Test
    func taxonSummaryHasTopAccessions() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        let rows = try db.fetchTaxonSummaryRows()

        for row in rows {
            #expect(!row.topAccessions.isEmpty, "Top accessions should not be empty")
            #expect(row.topAccessions.count <= 5, "Top accessions should be at most 5")
        }
    }

    // MARK: - fetchAccessionSummaries

    @Test
    func fetchAccessionSummariesReturnsPerAccessionData() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        let summaries = try db.fetchAccessionSummaries(sample: "sample_A", taxId: 2697049)

        // 3 accessions for this (sample, taxon) pair
        #expect(summaries.count == 3, "Should have 3 accessions")

        // Sorted by read count DESC: NC_009334.1 (3 reads), NC_001802.1 (2 reads), NC_045512.2 (1 read)
        #expect(summaries[0].readCount >= summaries[1].readCount, "Should be sorted by read count descending")
        #expect(summaries[1].readCount >= summaries[2].readCount, "Should be sorted by read count descending")
    }

    // MARK: - fetchReadsForAccession

    @Test
    func fetchReadsForAccessionReturnsAlignedReads() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        // NC_009334.1 is accession index 2 -> 3 reads per (sample, taxon)
        let reads = try db.fetchReadsForAccession(
            sample: "sample_A", taxId: 2697049, accession: "NC_009334.1"
        )

        #expect(reads.count == 3, "Should have 3 reads for this accession")

        let first = reads[0]
        #expect(first.chromosome == "NC_009334.1", "Chromosome should match accession")
        #expect(!first.sequence.isEmpty, "Sequence should not be empty")
        #expect(!first.cigar.isEmpty, "CIGAR should not be empty")
        #expect(first.position >= 0, "Position should be non-negative")

        // Check reverse complement flag: readNum 1 should be RC (flag 0x10)
        let rcReads = reads.filter { $0.isReverse }
        let fwdReads = reads.filter { !$0.isReverse }
        // readNum 0=fwd, 1=rc, 2=fwd
        #expect(fwdReads.count == 2, "Should have 2 forward reads")
        #expect(rcReads.count == 1, "Should have 1 reverse complement read")
    }

    @Test
    func fetchReadsRespectsMaxReads() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        let reads = try db.fetchReadsForAccession(
            sample: "sample_A", taxId: 2697049, accession: "NC_009334.1", maxReads: 1
        )

        #expect(reads.count == 1, "Should respect maxReads limit of 1")
    }

    // MARK: - Accession Summary Coverage Pre-Computation

    @Test
    func accessionSummariesHaveCoverageValues() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        let summaries = try db.fetchAccessionSummaries(sample: "sample_A", taxId: 2697049)

        #expect(summaries.count == 3)
        for summary in summaries {
            #expect(summary.referenceLength > 0, "Reference length should be positive")
            #expect(summary.coveredBasePairs > 0, "Covered base pairs should be positive for hits with known positions")
            #expect(summary.coverageFraction > 0, "Coverage fraction should be positive")
            #expect(summary.coverageFraction <= 1.0, "Coverage fraction should not exceed 1.0")
        }

        // NC_009334.1 has 3 reads at positions 0, 200, 400 with length 150 each.
        // Covered: 0..150 + 200..350 + 400..550 = 450 bp covered.
        let acc3 = summaries.first { $0.accession == "NC_009334.1" }!
        #expect(acc3.coveredBasePairs == 450, "3 non-overlapping reads of 150bp = 450bp covered")
    }

    @Test
    func accessionSummariesHandleOverlappingReads() throws {
        // Create hits with overlapping positions to test interval merging
        var hits: [NaoMgsVirusHit] = []
        for i in 0..<3 {
            hits.append(NaoMgsVirusHit(
                sample: "overlap_sample",
                seqId: "read_\(i)",
                taxId: 100,
                bestAlignmentScore: 100.0,
                cigar: "100M",
                queryStart: 0,
                queryEnd: 100,
                refStart: i * 50,  // 0, 50, 100 — overlapping by 50bp each
                refEnd: i * 50 + 100,
                readSequence: String(repeating: "A", count: 100),
                readQuality: String(repeating: "I", count: 100),
                subjectSeqId: "REF_001",
                subjectTitle: "Overlap Virus",
                bitScore: 200.0,
                eValue: 1e-40,
                percentIdentity: 99.0,
                editDistance: 1,
                fragmentLength: 200,
                isReverseComplement: false,
                pairStatus: "CP",
                queryLength: 100
            ))
        }

        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try NaoMgsDatabase.create(at: url, hits: hits)
        let summaries = try db.fetchAccessionSummaries(sample: "overlap_sample", taxId: 100)

        #expect(summaries.count == 1)
        // Reads at 0..100, 50..150, 100..200 — merged interval 0..200 = 200bp
        #expect(summaries[0].coveredBasePairs == 200, "Overlapping reads should be merged: 0-200 = 200bp")
    }

    // MARK: - Virus Hits Purge

    @Test
    func deleteVirusHitsAndVacuumPurgesRows() throws {
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try NaoMgsDatabase.create(at: url, hits: hits)

        // Open read-write and purge
        let rwDB = try NaoMgsDatabase.openReadWrite(at: url)
        try rwDB.deleteVirusHitsAndVacuum()

        // Re-open read-only and verify
        let db = try NaoMgsDatabase(at: url)

        // totalHitCount uses taxon_summaries, should still report 24
        let count = try db.totalHitCount()
        #expect(count == 24, "totalHitCount should still report 24 (from taxon_summaries)")

        // fetchSamples uses taxon_summaries, should still work
        let samples = try db.fetchSamples()
        #expect(samples.count == 2, "fetchSamples should still return 2 samples")
        #expect(samples[0].hitCount == 12)

        // fetchAccessionSummaries uses accession_summaries, should still work
        let summaries = try db.fetchAccessionSummaries(sample: "sample_A", taxId: 2697049)
        #expect(summaries.count == 3, "Accession summaries should survive purge")

        // fetchReadsForAccession queries virus_hits directly, should return empty
        let reads = try db.fetchReadsForAccession(
            sample: "sample_A", taxId: 2697049, accession: "NC_009334.1"
        )
        #expect(reads.isEmpty, "Reads should be empty after virus_hits purge")

        let readNames = try db.fetchReadNames(sample: "sample_A", taxId: 2697049)
        #expect(
            !readNames.isEmpty,
            "Taxon read names should survive purge so NAO-MGS miniBAMs can stay taxon-specific"
        )

        // Taxon summary rows should still work
        let taxonRows = try db.fetchTaxonSummaryRows()
        #expect(taxonRows.count == 4, "Taxon summary rows should survive purge")
    }

    @Test
    func databaseShrinksSizeAfterPurge() throws {
        // Use larger hits (1000 reads with realistic sequences) so the purge
        // produces a measurable size reduction.
        var hits: [NaoMgsVirusHit] = []
        for i in 0..<1000 {
            hits.append(NaoMgsVirusHit(
                sample: "bulk_sample",
                seqId: "read_\(i)",
                taxId: 12345,
                bestAlignmentScore: 100.0,
                cigar: "150M",
                queryStart: 0,
                queryEnd: 150,
                refStart: i * 10,
                refEnd: i * 10 + 150,
                readSequence: String(repeating: "ACGTACGT", count: 19),  // 152 chars
                readQuality: String(repeating: "IIIIIII!", count: 19),
                subjectSeqId: "ACC_\(i % 5)",
                subjectTitle: "Test Virus \(i % 5)",
                bitScore: 200.0,
                eValue: 1e-40,
                percentIdentity: 98.0,
                editDistance: 3,
                fragmentLength: 300,
                isReverseComplement: i % 2 == 0,
                pairStatus: "CP",
                queryLength: 150
            ))
        }

        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try NaoMgsDatabase.create(at: url, hits: hits)

        let sizeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64

        // Open, purge, then close the connection so VACUUM commits to disk
        do {
            let rwDB = try NaoMgsDatabase.openReadWrite(at: url)
            try rwDB.deleteVirusHitsAndVacuum()
            // rwDB deinit closes the connection
        }

        let sizeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64
        #expect(sizeAfter < sizeBefore, "Database should shrink after purge (was \(sizeBefore), now \(sizeAfter))")
    }

    // MARK: - Schema Migration

    @Test
    func openOldDatabaseTriggersAccessionSummaryMigration() throws {
        // Create a database, then remove accession_summaries to simulate an old schema
        let hits = makeSyntheticHits()
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try NaoMgsDatabase.create(at: url, hits: hits)

        // Drop accession_summaries to simulate pre-migration database
        do {
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            #expect(rc == SQLITE_OK)
            sqlite3_exec(db, "DROP TABLE accession_summaries", nil, nil, nil)
            sqlite3_close(db)
        }

        // Re-open — migration should recreate and populate accession_summaries
        let db = try NaoMgsDatabase(at: url)
        let summaries = try db.fetchAccessionSummaries(sample: "sample_A", taxId: 2697049)
        #expect(summaries.count == 3, "Migration should recreate accession_summaries from virus_hits")
        #expect(summaries[0].readCount > 0, "Migrated summaries should have read counts")
        #expect(summaries[0].coveredBasePairs > 0, "Migrated summaries should have coverage")
    }

    @Test
    func openLegacyDatabaseWithoutReverseColumnsMigratesAccessionSummaries() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            #expect(rc == SQLITE_OK)
            guard let db else { return }
            defer { sqlite3_close(db) }

            let createSQL = """
        CREATE TABLE virus_hits (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            seq_id TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            subject_seq_id TEXT NOT NULL,
            subject_title TEXT NOT NULL,
            ref_start INTEGER NOT NULL,
            cigar TEXT NOT NULL,
            read_sequence TEXT NOT NULL,
            read_quality TEXT NOT NULL,
            percent_identity REAL NOT NULL,
            bit_score REAL NOT NULL,
            e_value REAL NOT NULL,
            edit_distance INTEGER NOT NULL,
            query_length INTEGER NOT NULL,
            is_reverse_complement INTEGER NOT NULL,
            pair_status TEXT NOT NULL,
            fragment_length INTEGER NOT NULL,
            best_alignment_score REAL NOT NULL
        );
        CREATE TABLE taxon_summaries (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            hit_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL,
            avg_identity REAL NOT NULL,
            avg_bit_score REAL NOT NULL,
            avg_edit_distance REAL NOT NULL,
            pcr_duplicate_count INTEGER NOT NULL DEFAULT 0,
            accession_count INTEGER NOT NULL DEFAULT 0,
            top_accessions_json TEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY (sample, tax_id)
        );
        CREATE TABLE reference_lengths (
            accession TEXT PRIMARY KEY,
            length INTEGER NOT NULL
        );
        INSERT INTO reference_lengths (accession, length) VALUES ('AF304460.1', 1000), ('KT253324.1', 900);
        INSERT INTO taxon_summaries (
            sample, tax_id, name, hit_count, unique_read_count, avg_identity, avg_bit_score,
            avg_edit_distance, pcr_duplicate_count, accession_count, top_accessions_json
        ) VALUES (
            'legacy_sample', 11137, 'Human coronavirus 229E', 5, 5, 99.0, 250.0, 1.0, 0, 2,
            '["AF304460.1","KT253324.1"]'
        );
        """
            #expect(sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK)

            let insertSQL = """
        INSERT INTO virus_hits (
            sample, seq_id, tax_id, subject_seq_id, subject_title, ref_start, cigar,
            read_sequence, read_quality, percent_identity, bit_score, e_value,
            edit_distance, query_length, is_reverse_complement, pair_status,
            fragment_length, best_alignment_score
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }

            let reads: [(String, String, Int)] = [
                ("read_001", "AF304460.1", 0),
                ("read_002", "AF304460.1", 100),
                ("read_003", "AF304460.1", 200),
                ("read_004", "KT253324.1", 0),
                ("read_005", "KT253324.1", 100),
            ]
            for (seqId, accession, refStart) in reads {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, ("legacy_sample" as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (seqId as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 3, 11137)
                sqlite3_bind_text(stmt, 4, (accession as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, ("Human coronavirus 229E" as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 6, Int64(refStart))
                sqlite3_bind_text(stmt, 7, ("100M" as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 8, (String(repeating: "A", count: 100) as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 9, (String(repeating: "I", count: 100) as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 10, 99.0)
                sqlite3_bind_double(stmt, 11, 250.0)
                sqlite3_bind_double(stmt, 12, 1e-40)
                sqlite3_bind_int64(stmt, 13, 1)
                sqlite3_bind_int64(stmt, 14, 100)
                sqlite3_bind_int64(stmt, 15, 0)
                sqlite3_bind_text(stmt, 16, ("CP" as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 17, 200)
                sqlite3_bind_double(stmt, 18, 250.0)
                #expect(sqlite3_step(stmt) == SQLITE_DONE)
            }
        }

        let migrated = try NaoMgsDatabase(at: url)
        let summaries = try migrated.fetchAccessionSummaries(sample: "legacy_sample", taxId: 11137)
        #expect(summaries.count == 2, "Migration should rebuild accession summaries for legacy virus_hits schemas")
        #expect(summaries.reduce(0) { $0 + $1.readCount } == 5, "Migrated accession summaries should retain all legacy reads")
        #expect(summaries.allSatisfy { $0.coveredBasePairs > 0 }, "Migrated legacy summaries should compute covered bases")
    }
}
