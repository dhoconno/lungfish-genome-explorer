// ReadExtractionServiceTests.swift — Integration tests for ReadExtractionService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests exercise the three extraction strategies (read ID, BAM region,
// database) against the nf-core SARS-CoV-2 fixture data.  They require the
// bundled `samtools` and `seqkit` binaries to be present in the
// LungfishWorkflow resource bundle.
//
// The BAM fixture is paired-end (200 reads: 100 R1 + 100 R2), which is the
// exact configuration that exposed the `-0` vs `-o` samtools fastq bug.

import XCTest
import SQLite3
@testable import LungfishWorkflow

final class ReadExtractionServiceTests: XCTestCase {

    // MARK: - Shared State

    private var tempDir: URL!
    private var service: ReadExtractionService!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extraction-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = ReadExtractionService()
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - BAM Region Extraction (paired-end)

    /// Extracts all reads from the paired-end BAM by specifying the single
    /// reference name MT192765.1.  This is the exact flow that was broken
    /// when `-0` was used instead of `-o` in samtools fastq.
    func testExtractByBAMRegionPairedEnd() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: ["MT192765.1"],
            fallbackToAll: false,
            outputDirectory: tempDir,
            outputBaseName: "paired_region"
        )

        let result = try await service.extractByBAMRegion(config: config)

        // The fixture has 200 reads (100 R1 + 100 R2), 197 mapped.
        // samtools view filters to MT192765.1, which has 197 mapped reads.
        // samtools fastq -o writes READ1 and READ2 reads interleaved.
        XCTAssertGreaterThan(result.readCount, 0, "Must extract at least some reads from paired-end BAM")

        // Verify the output file is valid FASTQ (has @ header lines)
        let outputURL = result.fastqURLs[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertTrue(lines[0].hasPrefix("@"), "First line should be a FASTQ header")

        // Every 4th line should be a header (FASTQ format: @header, seq, +, qual)
        let headerCount = lines.enumerated().filter { $0.offset % 4 == 0 && $0.element.hasPrefix("@") }.count
        XCTAssertEqual(headerCount, result.readCount, "Header count should equal reported read count")
    }

    /// Verifies that deduplication flag works (no duplicate-flagged reads
    /// should be present in the fixture, so counts should be identical).
    func testExtractByBAMRegionWithDeduplication() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam

        // Without dedup
        let configNormal = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: ["MT192765.1"],
            fallbackToAll: false,
            outputDirectory: tempDir.appendingPathComponent("nodedup"),
            outputBaseName: "nodedup",
            deduplicateReads: false
        )
        let resultNormal = try await service.extractByBAMRegion(config: configNormal)

        // With dedup
        let configDedup = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: ["MT192765.1"],
            fallbackToAll: false,
            outputDirectory: tempDir.appendingPathComponent("dedup"),
            outputBaseName: "dedup",
            deduplicateReads: true
        )
        let resultDedup = try await service.extractByBAMRegion(config: configDedup)

        // Fixture has 0 duplicates per flagstat, so counts should match
        XCTAssertEqual(resultNormal.readCount, resultDedup.readCount,
                       "Fixture has no duplicates, counts should be equal")
    }

    /// Verifies that a nonexistent region produces the expected error.
    func testExtractByBAMRegionNoMatch() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: ["NONEXISTENT_REGION"],
            fallbackToAll: false,
            outputDirectory: tempDir,
            outputBaseName: "nomatch"
        )

        do {
            _ = try await service.extractByBAMRegion(config: config)
            XCTFail("Should have thrown noMatchingRegions")
        } catch let error as ExtractionError {
            if case .noMatchingRegions = error {
                // expected
            } else {
                XCTFail("Expected noMatchingRegions, got \(error)")
            }
        }
    }

    /// Verifies that fallbackToAll extracts reads when the region doesn't match.
    func testExtractByBAMRegionFallbackToAll() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: ["NONEXISTENT_REGION"],
            fallbackToAll: true,
            outputDirectory: tempDir,
            outputBaseName: "fallback"
        )

        let result = try await service.extractByBAMRegion(config: config)
        XCTAssertGreaterThan(result.readCount, 0, "Fallback should extract all reads")
    }

    /// Verifies that a missing BAM index is detected.
    func testExtractByBAMRegionMissingIndex() async throws {
        // Copy the BAM to a temp location without the index
        let srcBAM = TestFixtures.sarscov2.sortedBam
        let isolatedBAM = tempDir.appendingPathComponent("no_index.bam")
        try FileManager.default.copyItem(at: srcBAM, to: isolatedBAM)

        let config = BAMRegionExtractionConfig(
            bamURL: isolatedBAM,
            regions: ["MT192765.1"],
            fallbackToAll: false,
            outputDirectory: tempDir,
            outputBaseName: "noindex"
        )

        do {
            _ = try await service.extractByBAMRegion(config: config)
            XCTFail("Should have thrown bamNotIndexed")
        } catch let error as ExtractionError {
            if case .bamNotIndexed = error {
                // expected
            } else {
                XCTFail("Expected bamNotIndexed, got \(error)")
            }
        }
    }

    /// Verifies that progress callbacks fire during BAM extraction.
    func testExtractByBAMRegionReportsProgress() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: ["MT192765.1"],
            fallbackToAll: false,
            outputDirectory: tempDir,
            outputBaseName: "progress"
        )

        let progressValues = ProgressAccumulator()

        _ = try await service.extractByBAMRegion(config: config) { fraction, message in
            progressValues.append(fraction, message)
        }

        let calls = progressValues.getCalls()
        XCTAssertGreaterThan(calls.count, 0, "Should have received progress callbacks")
        // Progress should start at or near 0.1 and end at 1.0
        if let last = calls.last {
            XCTAssertEqual(last.0, 1.0, accuracy: 0.001, "Final progress should be 1.0")
        }
    }

    // MARK: - Read ID Extraction

    /// Extracts a subset of reads from the fixture FASTQ by read ID.
    func testExtractByReadIDsSingleEnd() async throws {
        let fastqR1 = TestFixtures.sarscov2.fastqR1

        // Get a few read IDs from the FASTQ by scanning the first entries
        let readIDs = try extractReadIDsFromFASTQ(fastqR1, count: 5)
        XCTAssertEqual(readIDs.count, 5, "Should have extracted 5 read IDs from fixture")

        let config = ReadIDExtractionConfig(
            sourceFASTQs: [fastqR1],
            readIDs: Set(readIDs),
            keepReadPairs: false,
            outputDirectory: tempDir,
            outputBaseName: "id_extract"
        )

        let result = try await service.extractByReadIDs(config: config)
        XCTAssertEqual(result.readCount, 5, "Should extract exactly 5 reads by ID")
        XCTAssertFalse(result.pairedEnd)
    }

    /// Extracts from paired FASTQ files, verifying both files are produced.
    func testExtractByReadIDsPairedEnd() async throws {
        let (r1, r2) = TestFixtures.sarscov2.pairedFastq

        // Get IDs from R1 — these should also be present in R2
        let readIDs = try extractReadIDsFromFASTQ(r1, count: 3)

        let config = ReadIDExtractionConfig(
            sourceFASTQs: [r1, r2],
            readIDs: Set(readIDs),
            keepReadPairs: true,
            outputDirectory: tempDir,
            outputBaseName: "paired_id_extract"
        )

        let result = try await service.extractByReadIDs(config: config)
        XCTAssertGreaterThan(result.readCount, 0)
        XCTAssertTrue(result.pairedEnd)
        XCTAssertEqual(result.fastqURLs.count, 2, "Paired extraction should produce two files")
    }

    /// Verifies that an empty read ID set is rejected.
    func testExtractByReadIDsEmptySet() async throws {
        let fastqR1 = TestFixtures.sarscov2.fastqR1
        let config = ReadIDExtractionConfig(
            sourceFASTQs: [fastqR1],
            readIDs: [],
            outputDirectory: tempDir,
            outputBaseName: "empty"
        )

        do {
            _ = try await service.extractByReadIDs(config: config)
            XCTFail("Should throw emptyReadIDSet")
        } catch let error as ExtractionError {
            if case .emptyReadIDSet = error {
                // expected
            } else {
                XCTFail("Expected emptyReadIDSet, got \(error)")
            }
        }
    }

    // MARK: - Bundle Creation

    /// Verifies bundle creation from extraction results produces valid structure.
    func testCreateBundleFromBAMExtraction() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: ["MT192765.1"],
            fallbackToAll: false,
            outputDirectory: tempDir,
            outputBaseName: "bundle_test"
        )

        let result = try await service.extractByBAMRegion(config: config)

        let metadata = ExtractionMetadata(
            sourceDescription: "SARS-CoV-2 test",
            toolName: "TestSuite",
            parameters: ["regions": "MT192765.1"]
        )

        let bundleDir = tempDir.appendingPathComponent("bundles")
        let bundleURL = try await service.createBundle(
            from: result,
            sourceName: "test_sample",
            selectionDescription: "MT192765.1",
            metadata: metadata,
            in: bundleDir
        )

        // Verify bundle structure
        XCTAssertTrue(bundleURL.lastPathComponent.hasSuffix(".lungfishfastq"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))

        // Should contain the FASTQ and extraction metadata
        let contents = try FileManager.default.contentsOfDirectory(atPath: bundleURL.path)
        XCTAssertTrue(contents.contains(where: { $0.hasSuffix(".fastq") }),
                       "Bundle should contain a FASTQ file")
        XCTAssertTrue(contents.contains("extraction-metadata.json"),
                       "Bundle should contain extraction metadata")
        XCTAssertTrue(contents.contains(ProvenanceRecorder.provenanceFilename),
                      "Bundle should contain reproducibility provenance")

        // Verify metadata is valid JSON (encoder uses .iso8601)
        let metadataURL = bundleURL.appendingPathComponent("extraction-metadata.json")
        let metadataData = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExtractionMetadata.self, from: metadataData)
        XCTAssertEqual(decoded.toolName, "TestSuite")
        XCTAssertEqual(decoded.sourceDescription, "SARS-CoV-2 test")

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenance = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: provenanceURL))
        XCTAssertEqual(provenance.name, "Classifier Read Extraction")
        XCTAssertEqual(provenance.status, .completed)
        XCTAssertEqual(provenance.steps.first?.toolName, "TestSuite")
        XCTAssertTrue(provenance.allOutputFiles.contains { $0.path.hasSuffix("extraction-metadata.json") })
        XCTAssertTrue(provenance.allOutputFiles.contains { $0.path.hasSuffix(".fastq") })
    }

    // MARK: - BAMRegionMatcher with Real BAM

    /// Verifies that BAMRegionMatcher correctly reads references from the fixture BAM.
    func testBAMRegionMatcherReadsRealHeader() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam
        let refs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: bamURL,
            runner: .shared
        )
        XCTAssertEqual(refs, ["MT192765.1"],
                       "Fixture BAM should have exactly MT192765.1 as reference")
    }

    /// Verifies exact matching works against a real BAM header.
    func testBAMRegionMatcherExactMatchAgainstFixture() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam
        let refs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: bamURL,
            runner: .shared
        )
        let result = BAMRegionMatcher.match(regions: ["MT192765.1"], againstReferences: refs)
        XCTAssertEqual(result.strategy, .exact)
        XCTAssertEqual(result.matchedRegions, ["MT192765.1"])
    }

    // MARK: - Database Extraction (NAO-MGS)

    /// Extracts reads from a test SQLite database matching the NAO-MGS schema.
    /// This is the path used by NAO-MGS "Extract FASTQ" in the app.
    func testExtractFromDatabaseByTaxId() async throws {
        let dbURL = try createTestNaoMgsDatabase()
        let config = DatabaseExtractionConfig(
            databaseURL: dbURL,
            sampleId: "test_sample",
            taxIds: [11137],
            outputDirectory: tempDir,
            outputBaseName: "db_extract"
        )

        let result = try await service.extractFromDatabase(config: config)
        XCTAssertEqual(result.readCount, 5, "Should extract all 5 reads for taxid 11137")
        XCTAssertFalse(result.pairedEnd)

        // Verify FASTQ content
        let content = try String(contentsOf: result.fastqURLs[0], encoding: .utf8)
        let headers = content.components(separatedBy: "\n").filter { $0.hasPrefix("@") }
        XCTAssertEqual(headers.count, 5)
        XCTAssertTrue(headers.contains("@read_001"))
        XCTAssertTrue(headers.contains("@read_005"))
    }

    /// Verifies that accession-based extraction works.
    func testExtractFromDatabaseByAccession() async throws {
        let dbURL = try createTestNaoMgsDatabase()
        let config = DatabaseExtractionConfig(
            databaseURL: dbURL,
            sampleId: "test_sample",
            accessions: ["AF304460.1"],
            outputDirectory: tempDir,
            outputBaseName: "acc_extract"
        )

        let result = try await service.extractFromDatabase(config: config)
        XCTAssertGreaterThan(result.readCount, 0, "Should extract reads for accession AF304460.1")
    }

    /// Verifies that a nonexistent taxid produces an empty extraction error.
    func testExtractFromDatabaseNoMatchingTaxId() async throws {
        let dbURL = try createTestNaoMgsDatabase()
        let config = DatabaseExtractionConfig(
            databaseURL: dbURL,
            sampleId: "test_sample",
            taxIds: [999999],
            outputDirectory: tempDir,
            outputBaseName: "nomatch"
        )

        do {
            _ = try await service.extractFromDatabase(config: config)
            XCTFail("Should throw emptyExtraction for nonexistent taxid")
        } catch let error as ExtractionError {
            if case .emptyExtraction = error {
                // expected
            } else {
                XCTFail("Expected emptyExtraction, got \(error)")
            }
        }
    }

    /// Verifies that maxReads limit is respected.
    func testExtractFromDatabaseMaxReads() async throws {
        let dbURL = try createTestNaoMgsDatabase()
        let config = DatabaseExtractionConfig(
            databaseURL: dbURL,
            sampleId: "test_sample",
            taxIds: [11137],
            maxReads: 2,
            outputDirectory: tempDir,
            outputBaseName: "limited"
        )

        let result = try await service.extractFromDatabase(config: config)
        XCTAssertEqual(result.readCount, 2, "Should respect maxReads limit")
    }

    /// Verifies that output filenames with special characters are sanitized.
    func testExtractFromDatabaseSanitizesFilename() async throws {
        let dbURL = try createTestNaoMgsDatabase()
        let config = DatabaseExtractionConfig(
            databaseURL: dbURL,
            sampleId: "test_sample",
            taxIds: [11137],
            outputDirectory: tempDir,
            outputBaseName: "NAO: sample_Human coronavirus 229E_extract"
        )

        let result = try await service.extractFromDatabase(config: config)
        let fastqFilename = result.fastqURLs[0].lastPathComponent

        XCTAssertFalse(fastqFilename.contains(":"), "Filename should not contain colons")
        XCTAssertFalse(fastqFilename.contains(" "), "Filename should not contain spaces")
        XCTAssertTrue(fastqFilename.hasSuffix(".fastq"), "Should end with .fastq")
        XCTAssertGreaterThan(result.readCount, 0)
    }

    /// Verifies that BAM extraction also sanitizes filenames.
    func testExtractByBAMRegionSanitizesFilename() async throws {
        let bamURL = TestFixtures.sarscov2.sortedBam
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: ["MT192765.1"],
            fallbackToAll: false,
            outputDirectory: tempDir,
            outputBaseName: "Sample: Human coronavirus OC43_extract"
        )

        let result = try await service.extractByBAMRegion(config: config)
        let fastqFilename = result.fastqURLs[0].lastPathComponent

        XCTAssertFalse(fastqFilename.contains(":"), "Filename should not contain colons")
        XCTAssertFalse(fastqFilename.contains(" "), "Filename should not contain spaces")
        XCTAssertGreaterThan(result.readCount, 0)
    }

    // MARK: - Helpers

    /// Creates a small SQLite database matching the NAO-MGS schema for testing.
    ///
    /// Contains 5 reads for taxid 11137 (Human coronavirus 229E) and 3 reads
    /// for taxid 694009 (Betapolyomavirus hominis), all under sample "test_sample".
    private func createTestNaoMgsDatabase() throws -> URL {
        let dbURL = tempDir.appendingPathComponent("test_hits.sqlite")

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "TestDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create test DB"])
        }
        defer { sqlite3_close(db) }

        // Create tables matching the full NAO-MGS schema (including columns
        // added post-initial release: pcr_duplicate_count, accession_count,
        // top_accessions_json, and the reference_lengths table).
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
        """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db)!)
            throw NSError(domain: "TestDB", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // Insert test reads — 5 for HCoV-229E (taxid 11137), 3 for BK polyomavirus (taxid 694009)
        let seq = "ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG"
        let qual = "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII"

        let insertSQL = """
        INSERT INTO virus_hits (sample, seq_id, tax_id, subject_seq_id, subject_title, ref_start, cigar, read_sequence, read_quality, percent_identity, bit_score, e_value, edit_distance, query_length, is_reverse_complement, pair_status, fragment_length, best_alignment_score)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db)!)
            throw NSError(domain: "TestDB", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        defer { sqlite3_finalize(stmt) }

        struct TestRead {
            let sample: String
            let seqId: String
            let taxId: Int
            let accession: String
            let title: String
        }

        let reads: [TestRead] = [
            TestRead(sample: "test_sample", seqId: "read_001", taxId: 11137, accession: "AF304460.1", title: "Human coronavirus 229E"),
            TestRead(sample: "test_sample", seqId: "read_002", taxId: 11137, accession: "AF304460.1", title: "Human coronavirus 229E"),
            TestRead(sample: "test_sample", seqId: "read_003", taxId: 11137, accession: "AF304460.1", title: "Human coronavirus 229E"),
            TestRead(sample: "test_sample", seqId: "read_004", taxId: 11137, accession: "KT253324.1", title: "Human coronavirus 229E"),
            TestRead(sample: "test_sample", seqId: "read_005", taxId: 11137, accession: "KT253324.1", title: "Human coronavirus 229E"),
            TestRead(sample: "test_sample", seqId: "read_006", taxId: 694009, accession: "NC_009539.1", title: "BK polyomavirus"),
            TestRead(sample: "test_sample", seqId: "read_007", taxId: 694009, accession: "NC_009539.1", title: "BK polyomavirus"),
            TestRead(sample: "test_sample", seqId: "read_008", taxId: 694009, accession: "NC_009539.1", title: "BK polyomavirus"),
        ]

        for read in reads {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (read.sample as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (read.seqId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 3, Int64(read.taxId))
            sqlite3_bind_text(stmt, 4, (read.accession as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (read.title as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 6, 100)  // ref_start
            sqlite3_bind_text(stmt, 7, "98M", -1, nil)  // cigar
            sqlite3_bind_text(stmt, 8, (seq as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 9, (qual as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 10, 98.5)  // percent_identity
            sqlite3_bind_double(stmt, 11, 150.0)  // bit_score
            sqlite3_bind_double(stmt, 12, 1e-30)  // e_value
            sqlite3_bind_int(stmt, 13, 2)  // edit_distance
            sqlite3_bind_int(stmt, 14, 98)  // query_length
            sqlite3_bind_int(stmt, 15, 0)  // is_reverse_complement
            sqlite3_bind_text(stmt, 16, "CP", -1, nil)  // pair_status
            sqlite3_bind_int(stmt, 17, 300)  // fragment_length
            sqlite3_bind_double(stmt, 18, 150.0)  // best_alignment_score

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db)!)
                throw NSError(domain: "TestDB", code: 4, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }

        // Insert taxon summaries (with full schema columns)
        let taxonSQL = """
        INSERT INTO taxon_summaries (sample, tax_id, name, hit_count, unique_read_count, avg_identity, avg_bit_score, avg_edit_distance, pcr_duplicate_count, accession_count, top_accessions_json)
        VALUES ('test_sample', 11137, 'Human coronavirus 229E', 5, 5, 98.5, 150.0, 2.0, 0, 2, '["AF304460.1","KT253324.1"]'),
               ('test_sample', 694009, 'BK polyomavirus', 3, 3, 98.5, 150.0, 2.0, 0, 1, '["NC_009539.1"]');
        """
        guard sqlite3_exec(db, taxonSQL, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db)!)
            throw NSError(domain: "TestDB", code: 5, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        return dbURL
    }

    /// Extracts the first N read IDs from a (possibly gzipped) FASTQ file.
    private func extractReadIDsFromFASTQ(_ url: URL, count: Int) throws -> [String] {
        let process = Process()
        if url.pathExtension.lowercased() == "gz" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzcat")
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
        }
        process.arguments = [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let content = String(data: data, encoding: .utf8) ?? ""
        let lines = content.components(separatedBy: "\n")

        var ids: [String] = []
        for (index, line) in lines.enumerated() {
            guard ids.count < count else { break }
            if index % 4 == 0, line.hasPrefix("@") {
                // Extract the read ID (first whitespace-separated token, without @)
                let id = String(line.dropFirst()).components(separatedBy: .whitespaces).first ?? ""
                if !id.isEmpty {
                    // Strip /1 or /2 suffix if present
                    let cleanID: String
                    if id.hasSuffix("/1") || id.hasSuffix("/2") {
                        cleanID = String(id.dropLast(2))
                    } else {
                        cleanID = id
                    }
                    ids.append(cleanID)
                }
            }
        }
        return ids
    }
}

// MARK: - ProgressAccumulator

/// Thread-safe progress callback collector for synchronous progress closures.
private final class ProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Double, String)] = []

    func append(_ fraction: Double, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((fraction, message))
    }

    func getCalls() -> [(Double, String)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
