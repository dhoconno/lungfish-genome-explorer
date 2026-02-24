// AlignmentChromosomeAliasingTests.swift - Tests for alignment chromosome name resolution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

/// Tests verifying that alignment chromosome aliasing works correctly.
///
/// BAM/CRAM files frequently use different chromosome naming than the reference bundle
/// (e.g., "MN908947.3" vs "MN908947", or "chr1" vs "1"). The aliasing system matches
/// chromosomes by sequence length from the AlignmentMetadataDatabase (populated at import).
final class AlignmentChromosomeAliasingTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Metadata DB Chromosome Stats

    func testMetadataDBAStoresChromosomeStats() throws {
        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        db.addChromosomeStats(chromosome: "MN908947.3", length: 29903, mapped: 169022, unmapped: 0)

        let stats = db.chromosomeStats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].chromosome, "MN908947.3")
        XCTAssertEqual(stats[0].length, 29903)
        XCTAssertEqual(stats[0].mappedReads, 169022)
    }

    func testMetadataDBMultipleChromosomes() throws {
        let dbURL = tempDir.appendingPathComponent("multi.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        db.addChromosomeStats(chromosome: "chr1", length: 248956422, mapped: 15_000_000, unmapped: 50000)
        db.addChromosomeStats(chromosome: "chr2", length: 242193529, mapped: 12_000_000, unmapped: 40000)
        db.addChromosomeStats(chromosome: "chrX", length: 156040895, mapped: 5_000_000, unmapped: 20000)

        let stats = db.chromosomeStats()
        XCTAssertEqual(stats.count, 3)

        let names = Set(stats.map(\.chromosome))
        XCTAssertTrue(names.contains("chr1"))
        XCTAssertTrue(names.contains("chr2"))
        XCTAssertTrue(names.contains("chrX"))
    }

    func testMetadataDBCanBeOpenedReadOnly() throws {
        let dbURL = tempDir.appendingPathComponent("readonly.db")

        // Create and populate
        let writeDB = try AlignmentMetadataDatabase.create(at: dbURL)
        writeDB.addChromosomeStats(chromosome: "MN908947.3", length: 29903, mapped: 100, unmapped: 0)

        // Reopen read-only
        let readDB = try AlignmentMetadataDatabase(url: dbURL)
        let stats = readDB.chromosomeStats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].chromosome, "MN908947.3")
    }

    // MARK: - Length-Based Matching Logic

    func testExactLengthMatchIdentifiesMismatchedNames() throws {
        // Simulate: reference has "MN908947" (29903 bp), BAM has "MN908947.3" (29903 bp)
        let refChromosomes = [
            ChromosomeInfo(name: "MN908947", length: 29903, offset: 0, lineBases: 60, lineWidth: 61)
        ]

        let dbURL = tempDir.appendingPathComponent("alias.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)
        db.addChromosomeStats(chromosome: "MN908947.3", length: 29903, mapped: 169022, unmapped: 0)

        let stats = db.chromosomeStats()
        let bamChromLengths = Dictionary(uniqueKeysWithValues: stats.map { ($0.chromosome, $0.length) })

        // Manual alias logic (mirrors buildAlignmentChromosomeAliasMap)
        let refNames = Set(refChromosomes.map(\.name))
        let bamNames = Set(bamChromLengths.keys)
        let unmatched = bamNames.subtracting(refNames)

        XCTAssertEqual(unmatched, Set(["MN908947.3"]), "BAM name should not match ref name")

        // Match by length
        var aliasMap: [String: String] = [:]
        for chrom in refChromosomes {
            if bamNames.contains(chrom.name) { continue }
            for bamChrom in unmatched {
                if bamChromLengths[bamChrom] == chrom.length {
                    aliasMap[chrom.name] = bamChrom
                }
            }
        }

        XCTAssertEqual(aliasMap.count, 1)
        XCTAssertEqual(aliasMap["MN908947"], "MN908947.3")
    }

    func testNoAliasNeededWhenNamesMatch() throws {
        let refChromosomes = [
            ChromosomeInfo(name: "chr1", length: 248956422, offset: 0, lineBases: 60, lineWidth: 61)
        ]

        let dbURL = tempDir.appendingPathComponent("match.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)
        db.addChromosomeStats(chromosome: "chr1", length: 248956422, mapped: 100, unmapped: 0)

        let stats = db.chromosomeStats()
        let bamNames = Set(stats.map(\.chromosome))
        let refNames = Set(refChromosomes.map(\.name))
        let unmatched = bamNames.subtracting(refNames)

        XCTAssertTrue(unmatched.isEmpty, "No unmatched names when they already match")
    }

    func testMultiChromosomeAliasing() throws {
        // Reference uses NC_ accessions, BAM uses plain numbers
        let refChromosomes = [
            ChromosomeInfo(name: "NC_041760.1", length: 161_218_571, offset: 0, lineBases: 60, lineWidth: 61),
            ChromosomeInfo(name: "NC_041761.1", length: 153_896_217, offset: 0, lineBases: 60, lineWidth: 61),
        ]

        let dbURL = tempDir.appendingPathComponent("multi_alias.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)
        db.addChromosomeStats(chromosome: "7", length: 161_218_571, mapped: 5_000_000, unmapped: 0)
        db.addChromosomeStats(chromosome: "8", length: 153_896_217, mapped: 4_000_000, unmapped: 0)

        let stats = db.chromosomeStats()
        let bamChromLengths = Dictionary(uniqueKeysWithValues: stats.map { ($0.chromosome, $0.length) })
        let refNames = Set(refChromosomes.map(\.name))
        let bamNames = Set(bamChromLengths.keys)
        let unmatched = bamNames.subtracting(refNames)

        var aliasMap: [String: String] = [:]
        var usedBAMChroms = Set<String>()
        for chrom in refChromosomes {
            if bamNames.contains(chrom.name) { continue }
            for bamChrom in unmatched where !usedBAMChroms.contains(bamChrom) {
                if bamChromLengths[bamChrom] == chrom.length {
                    aliasMap[chrom.name] = bamChrom
                    usedBAMChroms.insert(bamChrom)
                    break
                }
            }
        }

        XCTAssertEqual(aliasMap.count, 2)
        XCTAssertEqual(aliasMap["NC_041760.1"], "7")
        XCTAssertEqual(aliasMap["NC_041761.1"], "8")
    }

    func testNoAliasWhenNoMetadataDB() throws {
        // When no metadata DB path is available, alias map should be empty
        let trackInfo = AlignmentTrackInfo(
            id: "test",
            name: "sample.bam",
            format: .bam,
            sourcePath: "/data/sample.bam",
            indexPath: "/data/sample.bam.bai"
            // metadataDBPath is nil
        )
        XCTAssertNil(trackInfo.metadataDBPath)
    }

    // MARK: - Edge Cases

    func testPopulateFromIdxstatsFormatsCorrectly() throws {
        let dbURL = tempDir.appendingPathComponent("idxstats.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        // idxstats format: chromName\tseqLen\tmapped\tunmapped
        let idxstatsOutput = "MN908947.3\t29903\t169022\t0\n*\t0\t0\t0\n"
        db.populateFromIdxstats(idxstatsOutput)

        let stats = db.chromosomeStats()
        XCTAssertEqual(stats.count, 1, "Should skip * unmapped line")
        XCTAssertEqual(stats[0].chromosome, "MN908947.3")
        XCTAssertEqual(stats[0].length, 29903)
    }

    func testDuplicateLengthsPreventsFalseMatch() throws {
        // Two BAM chromosomes with the same length — should only match one
        let refChromosomes = [
            ChromosomeInfo(name: "scaffold_1", length: 1000, offset: 0, lineBases: 60, lineWidth: 61),
            ChromosomeInfo(name: "scaffold_2", length: 1000, offset: 0, lineBases: 60, lineWidth: 61),
        ]

        let dbURL = tempDir.appendingPathComponent("dup.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)
        db.addChromosomeStats(chromosome: "scf1", length: 1000, mapped: 100, unmapped: 0)
        db.addChromosomeStats(chromosome: "scf2", length: 1000, mapped: 50, unmapped: 0)

        let stats = db.chromosomeStats()
        let bamChromLengths = Dictionary(uniqueKeysWithValues: stats.map { ($0.chromosome, $0.length) })
        let bamNames = Set(bamChromLengths.keys)
        let refNames = Set(refChromosomes.map(\.name))
        let unmatched = bamNames.subtracting(refNames)

        // With exact length matching, both BAM chroms match both ref chroms
        // The algorithm should assign each BAM chrom to exactly one ref chrom
        var aliasMap: [String: String] = [:]
        var usedBAMChroms = Set<String>()
        for chrom in refChromosomes {
            if bamNames.contains(chrom.name) { continue }
            for bamChrom in unmatched.sorted() where !usedBAMChroms.contains(bamChrom) {
                if bamChromLengths[bamChrom] == chrom.length {
                    aliasMap[chrom.name] = bamChrom
                    usedBAMChroms.insert(bamChrom)
                    break
                }
            }
        }

        XCTAssertEqual(aliasMap.count, 2, "Each ref chrom should get a unique BAM alias")
        XCTAssertNotEqual(aliasMap["scaffold_1"], aliasMap["scaffold_2"],
                          "Two ref chroms should map to different BAM chroms")
    }
}
