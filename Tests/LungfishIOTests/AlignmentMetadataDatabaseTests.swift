// AlignmentMetadataDatabaseTests.swift - Tests for alignment metadata SQLite database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

// MARK: - AlignmentMetadataDatabase Tests

final class AlignmentMetadataDatabaseTests: XCTestCase {

    // MARK: - Test Fixtures

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishAlnDBTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeDatabase() throws -> AlignmentMetadataDatabase {
        let dbURL = tempDirectory.appendingPathComponent("test.stats.db")
        return try AlignmentMetadataDatabase.create(at: dbURL)
    }

    // MARK: - Creation

    func testCreateDatabase() throws {
        let dbURL = tempDirectory.appendingPathComponent("create.stats.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.databaseURL.path))
    }

    func testCreateOverwritesExisting() throws {
        let dbURL = tempDirectory.appendingPathComponent("overwrite.stats.db")

        let db1 = try AlignmentMetadataDatabase.create(at: dbURL)
        db1.setFileInfo("key1", value: "value1")
        XCTAssertEqual(db1.getFileInfo("key1"), "value1")

        // Create again — should overwrite
        let db2 = try AlignmentMetadataDatabase.create(at: dbURL)
        XCTAssertNil(db2.getFileInfo("key1"), "New database should not have data from old one")
    }

    func testOpenExisting() throws {
        let dbURL = tempDirectory.appendingPathComponent("open.stats.db")
        let db1 = try AlignmentMetadataDatabase.create(at: dbURL)
        db1.setFileInfo("test_key", value: "test_value")

        // Re-open as read-only
        let db2 = try AlignmentMetadataDatabase(url: dbURL)
        XCTAssertEqual(db2.getFileInfo("test_key"), "test_value")
    }

    // MARK: - File Info

    func testSetAndGetFileInfo() throws {
        let db = try makeDatabase()
        db.setFileInfo("source_path", value: "/data/sample.bam")
        db.setFileInfo("format", value: "bam")
        db.setFileInfo("total_reads", value: "1234567")

        XCTAssertEqual(db.getFileInfo("source_path"), "/data/sample.bam")
        XCTAssertEqual(db.getFileInfo("format"), "bam")
        XCTAssertEqual(db.getFileInfo("total_reads"), "1234567")
    }

    func testGetMissingFileInfo() throws {
        let db = try makeDatabase()
        XCTAssertNil(db.getFileInfo("nonexistent"))
    }

    func testSetFileInfoOverwrite() throws {
        let db = try makeDatabase()
        db.setFileInfo("key", value: "old")
        db.setFileInfo("key", value: "new")
        XCTAssertEqual(db.getFileInfo("key"), "new")
    }

    func testAllFileInfo() throws {
        let db = try makeDatabase()
        db.setFileInfo("a", value: "1")
        db.setFileInfo("b", value: "2")
        db.setFileInfo("c", value: "3")

        let all = db.allFileInfo()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all["a"], "1")
        XCTAssertEqual(all["b"], "2")
        XCTAssertEqual(all["c"], "3")
    }

    // MARK: - Read Groups

    func testAddAndQueryReadGroups() throws {
        let db = try makeDatabase()
        db.addReadGroup(id: "RG1", sample: "SampleA", library: "lib1", platform: "ILLUMINA")
        db.addReadGroup(id: "RG2", sample: "SampleB", platform: "ONT", center: "Wellcome")

        let groups = db.readGroups()
        XCTAssertEqual(groups.count, 2)

        let rg1 = groups.first { $0.id == "RG1" }
        XCTAssertNotNil(rg1)
        XCTAssertEqual(rg1?.sample, "SampleA")
        XCTAssertEqual(rg1?.library, "lib1")
        XCTAssertEqual(rg1?.platform, "ILLUMINA")
        XCTAssertNil(rg1?.center)

        let rg2 = groups.first { $0.id == "RG2" }
        XCTAssertNotNil(rg2)
        XCTAssertEqual(rg2?.sample, "SampleB")
        XCTAssertEqual(rg2?.platform, "ONT")
        XCTAssertEqual(rg2?.center, "Wellcome")
        XCTAssertNil(rg2?.library)
    }

    func testSampleNames() throws {
        let db = try makeDatabase()
        db.addReadGroup(id: "RG1", sample: "SampleB")
        db.addReadGroup(id: "RG2", sample: "SampleA")
        db.addReadGroup(id: "RG3", sample: "SampleB") // Duplicate
        db.addReadGroup(id: "RG4") // No sample

        let names = db.sampleNames()
        XCTAssertEqual(names, ["SampleA", "SampleB"])
    }

    // MARK: - Chromosome Stats

    func testAddAndQueryChromosomeStats() throws {
        let db = try makeDatabase()
        db.addChromosomeStats(chromosome: "chr1", length: 248_956_422, mapped: 50_000_000, unmapped: 1_000)
        db.addChromosomeStats(chromosome: "chr2", length: 242_193_529, mapped: 45_000_000, unmapped: 500)
        db.addChromosomeStats(chromosome: "chrM", length: 16_569, mapped: 100_000, unmapped: 10)

        let stats = db.chromosomeStats()
        XCTAssertEqual(stats.count, 3)
        // Should be ordered by mapped_reads DESC
        XCTAssertEqual(stats[0].chromosome, "chr1")
        XCTAssertEqual(stats[0].mappedReads, 50_000_000)
        XCTAssertEqual(stats[1].chromosome, "chr2")
        XCTAssertEqual(stats[2].chromosome, "chrM")
    }

    func testTotalMappedReads() throws {
        let db = try makeDatabase()
        db.addChromosomeStats(chromosome: "chr1", length: 1000, mapped: 100, unmapped: 10)
        db.addChromosomeStats(chromosome: "chr2", length: 2000, mapped: 200, unmapped: 20)

        XCTAssertEqual(db.totalMappedReads(), 300)
    }

    func testTotalUnmappedReads() throws {
        let db = try makeDatabase()
        db.addChromosomeStats(chromosome: "chr1", length: 1000, mapped: 100, unmapped: 10)
        db.addChromosomeStats(chromosome: "chr2", length: 2000, mapped: 200, unmapped: 20)

        XCTAssertEqual(db.totalUnmappedReads(), 30)
    }

    func testEmptyTotals() throws {
        let db = try makeDatabase()
        XCTAssertEqual(db.totalMappedReads(), 0)
        XCTAssertEqual(db.totalUnmappedReads(), 0)
    }

    // MARK: - Flag Stats

    func testAddAndQueryFlagStats() throws {
        let db = try makeDatabase()
        db.addFlagStat(category: "total", qcPass: 1_000_000, qcFail: 500)
        db.addFlagStat(category: "mapped", qcPass: 990_000, qcFail: 400)
        db.addFlagStat(category: "duplicates", qcPass: 50_000, qcFail: 100)

        let stats = db.flagStats()
        XCTAssertEqual(stats.count, 3)

        let total = stats.first { $0.category == "total" }
        XCTAssertNotNil(total)
        XCTAssertEqual(total?.qcPass, 1_000_000)
        XCTAssertEqual(total?.qcFail, 500)
    }

    // MARK: - Provenance

    func testAddProvenanceRecord() throws {
        let db = try makeDatabase()

        let step1 = db.addProvenanceRecord(
            tool: "samtools",
            subcommand: "index",
            version: "1.19",
            command: "samtools index sample.bam",
            inputFile: "/data/sample.bam",
            outputFile: "/data/sample.bam.bai",
            exitCode: 0,
            duration: 12.5
        )
        XCTAssertGreaterThan(step1, 0)

        let step2 = db.addProvenanceRecord(
            tool: "samtools",
            subcommand: "idxstats",
            version: "1.19",
            command: "samtools idxstats sample.bam",
            inputFile: "/data/sample.bam",
            exitCode: 0,
            duration: 0.5,
            parentStep: step1
        )
        XCTAssertGreaterThan(step2, step1)
    }

    func testProvenanceHistory() throws {
        let db = try makeDatabase()

        db.addProvenanceRecord(tool: "samtools", command: "samtools index sample.bam", exitCode: 0)
        db.addProvenanceRecord(tool: "samtools", command: "samtools idxstats sample.bam", exitCode: 0)

        let history = db.provenanceHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].tool, "samtools")
        XCTAssertEqual(history[0].command, "samtools index sample.bam")
        XCTAssertEqual(history[1].command, "samtools idxstats sample.bam")
    }

    // MARK: - Samtools Output Parsing

    func testPopulateFromIdxstats() throws {
        let db = try makeDatabase()
        let idxstatsOutput = """
        chr1\t248956422\t50000000\t1000
        chr2\t242193529\t45000000\t500
        chrM\t16569\t100000\t10
        *\t0\t0\t5000
        """
        db.populateFromIdxstats(idxstatsOutput)

        let stats = db.chromosomeStats()
        XCTAssertEqual(stats.count, 3, "Should skip the '*' unmapped line")
        XCTAssertEqual(db.totalMappedReads(), 95_100_000)
    }

    func testPopulateFromFlagstat() throws {
        let db = try makeDatabase()
        let flagstatOutput = """
        12345678 + 500 in total (QC-passed reads + QC-failed reads)
        0 + 0 primary
        1234 + 50 secondary
        5678 + 100 supplementary
        50000 + 200 duplicates
        49000 + 190 primary duplicates
        12000000 + 400 mapped (97.20% : N/A)
        11500000 + 350 primary mapped (93.20% : N/A)
        10000000 + 300 paired in sequencing
        5000000 + 150 read1
        5000000 + 150 read2
        9800000 + 290 properly paired (98.00% : N/A)
        9900000 + 295 with itself and mate mapped
        50000 + 5 singletons (0.50% : N/A)
        10000 + 2 with mate mapped to a different chr
        5000 + 1 with mate mapped to a different chr (mapQ>=5)
        """
        db.populateFromFlagstat(flagstatOutput)

        let stats = db.flagStats()
        XCTAssertEqual(stats.count, 16)

        let total = stats.first { $0.category == "total" }
        XCTAssertEqual(total?.qcPass, 12_345_678)
        XCTAssertEqual(total?.qcFail, 500)

        let mapped = stats.first { $0.category == "mapped" }
        XCTAssertEqual(mapped?.qcPass, 12_000_000)
    }

    func testPopulateFromFlagstatParsesByCategoryTextNotLineOrder() throws {
        let db = try makeDatabase()
        let flagstatOutput = """
        250 + 1 mapped (99.0% : N/A)
        300 + 2 in total (QC-passed reads + QC-failed reads)
        120 + 0 duplicates
        """
        db.populateFromFlagstat(flagstatOutput)

        let stats = db.flagStats()
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.first { $0.category == "total" }?.qcPass, 300)
        XCTAssertEqual(stats.first { $0.category == "mapped" }?.qcPass, 250)
        XCTAssertEqual(stats.first { $0.category == "duplicates" }?.qcPass, 120)
    }

    func testPopulateFromReadGroups() throws {
        let db = try makeDatabase()
        let readGroups = [
            SAMParser.ReadGroup(
                id: "RG1", sample: "SampleA", library: "lib1",
                platform: "ILLUMINA", platformUnit: "unit1",
                center: nil, description: nil
            ),
            SAMParser.ReadGroup(
                id: "RG2", sample: "SampleB", library: nil,
                platform: "ONT", platformUnit: nil,
                center: "Wellcome", description: "Long reads"
            )
        ]
        db.populateFromReadGroups(readGroups)

        let groups = db.readGroups()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.id == "RG1" }?.sample, "SampleA")
        XCTAssertEqual(groups.first { $0.id == "RG2" }?.center, "Wellcome")
    }

    // MARK: - Program Records

    func testAddAndQueryProgramRecords() throws {
        let db = try makeDatabase()
        db.addProgramRecord(
            id: "bwa",
            name: "bwa",
            version: "0.7.17",
            commandLine: "bwa mem -t 8 ref.fa reads.fq",
            previousProgram: nil
        )
        db.addProgramRecord(
            id: "samtools",
            name: "samtools",
            version: "1.19",
            commandLine: "samtools sort -o sorted.bam",
            previousProgram: "bwa"
        )

        let records = db.programRecords()
        XCTAssertEqual(records.count, 2)

        let bwa = records.first { $0.id == "bwa" }
        XCTAssertNotNil(bwa)
        XCTAssertEqual(bwa?.name, "bwa")
        XCTAssertEqual(bwa?.version, "0.7.17")
        XCTAssertEqual(bwa?.commandLine, "bwa mem -t 8 ref.fa reads.fq")
        XCTAssertNil(bwa?.previousProgram)

        let samtools = records.first { $0.id == "samtools" }
        XCTAssertNotNil(samtools)
        XCTAssertEqual(samtools?.previousProgram, "bwa")
    }

    func testPopulateFromProgramRecords() throws {
        let db = try makeDatabase()
        let parsed = [
            SAMParser.ProgramRecord(
                id: "tool1", name: "Tool One", version: "1.0",
                commandLine: "tool1 --input file.bam", previousProgram: nil
            ),
            SAMParser.ProgramRecord(
                id: "tool2", name: nil, version: "2.0",
                commandLine: nil, previousProgram: "tool1"
            )
        ]
        db.populateFromProgramRecords(parsed)

        let records = db.programRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first { $0.id == "tool1" }?.name, "Tool One")
        XCTAssertEqual(records.first { $0.id == "tool2" }?.previousProgram, "tool1")
        XCTAssertNil(records.first { $0.id == "tool2" }?.name)
    }

    func testProgramRecordsEmpty() throws {
        let db = try makeDatabase()
        XCTAssertTrue(db.programRecords().isEmpty)
    }

    // MARK: - Idxstats Edge Cases

    func testPopulateFromIdxstatsEmptyOutput() throws {
        let db = try makeDatabase()
        db.populateFromIdxstats("")
        XCTAssertEqual(db.totalMappedReads(), 0)
    }

    func testPopulateFromIdxstatsMalformedLines() throws {
        let db = try makeDatabase()
        let output = """
        chr1\t1000\t500\t10
        malformed line
        chr2\t2000
        chr3\t3000\t300\t5
        """
        db.populateFromIdxstats(output)
        let stats = db.chromosomeStats()
        XCTAssertEqual(stats.count, 2, "Should skip malformed lines")
    }
}
