// NaoMgsBamMaterializerTests.swift - Tests for NaoMgsBamMaterializer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import CryptoKit
import OSLog
import LungfishTestSupport
@testable import LungfishIO

final class NaoMgsBamMaterializerTests: XCTestCase {

    private struct ProcessOutput {
        let exitCode: Int32
        let stdout: String
    }

    private var samtoolsPath: String {
        BamFixtureBuilder.locateSamtools() ?? ""
    }

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsMaterializerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runProcess(executable: String, arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessOutput(exitCode: process.terminationStatus, stdout: out)
    }

    /// Creates a minimal NAO-MGS SQLite database with one sample and a handful of virus_hits rows.
    /// Schema matches the real NaoMgsDatabase schema (R1 fields are nullable for R2-only rows).
    func makeTestDatabase(at dbURL: URL, sample: String = "S1", duplicateCount: Int = 3) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db,
                               SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE virus_hits (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            seq_id TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            subject_seq_id TEXT NOT NULL,
            subject_title TEXT NOT NULL,
            ref_start INTEGER,
            cigar TEXT,
            read_sequence TEXT,
            read_quality TEXT,
            percent_identity REAL NOT NULL,
            bit_score REAL NOT NULL,
            e_value REAL NOT NULL,
            edit_distance INTEGER,
            query_length INTEGER,
            is_reverse_complement INTEGER,
            pair_status TEXT NOT NULL,
            fragment_length INTEGER NOT NULL,
            best_alignment_score REAL,
            ref_start_rev INTEGER,
            read_sequence_rev TEXT,
            read_quality_rev TEXT,
            edit_distance_rev INTEGER,
            query_length_rev INTEGER,
            is_reverse_complement_rev INTEGER,
            best_alignment_score_rev REAL
        );
        CREATE TABLE reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL);
        CREATE TABLE taxon_summaries (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            hit_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL,
            avg_identity REAL NOT NULL,
            avg_bit_score REAL NOT NULL,
            avg_edit_distance REAL NOT NULL,
            pcr_duplicate_count INTEGER NOT NULL,
            accession_count INTEGER NOT NULL,
            top_accessions_json TEXT NOT NULL,
            bam_path TEXT,
            bam_index_path TEXT,
            PRIMARY KEY (sample, tax_id)
        );
        """
        sqlite3_exec(db, schema, nil, nil, nil)

        sqlite3_exec(db, "INSERT INTO reference_lengths VALUES ('NC_001', 1000)", nil, nil, nil)
        sqlite3_exec(db, """
            INSERT INTO taxon_summaries VALUES (
                '\(sample)', 1, 'Test virus', \(duplicateCount), \(duplicateCount),
                99.0, 100.0, 0.0, 0, 1, '[]', NULL, NULL
            )
            """, nil, nil, nil)

        // Insert `duplicateCount` rows at identical position (will become duplicates after markdup)
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        for i in 0..<duplicateCount {
            let sql = """
            INSERT INTO virus_hits VALUES (
                NULL, '\(sample)', 'read\(i)', 1, 'NC_001', 'Test virus',
                100, '50M', '\(seq)', '\(qual)', 99.0, 100.0, 0.001, 0, 50, 0,
                'unpaired', 50, 90.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
            )
            """
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    private func makePairedTestDatabase(at dbURL: URL, sample: String = "S1") throws {
        try makeTestDatabase(at: dbURL, sample: sample, duplicateCount: 0)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        defer { sqlite3_close(db) }

        let mate1 = String(repeating: "A", count: 50)
        let mate2 = String(repeating: "T", count: 50)
        let qual = String(repeating: "I", count: 50)
        let sql = """
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'paired_read', 1, 'NC_001', 'Test virus',
            800, '50M', '\(mate1)', '\(qual)', 99.0, 100.0, 0.001, 0, 50, 1,
            'CP', 250, 90.0, 500, '\(mate2)', '\(qual)', 1, 50, 0, 91.0
        )
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Creates a database with an R2-only row (R1 fields are NULL, R2 fields are populated).
    private func makeR2OnlyTestDatabase(at dbURL: URL, sample: String = "S1") throws {
        try makeTestDatabase(at: dbURL, sample: sample, duplicateCount: 0)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        defer { sqlite3_close(db) }

        let r2Seq = String(repeating: "C", count: 75)
        let r2Qual = String(repeating: "H", count: 75)

        // R2-only: ref_start is NULL, cigar/read_sequence/read_quality are NULL,
        // but R2 columns have valid data.
        let sql = """
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'r2only_read', 1, 'NC_001', 'Test virus',
            NULL, NULL, NULL, NULL,
            99.0, 100.0, 0.001, 0, 0, 0,
            'R2', 0, 0.0,
            200, '\(r2Seq)', '\(r2Qual)', 2, 75, 1, 88.0
        )
        """
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        XCTAssertEqual(rc, SQLITE_OK, "R2-only INSERT should succeed; got \(rc)")
    }

    /// Creates a database with a mix: one paired row, one R1-only row, and one R2-only row.
    private func makeMixedTestDatabase(at dbURL: URL, sample: String = "S1") throws {
        try makeTestDatabase(at: dbURL, sample: sample, duplicateCount: 0)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        defer { sqlite3_close(db) }

        let seq50 = String(repeating: "A", count: 50)
        let qual50 = String(repeating: "I", count: 50)
        let seqR2 = String(repeating: "G", count: 60)
        let qualR2 = String(repeating: "J", count: 60)

        // Row 1: Paired (both R1 + R2)
        sqlite3_exec(db, """
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'paired_read', 1, 'NC_001', 'Test virus',
            100, '50M', '\(seq50)', '\(qual50)', 99.0, 100.0, 0.001, 0, 50, 0,
            'CP', 200, 90.0, 300, '\(seq50)', '\(qual50)', 1, 50, 1, 91.0
        )
        """, nil, nil, nil)

        // Row 2: R1 only
        sqlite3_exec(db, """
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'r1only_read', 1, 'NC_001', 'Test virus',
            500, '50M', '\(seq50)', '\(qual50)', 99.0, 100.0, 0.001, 0, 50, 0,
            'R1', 50, 90.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        )
        """, nil, nil, nil)

        // Row 3: R2 only (R1 fields NULL)
        sqlite3_exec(db, """
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'r2only_read', 1, 'NC_001', 'Test virus',
            NULL, NULL, NULL, NULL,
            99.0, 100.0, 0.001, 0, 0, 0,
            'R2', 0, 0.0,
            700, '\(seqR2)', '\(qualR2)', 2, 60, 1, 88.0
        )
        """, nil, nil, nil)
    }

    func testMaterializeSingleSample() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        XCTAssertEqual(generated.count, 1)
        let bamURL = generated[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path + ".bai"))
    }

    func testMaterializeWithProvenanceRecordsSubprocessSteps() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let result = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath,
            samtoolsVersion: "samtools-test"
        )

        let bamURL = try XCTUnwrap(result.bamURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path + ".bai"))
        XCTAssertFalse(result.steps.isEmpty)
        XCTAssertTrue(result.steps.contains { $0.toolName == "lungfish nao-mgs materialize-bam" })
        XCTAssertTrue(result.steps.contains { $0.toolName == "samtools" })
        XCTAssertTrue(result.steps.filter { $0.toolName == "samtools" }.allSatisfy { $0.toolVersion == "samtools-test" })
        XCTAssertFalse(result.steps.contains { $0.argv.first == "/bin/sh" })
        XCTAssertEqual(result.steps.filter { $0.parentStepID != nil }.map { $0.argv[1] }, ["sort", "fixmate", "sort",
            "markdup", "index"])
        XCTAssertTrue(result.steps.contains { $0.reproducibleCommand.contains("samtools") })
        XCTAssertTrue(result.steps.contains { step in
            step.outputURLs.contains(bamURL)
                && step.exitStatus == 0
                && step.wallTimeSeconds != nil
        })
    }

    func testMaterializeDuplicatesAreMarked() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 5)

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        let bamURL = generated[0]
        // After markdup, non-duplicate count should be less than total (5)
        let total = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath
        )
        let nonDup = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath
        )
        XCTAssertEqual(total, 5)
        XCTAssertLessThan(nonDup, total, "Some reads should be flagged as duplicates")
    }

    func testMaterializeIdempotent() async throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let first = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtoolsPath
        )
        let firstMtime = (try? FileManager.default.attributesOfItem(atPath: first[0].path)[.modificationDate]) as? Date

        try await Task.sleep(nanoseconds: 1_100_000_000)

        let second = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtoolsPath
        )
        let secondMtime = (try? FileManager.default.attributesOfItem(atPath: second[0].path)[.modificationDate]) as? Date

        XCTAssertEqual(firstMtime, secondMtime, "Second call should be a no-op")
    }

    func testMaterializePairedRowEmitsBothMates() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makePairedTestDatabase(at: dbURL, sample: "S1")

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        let bamURL = try XCTUnwrap(generated.first)
        let output = try runProcess(executable: samtoolsPath, arguments: ["view", bamURL.path])
        XCTAssertEqual(output.exitCode, 0)

        let lines = output.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "Paired NAO-MGS rows should emit both mates into the BAM")

        let fields = lines.map { $0.split(separator: "\t").map(String.init) }
        XCTAssertEqual(fields[0][0], "paired_read")
        XCTAssertEqual(fields[1][0], "paired_read")
        XCTAssertEqual(fields[0][2], "NC_001")
        XCTAssertEqual(fields[1][2], "NC_001")

        let positions = Set(fields.compactMap { Int($0[3]) })
        XCTAssertEqual(positions, Set([501, 801]))
    }

    func testMaterializeR2OnlyRowEmitsSingleRecord() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeR2OnlyTestDatabase(at: dbURL, sample: "S1")

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        XCTAssertEqual(generated.count, 1, "R2-only sample should produce a BAM")
        let bamURL = try XCTUnwrap(generated.first)
        let output = try runProcess(executable: samtoolsPath, arguments: ["view", bamURL.path])
        XCTAssertEqual(output.exitCode, 0)

        let lines = output.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1, "R2-only row should emit exactly one SAM record")

        let fields = lines[0].split(separator: "\t").map(String.init)
        XCTAssertEqual(fields[0], "r2only_read", "QNAME should match seq_id")
        XCTAssertEqual(fields[2], "NC_001", "RNAME should match subject_seq_id")

        // Position should be ref_start_rev + 1 = 201 (1-based SAM)
        XCTAssertEqual(Int(fields[3]), 201, "POS should be ref_start_rev + 1")

        // CIGAR should be 75M (query_length_rev = 75)
        XCTAssertEqual(fields[5], "75M", "CIGAR should be query_length_rev + M")

        // Flag: is_reverse_complement_rev = 1, so flag = 16 (reverse strand, unpaired)
        let flag = Int(fields[1]) ?? 0
        XCTAssertEqual(flag, 16, "Flag should be 16 for reverse-complemented unpaired R2")

        // Sequence should be the R2 sequence (75 Cs)
        XCTAssertEqual(fields[9], String(repeating: "C", count: 75), "Sequence should be R2 data")

        // Quality should be the R2 quality (75 Hs)
        XCTAssertEqual(fields[10], String(repeating: "H", count: 75), "Quality should be R2 data")

        // RNEXT/PNEXT/TLEN should be unmapped mate markers
        XCTAssertEqual(fields[6], "*", "RNEXT should be * for unpaired")
        XCTAssertEqual(fields[7], "0", "PNEXT should be 0 for unpaired")
        XCTAssertEqual(fields[8], "0", "TLEN should be 0 for unpaired")
    }

    func testMaterializeMixedRowsEmitsCorrectCounts() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeMixedTestDatabase(at: dbURL, sample: "S1")

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        let bamURL = try XCTUnwrap(generated.first)
        let output = try runProcess(executable: samtoolsPath, arguments: ["view", bamURL.path])
        XCTAssertEqual(output.exitCode, 0)

        let lines = output.stdout.split(separator: "\n").map(String.init)
        // Paired row: 2 records, R1-only: 1 record, R2-only: 1 record = 4 total
        XCTAssertEqual(lines.count, 4, "Mixed DB should emit 4 SAM records (2 paired + 1 R1-only + 1 R2-only)")

        let qnames = lines.map { $0.split(separator: "\t").first.map(String.init) ?? "" }
        XCTAssertEqual(qnames.filter { $0 == "paired_read" }.count, 2, "Paired row should produce 2 records")
        XCTAssertEqual(qnames.filter { $0 == "r1only_read" }.count, 1, "R1-only row should produce 1 record")
        XCTAssertEqual(qnames.filter { $0 == "r2only_read" }.count, 1, "R2-only row should produce 1 record")
    }

    func testMaterializeR2OnlyForwardStrand() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")

        // Create DB with R2-only row on forward strand (is_reverse_complement_rev = 0)
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 0)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        let r2Seq = String(repeating: "T", count: 40)
        let r2Qual = String(repeating: "F", count: 40)
        sqlite3_exec(db, """
        INSERT INTO virus_hits VALUES (
            NULL, 'S1', 'fwd_r2_read', 1, 'NC_001', 'Test virus',
            NULL, NULL, NULL, NULL,
            99.0, 100.0, 0.001, 0, 0, 0,
            'R2', 0, 0.0,
            400, '\(r2Seq)', '\(r2Qual)', 1, 40, 0, 85.0
        )
        """, nil, nil, nil)
        sqlite3_close(db)

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        XCTAssertEqual(generated.count, 1, "R2-only forward-strand sample should produce a BAM")
        let bamURL = try XCTUnwrap(generated.first)
        let output = try runProcess(executable: samtoolsPath, arguments: ["view", bamURL.path])
        XCTAssertEqual(output.exitCode, 0)

        let lines = output.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1)

        let fields = lines[0].split(separator: "\t").map(String.init)
        let flag = Int(fields[1]) ?? -1
        XCTAssertEqual(flag, 0, "Flag should be 0 for forward-strand unpaired R2")
        XCTAssertEqual(Int(fields[3]), 401, "POS should be ref_start_rev + 1")
        XCTAssertEqual(fields[5], "40M", "CIGAR should use query_length_rev")
    }
}

// MARK: - Lane 13.09 M0, the freeze before generateBam moves onto ToolProcess (QA 1)

/// Each pin holds what the base gives, with the folder and the samtools path as `<TMP>` and `<SAMTOOLS>`. The BAM
/// pins skip the markdup pass, so they hold the pipeline's own output, whose `@PG` `CL:` lines carry each argv.
extension NaoMgsBamMaterializerTests {
    struct PinnedStep: Equatable {
        let tool: String
        let argv: [String]
        let exitStatus: Int?
        let stderr: String?
        let outputs: [String]
        /// The parent's index in the same list.
        var parent: Int? = nil
        var stdinPipe: String? = nil
        var stdoutPipe: String? = nil
        /// Both the wall time and the start are present.
        var timed = true

        func erasingStderr() -> PinnedStep {
            PinnedStep(tool: tool, argv: argv, exitStatus: exitStatus, stderr: nil, outputs: outputs, parent: parent,
                       stdinPipe: stdinPipe, stdoutPipe: stdoutPipe, timed: timed)
        }
    }

    func testBAMTextOfEachRowShapeIsPinned() throws {
        try assertPinnedBAMText("8a568ec43ac1bbe1d656da3d4642c5c19cba1300d677f35462c39ddd5119154d") {
            try self.makeTestDatabase(at: $0, sample: "S1", duplicateCount: 3)
        }
        try assertPinnedBAMText("d888bb9655230cc69a402fc375fd265f7b789b1085e68f0728fa27f778587d57") {
            try self.makePairedTestDatabase(at: $0, sample: "S1")
        }
        try assertPinnedBAMText("5510ee6b01b2184d8bb660b2b317d6a404096b5015a5c42aa5d7eb2d76caa661") {
            try self.makeR2OnlyTestDatabase(at: $0, sample: "S1")
        }
    }

    /// Three runs on one database. The first makes the BAM alone. The second finds it with a samtools whose markdup
    /// fails, so it records the failed markdup and then the index. The third marks the duplicates.
    func testRecordedStepsOfAMaterializationArePinned() throws {
        let samtools = try pinSamtools()
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)
        let bam = "<TMP>/bams/S1.bam"

        let first = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: false)
        XCTAssertEqual(pinnedSteps(first.steps, tmp: tmp, samtools: samtools), [
            PinnedStep(tool: "lungfish nao-mgs materialize-bam", argv: materializeArgv(sample: "S1"),
                       exitStatus: 0, stderr: nil, outputs: [bam]),
        ])

        let failing = try makeFakeSamtools(in: tmp, body: """
            if [ "$1" = markdup ]; then cat > /dev/null; echo "fake samtools markdup failed" >&2; exit 1; fi
            exec \(samtools) "$@"
            """)
        let second = pinnedSteps(
            try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: failing, markDuplicates: true).steps,
            tmp: tmp, samtools: failing
        )
        XCTAssertEqual(second.map { $0.stderr != nil }, [true, false, false, false, false, false, false],
                       "Only the markdup call records the failure's error")
        XCTAssertEqual(second.map { $0.erasingStderr() }, pinnedMarkdupSteps(bam: bam, exitStatus: 1, stageExit: nil, outputs: []) + [
            PinnedStep(tool: "samtools", argv: ["<SAMTOOLS>", "index", bam], exitStatus: 0, stderr: nil, outputs: ["\(bam).bai"]),
        ])

        let third = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: true)
        XCTAssertEqual(pinnedSteps(third.steps, tmp: tmp, samtools: samtools),
                       pinnedMarkdupSteps(bam: bam, exitStatus: 0, stageExit: 0, outputs: [bam, "\(bam).bai"]))
    }

    /// The markdup call, then its five samtools stages under it, joined by `pipe:` paths (BIO-13.09-M2 item 7a).
    private func pinnedMarkdupSteps(bam: String, exitStatus: Int, stageExit: Int?, outputs: [String]) -> [PinnedStep] {
        let call = PinnedStep(
            tool: "lungfish nao-mgs markdup",
            argv: ["lungfish-internal", "nao-mgs-markdup", "--bam", bam, "--samtools", "<SAMTOOLS>", "--threads", "4"],
            exitStatus: exitStatus, stderr: nil, outputs: outputs
        )
        let stages: [(argv: [String], stdin: String?, stdout: String?)] = [
            (["<SAMTOOLS>", "sort", "-n", "-@", "4", bam], nil, "pipe:stdout:samtools-sort-n"),
            (["<SAMTOOLS>", "fixmate", "-m", "-", "-"], "pipe:stdout:samtools-sort-n", "pipe:stdout:samtools-fixmate"),
            (["<SAMTOOLS>", "sort", "-@", "4", "-"], "pipe:stdout:samtools-fixmate", "pipe:stdout:samtools-sort"),
            (["<SAMTOOLS>", "markdup", "-", "\(bam).markdup.tmp"], "pipe:stdout:samtools-sort", nil),
            (["<SAMTOOLS>", "index", "\(bam).markdup.tmp"], nil, nil),
        ]
        return [call] + stages.map {
            PinnedStep(tool: "samtools", argv: $0.argv, exitStatus: stageExit, stderr: nil, outputs: [], parent: 0,
                       stdinPipe: $0.stdin, stdoutPipe: $0.stdout, timed: false)
        }
    }

    /// Code 5 with the failing stage's stderr. Only the last stage fails, which `sh -c` and ToolProcess both report.
    func testAFailingLastStageGivesThePipelineFailureWords() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "PinLast", duplicateCount: 3)
        let fake = try makeFakeSamtools(in: tmp, body: """
            cat > /dev/null
            if [ "$1" = sort ]; then echo "fake samtools sort failed" >&2; exit 1; fi
            exit 0
            """)
        let start = Date()
        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: fake, markDuplicates: false)
        XCTAssertEqual(result.bamURLs, [])
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertEqual(try materializerWarnings(forSample: "PinLast", since: start), [
            "Failed to materialize BAM for sample PinLast: samtools pipeline failed: fake samtools sort failed",
        ])
    }

    /// Code 7. Each stage exits 1 after a second unread, and the rows overfill the pipe, so the writer is waiting.
    func testAStageThatStopsReadingGivesTheBrokenPipeWords() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "PinPipe", duplicateCount: 0)
        try addSingleEndRows(to: dbURL, sample: "PinPipe", count: 2000)
        let fake = try makeFakeSamtools(in: tmp, body: "sleep 1\nexit 1\n")
        let start = Date()
        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: fake, markDuplicates: false)
        XCTAssertEqual(result.bamURLs, [])
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertEqual(try materializerWarnings(forSample: "PinPipe", since: start), [
            "Failed to materialize BAM for sample PinPipe: Broken pipe writing SAM record for sample PinPipe",
        ])
    }

    /// Only the first stage fails. `sh -c` reported the last stage's status, so the base recorded a success with the
    /// first stage's stderr. The pipeline reports every stage, so the sample now fails (lane 13.09 prediction (b)).
    func testAFailingFirstStageAloneFailsTheSample() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "PinFirst", duplicateCount: 3)
        let fake = try makeFakeSamtools(in: tmp, body: """
            cat > /dev/null
            if [ "$1" = view ]; then echo "fake samtools view failed" >&2; exit 1; fi
            exit 0
            """)
        let start = Date()
        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: fake, markDuplicates: false)
        XCTAssertEqual(result.bamURLs, [])
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertEqual(try materializerWarnings(forSample: "PinFirst", since: start), [
            "Failed to materialize BAM for sample PinFirst: samtools pipeline failed: fake samtools view failed",
        ])
    }

    /// The real samtools rejects a row whose CIGAR and sequence lengths differ, exits 1 from `view`, and `sort` still
    /// writes the reads before it and exits 0. `sh -c` reported that as a success with a BAM short of reads
    /// (`build/lane/base-truncation.txt`), so this test fails at the base. Now the sample fails and keeps no BAM
    /// (BIO-13.09-M2 question 2, item 4).
    func testASAMRecordSamtoolsRejectsFailsTheSampleAndLeavesNoBAM() throws {
        let samtools = try pinSamtools()
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "PinReject", duplicateCount: 3)
        try addSingleEndRows(to: dbURL, sample: "PinReject", count: 1, sequenceLength: 50)
        let start = Date()
        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: false)
        XCTAssertEqual(result.bamURLs, [])
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("bams/PinReject.bam").path))
        let warnings = try materializerWarnings(forSample: "PinReject", since: start)
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings.first?.hasPrefix(
            "Failed to materialize BAM for sample PinReject: samtools pipeline failed:"
        ) == true, "\(warnings)")
    }

    // MARK: Pin helpers

    private func pinSamtools() throws -> String {
        guard let path = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        return path
    }

    func materializeForPin(dbURL: URL, tmp: URL, samtools: String, markDuplicates: Bool) throws -> NaoMgsBamMaterializationResult {
        try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtools,
            markDuplicates: markDuplicates, samtoolsVersion: "samtools-test", lungfishVersion: "test"
        )
    }

    private func materializeArgv(sample: String) -> [String] {
        ["lungfish-internal", "nao-mgs-materialize-bam", "--database", "<TMP>/naomgs.sqlite", "--sample", sample,
         "--output", "<TMP>/bams/\(sample).bam", "--samtools", "<SAMTOOLS>"]
    }

    /// The samtools path goes first, since a fake samtools lives in the folder.
    private func tokenized(_ text: String, tmp: URL, samtools: String) -> String {
        text.replacingOccurrences(of: samtools, with: "<SAMTOOLS>").replacingOccurrences(of: tmp.path, with: "<TMP>")
    }

    private func pinnedSteps(_ steps: [NaoMgsBamMaterializationStep], tmp: URL, samtools: String) -> [PinnedStep] {
        steps.map { step in
            PinnedStep(
                tool: step.toolName,
                argv: step.argv.map { tokenized($0, tmp: tmp, samtools: samtools) },
                exitStatus: step.exitStatus,
                stderr: step.stderr.map { tokenized($0, tmp: tmp, samtools: samtools) },
                outputs: step.outputURLs.map { tokenized($0.path, tmp: tmp, samtools: samtools) },
                parent: step.parentStepID.flatMap { parentID in steps.firstIndex { $0.id == parentID } },
                stdinPipe: step.stdinPipe,
                stdoutPipe: step.stdoutPipe,
                timed: step.wallTimeSeconds != nil && step.startedAt != nil
            )
        }
    }

    private func assertPinnedBAMText(
        _ expected: String, file: StaticString = #filePath, line: UInt = #line, build: (URL) throws -> Void
    ) throws {
        let samtools = try pinSamtools()
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try build(dbURL)
        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: false)
        let bamURL = try XCTUnwrap(result.bamURLs.first, file: file, line: line)
        let output = try runProcess(executable: samtools, arguments: ["view", "-h", bamURL.path])
        XCTAssertEqual(output.exitCode, 0, file: file, line: line)
        let text = tokenized(output.stdout, tmp: tmp, samtools: samtools)
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected, "samtools view -h text:\n\(text)", file: file, line: line)
    }

    func makeFakeSamtools(in tmp: URL, body: String) throws -> String {
        let url = tmp.appendingPathComponent("fake-samtools")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// `count` single-end rows at distinct positions, in one transaction. Each has CIGAR `100M`, and a
    /// `sequenceLength` other than 100 makes a row samtools rejects.
    func addSingleEndRows(to dbURL: URL, sample: String, count: Int, sequenceLength: Int = 100) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw NSError(domain: "test", code: 3) }
        defer { sqlite3_close(db) }
        let seq = String(repeating: "A", count: sequenceLength)
        let qual = String(repeating: "I", count: sequenceLength)
        var sql = "BEGIN;"
        for i in 0..<count {
            sql += """
            INSERT INTO virus_hits VALUES (NULL, '\(sample)', 'bulk\(i)', 1, 'NC_001', 'Test virus', \(i % 900),
            '100M', '\(seq)', '\(qual)', 99.0, 100.0, 0.001, 0, 100, 0, 'unpaired', 100, 90.0,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL);
            """
        }
        sql += "COMMIT;"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    /// The warnings the materializer logged for `sample` since `start`, read back from this process's log.
    func materializerWarnings(forSample sample: String, since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "com.lungfish.io", "NaoMgsBamMaterializer")
        return try store.getEntries(at: store.position(date: start), matching: predicate)
            .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
            .filter { $0.contains("for sample \(sample):") }
    }
}
