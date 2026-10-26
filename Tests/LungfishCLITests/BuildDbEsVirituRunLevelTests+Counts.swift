// BuildDbEsVirituRunLevelTests+Counts.swift - build-db writes only the read counts it measured
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 13-BUILDDB-COUNTS with BIO's Q-A3 item 6 of Phase 2.13. A failed total count, count output that is not a
// number and a failed markdup leave a row with the read count it was parsed with and no unique reads, and the
// summary names the rows left uncounted. Each run builds `esviritu-mini` with a stand-in BAM of one sample and a
// stand-in samtools, once without the BAM for the parsed values, so no real tool runs.

import XCTest
import SQLite3
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

extension BuildDbEsVirituRunLevelTests {
    func testAFailedTotalCountLeavesTheParsedReadCount() async throws {
        let run = try await ReadCountRun.build(samtools: ReadCountRun.totalCountPrintsNoNumber)

        XCTAssertEqual(run.counted.count, 2, "the two rows of the sample with the BAM")
        for (rowid, counts) in run.counted {
            XCTAssertEqual(counts, ReadCountRun.Counts(read: try XCTUnwrap(run.parsed[rowid]).read, unique: nil), "row \(rowid)")
        }
    }

    func testAFailedMarkdupLeavesUniqueReadsNull() async throws {
        let run = try await ReadCountRun.build(samtools: ReadCountRun.failingMarkdup)

        XCTAssertTrue(run.lines.contains { $0.hasPrefix("  Warning: markdup failed on ") }, "\(run.lines)")
        XCTAssertEqual(run.counted.count, 2, "the two rows of the sample with the BAM")
        for (rowid, counts) in run.counted {
            XCTAssertNil(counts.unique, "row \(rowid) of a BAM with no duplicate flags")
            XCTAssertEqual(counts.read, try XCTUnwrap(run.parsed[rowid]).read, "row \(rowid)")
        }
    }

    func testTheSummaryCountsTheRowsLeftUncounted() async throws {
        let run = try await ReadCountRun.build(samtools: ReadCountRun.firstTotalCountFails)

        XCTAssertTrue(run.lines.contains("  Updated read counts for 1/2 organisms, 1 left uncounted"), "\(run.lines)")
        XCTAssertEqual(run.counted.values.filter { $0.unique == nil }.count, 1)
    }
}

/// One `build-db esviritu` run of `esviritu-mini` with a stand-in BAM and index in one sample's `_temp/`.
private enum ReadCountRun {
    struct Counts: Equatable {
        let read: Int64
        let unique: Int64?
    }

    struct Outcome {
        /// Every row as the tables gave it, from a build without the BAM, by rowid.
        let parsed: [Int64: Counts]
        /// Each row that names the BAM after the build with it, by rowid.
        let counted: [Int64: Counts]
        /// The lines of text and warnings of the build with the BAM.
        let lines: [String]
    }

    static let sample = "SRR35517705"

    /// A header that says the BAM was marked, so no markdup runs. A total count of a row prints no number.
    static let totalCountPrintsNoNumber = stub(totalCount: #"echo "no count""#)

    /// The first total count of a row exits 1 and every other count prints 2.
    static let firstTotalCountFails = stub(totalCount: #"if [ -e "$0.failed" ]; then echo 2; else touch "$0.failed"; exit 1; fi"#)

    /// No `samtools markdup` in the header, so markdup runs and its first stage exits 1. Every count prints 2.
    static let failingMarkdup = """
    #!/bin/sh
    case "$1" in
      --version) echo "samtools 1.21" ;;
      view)
        case "$2" in
          -H) printf '@HD\\tVN:1.6\\n' ;;
          -c) echo 2 ;;
        esac ;;
      *) exit 1 ;;
    esac
    exit 0
    """

    private static func stub(totalCount: String) -> String {
        """
        #!/bin/sh
        case "$1" in
          --version) echo "samtools 1.21" ;;
          view)
            case "$2" in
              -H) printf '@HD\\tVN:1.6\\n@PG\\tID:samtools.1\\tPN:samtools\\tCL:samtools markdup in out\\n' ;;
              -c) if [ "$4" = "2308" ] && [ -n "$6" ]; then \(totalCount); else echo 2; fi ;;
            esac ;;
          *) exit 1 ;;
        esac
        exit 0
        """
    }

    static func build(samtools script: String) async throws -> Outcome {
        let parsedScratch = try ImportStreamCapture.Scratch()
        defer { parsedScratch.remove() }
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let samtools = try ManagedSamtoolsHome.makeStub(rootURL: scratch.root, namePrefix: "Home", script: script)
        let parsedResult = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: parsedScratch)
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)
        let temp = result.appendingPathComponent("\(sample)/\(sample)_temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("BAM".utf8).write(to: temp.appendingPathComponent("\(sample).third.filt.sorted.bam"))
        try Data("BAI".utf8).write(to: temp.appendingPathComponent("\(sample).third.filt.sorted.bam.bai"))
        let lines = Lines()
        let events = BuildDbEventSink(
            progress: { _, _ in }, text: { lines.append($0) }, textWarning: { lines.append($0) }, warning: { lines.append($0) }
        )

        // `build-db` finds its managed samtools under `HOME`.
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", samtools.homeURL.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        }
        let options = BuildDbRunOptions(globalOptions: try GlobalOptions.parse([]))
        _ = try await BuildDbCommand.EsVirituSubcommand.buildDatabase(in: parsedResult, options: options, events: .silent)
        _ = try await BuildDbCommand.EsVirituSubcommand.buildDatabase(in: result, options: options, events: events)
        return Outcome(
            parsed: try counts(in: parsedResult, filter: ""),
            counted: try counts(in: result, filter: " WHERE bam_path IS NOT NULL"),
            lines: lines.all
        )
    }

    private static func counts(in result: URL, filter: String) throws -> [Int64: Counts] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(result.appendingPathComponent("esviritu.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid, read_count, unique_reads FROM detection_rows" + filter, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Int64: Counts] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let unique = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2)
            rows[sqlite3_column_int64(statement, 0)] = Counts(read: sqlite3_column_int64(statement, 1), unique: unique)
        }
        return rows
    }
}

/// The lines a run reported, in order, from any thread.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
