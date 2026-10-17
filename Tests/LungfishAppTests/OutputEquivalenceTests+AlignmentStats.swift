// OutputEquivalenceTests+AlignmentStats.swift - The import duration of an alignment stats database is masked, nothing beside it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A62, ruling A62-ARCH Fix 1 and 2. A BAM import writes the seconds it took into the `duration`
// column of the `provenance` table of the alignment's `<track>.stats.db` (AlignmentMetadataDatabase), so two runs
// never agree on it, and the standard masks cover no value of a database dump but the identifiers and timestamps in
// its text. The contract (docs/contracts/CLI-EQUIVALENCE.md, Masks) masks that one column where the table is the one
// AlignmentMetadataDatabase writes. The same column in another table, a `provenance` table with other columns and
// every other column and table of the database are compared as written. OutputEquivalenceTests is past the
// file-size baseline, so these tests sit in an extension beside it.

import Foundation
import SQLite3
import XCTest
import LungfishIO
import LungfishTestSupport

extension OutputEquivalenceTests {
    /// The facts of the import step an alignment stats database records, which the first row of the table holds.
    private struct StatsImport {
        var command = "lungfish-cli import-bam --input reads.bam"
        var version: String? = "1.0"
        var inputFile: String? = "reads.bam"
        var exitCode: Int32? = 0
        var seconds: Double? = 0.13
    }

    /// Two runs of an import never take the same time, so the duration of the import step and of the step that
    /// hangs from it do not count, under the database kind and the bundle kind alike.
    func testAnAlignmentStatsDatabaseMasksOnlyItsImportDuration() throws {
        let (scratch, a, b) = try makeStatsRoots()
        defer { TestTempDirectory.cleanup(scratch) }
        var slower = StatsImport()
        slower.seconds = 0.15
        try writeAlignmentStats(at: a.appendingPathComponent("x.stats.db"), StatsImport())
        try writeAlignmentStats(at: b.appendingPathComponent("x.stats.db"), slower)
        for kind in [OutputEquivalence.Kind.database, .bundle] {
            XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: kind), [], "\(kind)")
            OutputEquivalence.assertSame(a, b, kind: kind)
        }
    }

    /// The mask reads the `duration` column and no other. A changed command, version, exit code or input file
    /// still differs when the durations differ too, and so does a duration that one run never recorded.
    func testAnAlignmentStatsDatabaseStillDiffersOnItsCommandVersionOrExitCode() throws {
        let (scratch, a, b) = try makeStatsRoots()
        defer { TestTempDirectory.cleanup(scratch) }
        let changes: [(label: String, edit: (inout StatsImport) -> Void)] = [
            ("command", { $0.command += " --threads 4" }),
            ("version", { $0.version = "1.1" }),
            ("exit_code", { $0.exitCode = 1 }),
            ("input_file", { $0.inputFile = "other.bam" }),
            ("a duration that was not recorded", { $0.seconds = nil }),
        ]
        for kind in [OutputEquivalence.Kind.database, .bundle] {
            for (label, edit) in changes {
                var other = StatsImport()
                other.seconds = 0.15
                edit(&other)
                try writeAlignmentStats(at: a.appendingPathComponent("x.stats.db"), StatsImport())
                try writeAlignmentStats(at: b.appendingPathComponent("x.stats.db"), other)
                let found = try OutputEquivalence.differences(a, b, kind: kind)
                XCTAssertEqual(found.count, 1, "\(kind), \(label): \(found)")
                XCTAssertTrue(found.first?.hasPrefix("differs: x.stats.db") == true, "\(kind), \(label): \(found)")
            }
        }
    }

    /// The mask reads the table AlignmentMetadataDatabase writes and nothing that looks like it. A `duration` in
    /// a `provenance` table of two columns, in another table, and in a `provenance` table that has a column more
    /// (so its second-to-last field is still a number) is compared as written. With equal times the same
    /// databases match, so the duration alone made them differ.
    func testADurationOutsideAnAlignmentStatsProvenanceTableIsComparedAsWritten() throws {
        let (scratch, a, b) = try makeStatsRoots()
        defer { TestTempDirectory.cleanup(scratch) }
        let columns = "step_order INTEGER PRIMARY KEY, tool TEXT, subcommand TEXT, version TEXT, command TEXT, "
            + "timestamp TEXT, input_file TEXT, output_file TEXT, exit_code INTEGER, "
        let shapes: [(label: String, statements: (String) -> [String])] = [
            ("a provenance table of two columns", { seconds in
                ["CREATE TABLE provenance (id INTEGER, duration REAL)", "INSERT INTO provenance VALUES (1, \(seconds))"]
            }),
            ("a runs table", { seconds in
                ["CREATE TABLE runs (name TEXT, duration REAL)", "INSERT INTO runs VALUES ('import', \(seconds))"]
            }),
            ("a provenance table with a column more", { seconds in
                [
                    "CREATE TABLE provenance (" + columns + "note TEXT, duration REAL, parent_step INTEGER)",
                    "INSERT INTO provenance VALUES (1, 'lungfish', 'import-bam', '1.0', 'cmd', '2026-10-14', 'in.bam', "
                        + "'out.bam', 0, 'n', \(seconds), NULL)",
                ]
            }),
        ]
        for kind in [OutputEquivalence.Kind.database, .bundle] {
            for (label, statements) in shapes {
                for (root, seconds) in [(a, "0.13"), (b, "0.15")] {
                    try execute(statements(seconds), at: root.appendingPathComponent("x.stats.db"))
                }
                let found = try OutputEquivalence.differences(a, b, kind: kind)
                XCTAssertEqual(found.count, 1, "\(kind), \(label): \(found)")
                XCTAssertTrue(found.first?.hasPrefix("differs: x.stats.db") == true, "\(kind), \(label): \(found)")
                try execute(statements("0.13"), at: b.appendingPathComponent("x.stats.db"))
                XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: kind), [], "\(kind), \(label) with equal times")
            }
        }
    }

    // MARK: - Fixture helpers

    private func makeStatsRoots() throws -> (scratch: URL, a: URL, b: URL) {
        let scratch = try TestTempDirectory.make(prefix: "output-equivalence-stats")
        let a = scratch.appendingPathComponent("A", isDirectory: true)
        let b = scratch.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return (scratch, a, b)
    }

    /// The stats database a BAM import leaves beside its track, written by the real AlignmentMetadataDatabase so the
    /// mask tracks the table the writer declares. It holds the import step and one step that hangs from it, whose
    /// time is a tenth of the import's.
    private func writeAlignmentStats(at url: URL, _ step: StatsImport) throws {
        try? FileManager.default.removeItem(at: url)
        let database = try AlignmentMetadataDatabase.create(at: url)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = database.addProvenanceRecord(
            tool: "lungfish", subcommand: "import-bam", version: step.version, command: step.command,
            timestamp: timestamp, inputFile: step.inputFile, outputFile: "x.sorted.bam", exitCode: step.exitCode,
            duration: step.seconds
        )
        database.addProvenanceRecord(
            tool: "samtools", subcommand: "sort", version: "1.21", command: "samtools sort reads.bam",
            timestamp: timestamp, inputFile: step.inputFile, outputFile: "x.sorted.bam", exitCode: 0,
            duration: step.seconds.map { $0 / 10 }, parentStep: parent
        )
    }

    /// A fresh database at `url` that holds the result of `statements`.
    private func execute(_ statements: [String], at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        for statement in statements {
            XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK, statement)
        }
    }
}
