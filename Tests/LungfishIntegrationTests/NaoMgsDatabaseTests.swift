// NaoMgsDatabaseTests.swift — Tests for NaoMgsDatabase schema and creation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
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
}
