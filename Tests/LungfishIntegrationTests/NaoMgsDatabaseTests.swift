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
}
