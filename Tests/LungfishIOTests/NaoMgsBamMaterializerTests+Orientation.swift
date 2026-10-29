// NaoMgsBamMaterializerTests+Orientation.swift - The NAO-MGS BAM holds a reverse-flagged record on the reference strand
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane NAO-BAM-ORIENT (BIO ruling BIO-NAO-BAM-ORIENT, section 6). NAO-MGS holds each mate as the instrument
// sequenced it and names the strand it aligned to in `prim_align_query_rc`. SAM wants a record flagged 0x10 to hold the
// reverse complement of the read with its qualities reversed, and `samtools fastq` undoes exactly that. This test
// reaches all four write sites of the materializer (a pair with either mate reversed, and a single R1 or R2 read) and
// the qualities, which the extraction tests do not, since the fixture reads there all have one quality value.

import XCTest
import SQLite3
import LungfishTestSupport
@testable import LungfishIO

extension NaoMgsBamMaterializerTests {
    private struct SequencedMate {
        let sequence: String
        let quality: String
    }

    private struct BAMRecord {
        let name: String
        let flag: Int
        let sequence: String
        let quality: String

        /// The name `samtools fastq` gives the record, which adds `/1` or `/2` for a READ1 or READ2 flag.
        var fastqName: String {
            name + (flag & 0x40 != 0 ? "/1" : flag & 0x80 != 0 ? "/2" : "")
        }
    }

    /// Four rows, each with a mate whose strand flag is 1, as a NAO-MGS import stores them (reads as sequenced). Every
    /// reverse mate is `AAAACCCCGG` with quality `ABCDEFGHIJ`, which is `CCGGGGTTTT` and `JIHGFEDCBA` on the reference
    /// strand. Each forward mate has bytes of its own.
    func testMaterializerStoresReverseFlaggedRecordsOnTheReferenceStrand() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 0)
        try addOrientationRows(to: dbURL, sample: "S1")

        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: false)
        let bam = try XCTUnwrap(result.bamURLs.first)

        let reverse = SequencedMate(sequence: "AAAACCCCGG", quality: "ABCDEFGHIJ")
        let sequenced: [String: SequencedMate] = [
            "pairR1Reverse/1": reverse,
            "pairR1Reverse/2": SequencedMate(sequence: "GATTACAGAT", quality: "KLMNOPQRST"),
            "pairR2Reverse/1": SequencedMate(sequence: "TGCATTGACA", quality: "LMNOPQRSTU"),
            "pairR2Reverse/2": reverse,
            "singleR1Reverse": reverse,
            "singleR2Reverse": reverse,
        ]
        let flags: [String: Int] = [
            "pairR1Reverse/1": 83, "pairR1Reverse/2": 163, "pairR2Reverse/1": 99, "pairR2Reverse/2": 147,
            "singleR1Reverse": 16, "singleR2Reverse": 16,
        ]

        // The BAM: a 0x10 record is on the reference strand, every other record is as sequenced.
        let records = try orientationSamtoolsText(samtools, ["view", bam.path])
            .split(separator: "\n").map { line -> BAMRecord in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return BAMRecord(name: fields[0], flag: Int(fields[1]) ?? -1, sequence: fields[9], quality: fields[10])
            }
        XCTAssertEqual(records.map(\.fastqName).sorted(), sequenced.keys.sorted(), "the BAM holds the six mates of the four rows")
        var reverseFlagged = 0
        for record in records {
            guard let mate = sequenced[record.fastqName] else { continue }
            XCTAssertEqual(record.flag, flags[record.fastqName], "flag of \(record.fastqName)")
            if record.flag & 0x10 != 0 {
                reverseFlagged += 1
                XCTAssertEqual(record.sequence, "CCGGGGTTTT", "SEQ of \(record.fastqName), flag \(record.flag)")
                XCTAssertEqual(record.quality, "JIHGFEDCBA", "QUAL of \(record.fastqName), flag \(record.flag)")
            } else {
                XCTAssertEqual(record.sequence, mate.sequence, "SEQ of \(record.fastqName), flag \(record.flag)")
                XCTAssertEqual(record.quality, mate.quality, "QUAL of \(record.fastqName), flag \(record.flag)")
            }
        }
        XCTAssertEqual(reverseFlagged, 4, "four of the records carry flag 0x10")

        // `samtools fastq` reverse-complements each 0x10 record back, so it writes every mate as it was sequenced.
        let byName = tmp.appendingPathComponent("by-name.bam")
        _ = try orientationSamtoolsText(samtools, ["sort", "-n", "-o", byName.path, bam.path])
        let lines = try orientationSamtoolsText(samtools, ["fastq", byName.path])
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var written: [String: SequencedMate] = [:]
        var index = 0
        while index + 3 < lines.count {
            written[String(lines[index].dropFirst())] = SequencedMate(sequence: lines[index + 1], quality: lines[index + 3])
            index += 4
        }
        XCTAssertEqual(written.keys.sorted(), sequenced.keys.sorted(), "samtools fastq writes the six mates")
        for (name, mate) in sequenced {
            XCTAssertEqual(written[name]?.sequence, mate.sequence, "samtools fastq SEQ of \(name)")
            XCTAssertEqual(written[name]?.quality, mate.quality, "samtools fastq QUAL of \(name)")
        }
    }

    /// Lane NAO-BAM-STALE tells a BAM built before the orientation fix by the version on the materializer's `@PG` line,
    /// `VN:1.0` before the fix and `VN:1.1` after. samtools keeps the earlier `@PG` lines through fixmate, sort and
    /// markdup, so the line must be in the BAM the import keeps, which is the one after markdup.
    func testTheMaterializerHeaderLineNamesTheFixAndSurvivesMarkdup() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: samtools, markDuplicates: true)
        let bam = try XCTUnwrap(result.bamURLs.first)
        let header = try orientationSamtoolsText(samtools, ["view", "-H", bam.path]).split(separator: "\n").map(String.init)
        let line = header.first { $0.hasPrefix("@PG") && $0.contains("ID:lungfish-naomgs-materializer") }
        XCTAssertNotNil(line, "the BAM after markdup keeps the materializer's @PG line:\n\(header.joined(separator: "\n"))")
        XCTAssertTrue(line?.contains("VN:1.1") == true, "the materializer's @PG line names VN:1.1, the version after the fix: \(line ?? "none")")
    }

    /// Adds the four rows of the orientation test to a database `makeTestDatabase` made, in its column order. Every
    /// mate is 10 bases at `10M`, and a mate with a strand flag of 1 is the reverse mate.
    private func addOrientationRows(to dbURL: URL, sample: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw NSError(domain: "test", code: 5) }
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'pairR1Reverse', 1, 'NC_001', 'Test virus', 100, '10M', 'AAAACCCCGG', 'ABCDEFGHIJ',
            99.0, 100.0, 0.001, 0, 10, 1, 'CP', 110, 90.0, 200, 'GATTACAGAT', 'KLMNOPQRST', 0, 10, 0, 91.0
        );
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'pairR2Reverse', 1, 'NC_001', 'Test virus', 300, '10M', 'TGCATTGACA', 'LMNOPQRSTU',
            99.0, 100.0, 0.001, 0, 10, 0, 'CP', 110, 90.0, 400, 'AAAACCCCGG', 'ABCDEFGHIJ', 0, 10, 1, 91.0
        );
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'singleR1Reverse', 1, 'NC_001', 'Test virus', 500, '10M', 'AAAACCCCGG', 'ABCDEFGHIJ',
            99.0, 100.0, 0.001, 0, 10, 1, 'UP', 10, 90.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        );
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'singleR2Reverse', 1, 'NC_001', 'Test virus', NULL, NULL, NULL, NULL,
            99.0, 100.0, 0.001, 0, 0, 0, 'R2', 0, 0.0, 600, 'AAAACCCCGG', 'ABCDEFGHIJ', 0, 10, 1, 88.0
        );
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "the four orientation rows insert")
    }

    /// The standard output of `samtools <arguments>`. A failing exit status fails the test with samtools' words.
    private func orientationSamtoolsText(_ samtools: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtools)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "samtools \(arguments.joined(separator: " ")) said: \(stderr)")
        return text
    }
}
