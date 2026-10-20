// MarkdupServiceSpawnConformanceTests.swift - Real-samtools pins of the MarkdupService pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import CryptoKit
import LungfishTestSupport
@testable import LungfishIO

/// Lane 13.10, M0. Both tests need a real samtools, so the class name holds `Conformance` and the unit tier
/// skips it. They pass at the base, where `MarkdupService` runs its four stages through `/bin/sh -c`, and stay
/// unchanged once the stages run as a `ToolProcess` pipeline.
final class MarkdupServiceSpawnConformanceTests: XCTestCase {

    private func pinSamtools() throws -> String {
        guard let path = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        return path
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdupSpawnConformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The script `MarkdupService` handed to `/bin/sh -c` at the base, kept here as the reference. Its
    /// backslash-newline pairs join the four commands onto one line, as they did in the source.
    private static let referenceScript = """
    set -o pipefail
    "$1" sort -n -@ "$2" "$3" | \
    "$1" fixmate -m - - | \
    "$1" sort -@ "$2" - | \
    "$1" markdup - "$4"
    """

    /// Five reads at one position, so four of them become duplicates.
    private func makeBamWithDuplicates(at url: URL, samtools: String) throws {
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        let reads = (0..<5).map { i in
            BamFixtureBuilder.Read(qname: "read\(i)", flag: 0, rname: "chr1", pos: 100, mapq: 60, cigar: "50M", seq: seq, qual: qual)
        }
        try BamFixtureBuilder.makeBAM(
            at: url, references: [BamFixtureBuilder.Reference(name: "chr1", length: 1000)], reads: reads, samtoolsPath: samtools
        )
    }

    /// `samtools view -h` of a BAM with its folder, the samtools path and the version replaced by tokens.
    private func headerAndReads(of bam: URL, samtools: String, folders: [URL]) throws -> String {
        let result = try ProcessRunner.run(URL(fileURLWithPath: samtools), ["view", "-h", bam.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        // The reference copy carries the header lines the fixture wrote in the first folder.
        return folders.reduce(result.stdout) { $0.replacingOccurrences(of: $1.path, with: "<DIR>") }
            .replacingOccurrences(of: samtools, with: "<SAMTOOLS>")
            .replacingOccurrences(of: "VN:[0-9][0-9.]*", with: "VN:<VER>", options: .regularExpression)
    }

    func testAMarkdupRunLeavesTheTextTheShellScriptLeft() throws {
        let samtools = try pinSamtools()
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = root.appendingPathComponent("service/test.bam")
        let reference = root.appendingPathComponent("reference/test.bam")
        try makeBamWithDuplicates(at: service, samtools: samtools)
        try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: service, to: reference)

        let served = try MarkdupService.markdup(bamURL: service, samtoolsPath: samtools)
        XCTAssertEqual(served.totalReads, 5)
        XCTAssertEqual(served.duplicateReads, 4)

        let temp = reference.path + ".markdup.tmp"
        let ran = try ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", Self.referenceScript, "markdup-pipeline", samtools, "4", reference.path, temp]
        )
        XCTAssertEqual(ran.status, 0, ran.stderr)
        try FileManager.default.removeItem(at: reference)
        try FileManager.default.moveItem(atPath: temp, toPath: reference.path)

        let folders = [service, reference].map { $0.deletingLastPathComponent() }
        let serviceText = try headerAndReads(of: service, samtools: samtools, folders: folders)
        let referenceText = try headerAndReads(of: reference, samtools: samtools, folders: folders)
        XCTAssertEqual(serviceText, referenceText)

        // The four stages are recorded in the header with the arguments they ran with.
        let commands = serviceText.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("@PG"), let field = line.split(separator: "\t").first(where: { $0.hasPrefix("CL:") }) else { return nil }
            return String(field.dropFirst(3))
        }
        let expected = [
            " sort -n -@ 4 <DIR>/test.bam", " fixmate -m - -", " sort -@ 4 -", " markdup - <DIR>/test.bam.markdup.tmp",
        ]
        for tail in expected {
            XCTAssertEqual(commands.filter { $0.hasSuffix(tail) }.count, 1, "\(tail) in \(commands)")
        }
        // The digest of the text, for the lane report.
        let digest = SHA256.hash(data: Data(serviceText.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest.count, 64)
    }

    /// 13.09 records the markdup replay as one step per command of the script (BIO-13.09-M2), so the stages
    /// this service runs must be the first four of those records, argv for argv, argv[0] included.
    func testTheStagesMarkdupServiceRunsAreTheFirstFourSamtoolsRecordsOfTheNaoMgsMarkdup() throws {
        let samtools = try pinSamtools()
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let log = tmp.appendingPathComponent("calls.log")
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wrapper = bin.appendingPathComponent("samtools")
        try """
        #!/bin/sh
        { printf '%s\\037' "$0" "$@"; printf '\\n'; } >> "\(log.path)"
        exec "\(samtools)" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeNaoMgsDatabase(at: dbURL, sample: "S1", rows: 3)
        let result = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: wrapper.path,
            markDuplicates: true, samtoolsVersion: "samtools-test", lungfishVersion: "test"
        )

        let call = try XCTUnwrap(result.steps.first { $0.toolName == "lungfish nao-mgs markdup" })
        let records = result.steps.filter { $0.parentStepID == call.id && $0.toolName == "samtools" }.map(\.argv)
        XCTAssertEqual(records.count, 5)
        let bam = try XCTUnwrap(result.bamURLs.first).path
        let s = wrapper.path
        XCTAssertEqual(Array(records.prefix(4)), [
            [s, "sort", "-n", "-@", "4", bam],
            [s, "fixmate", "-m", "-", "-"],
            [s, "sort", "-@", "4", "-"],
            [s, "markdup", "-", bam + ".markdup.tmp"],
        ])

        let text = try String(contentsOf: log, encoding: .utf8)
        let calls = text.split(separator: "\n").map { line -> [String] in
            var parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            parts.removeLast()
            return parts
        }
        for record in records {
            XCTAssertEqual(calls.filter { $0 == record }.count, 1, "\(record)")
        }
    }

    /// A NAO-MGS database with one sample and `rows` single-end hits at one position, as the materializer reads it.
    private func makeNaoMgsDatabase(at dbURL: URL, sample: String, rows: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE virus_hits (
            rowid INTEGER PRIMARY KEY, sample TEXT NOT NULL, seq_id TEXT NOT NULL, tax_id INTEGER NOT NULL,
            subject_seq_id TEXT NOT NULL, subject_title TEXT NOT NULL, ref_start INTEGER, cigar TEXT,
            read_sequence TEXT, read_quality TEXT, percent_identity REAL NOT NULL, bit_score REAL NOT NULL,
            e_value REAL NOT NULL, edit_distance INTEGER, query_length INTEGER, is_reverse_complement INTEGER,
            pair_status TEXT NOT NULL, fragment_length INTEGER NOT NULL, best_alignment_score REAL,
            ref_start_rev INTEGER, read_sequence_rev TEXT, read_quality_rev TEXT, edit_distance_rev INTEGER,
            query_length_rev INTEGER, is_reverse_complement_rev INTEGER, best_alignment_score_rev REAL
        );
        CREATE TABLE reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL);
        CREATE TABLE taxon_summaries (
            sample TEXT NOT NULL, tax_id INTEGER NOT NULL, name TEXT NOT NULL, hit_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL, avg_identity REAL NOT NULL, avg_bit_score REAL NOT NULL,
            avg_edit_distance REAL NOT NULL, pcr_duplicate_count INTEGER NOT NULL, accession_count INTEGER NOT NULL,
            top_accessions_json TEXT NOT NULL, bam_path TEXT, bam_index_path TEXT, PRIMARY KEY (sample, tax_id)
        );
        INSERT INTO reference_lengths VALUES ('NC_001', 1000);
        INSERT INTO taxon_summaries VALUES ('\(sample)', 1, 'Test virus', \(rows), \(rows), 99.0, 100.0, 0.0, 0, 1, '[]', NULL, NULL);
        """
        sqlite3_exec(db, schema, nil, nil, nil)
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        for i in 0..<rows {
            sqlite3_exec(db, """
            INSERT INTO virus_hits VALUES (
                NULL, '\(sample)', 'read\(i)', 1, 'NC_001', 'Test virus',
                100, '50M', '\(seq)', '\(qual)', 99.0, 100.0, 0.001, 0, 50, 0,
                'unpaired', 50, 90.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
            )
            """, nil, nil, nil)
        }
    }
}
