// MarkdupReadCountFlagsTests.swift - The markdup totals count reads, not alignment records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane COUNTS of the 5.6 S1 sweep (MARKDUP-COUNTS-RECORDS, which folds MARKDUP-COMMAND-COUNT-FLAGS and
// BUILD-DB-COUNT-FLAGS). `lungfish-cli markdup` and the markdup of `lungfish-cli build-db` counted a total with
// `samtools view -c -F 0x4` and the reads that are not duplicates with `-F 0x404`, so a secondary or a supplementary
// record counted as a read, and the printed total and duplicate share were counts of alignment records. `MarkdupService`
// counts with `-F 0x904` and `-F 0xD04`, and the four count sites of the two commands now do the same.
//
// The crafted BAM has one reference A of 1000 bp and four records of two reads.
//   r1  flag 0     A:101  primary
//   r2  flag 0     A:101  primary at the place and strand of r1, so markdup marks one of the two a duplicate
//   r1  flag 256   A:301  secondary
//   r2  flag 2048  A:501  supplementary
// On the marked copy samtools gives these counts, and each test checks them against samtools itself first.
//   view -c -F 0x4    4   every mapped record
//   view -c -F 0x904  2   the reads, which are the two primary records
//   view -c -F 0xD04  1   the reads that are not duplicates
// So the total and the duplicate share were 4 and 1 in 4 before the change, and are 2 and 1 in 2 after it. The duplicate
// count is 1 either way.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO

/// The live form, with the managed samtools. `LUNGFISH_REQUIRE_TOOLS=1` turns a missing samtools into a failure. Each
/// command has two count sites, one for a BAM that already carries markdup flags (only its index is refreshed) and one
/// for a BAM that the command marks, so each command has a test for each.
final class MarkdupReadCountFlagsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "MarkdupReadCountFlags")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - lungfish-cli markdup

    /// Red at the base, with 4 reads and a share of 1 in 4. The BAM carries `@PG ID:samtools.markdup`, so the command
    /// only refreshes its index and counts it.
    func testMarkdupCommandCountsReadsOnAnAlreadyMarkedBam() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let bam = try Self.makeBAM(in: root, named: "marked", marked: true, samtools: samtools)
        try Self.assertSamtoolsCounts(of: bam, samtools: samtools, records: 4, reads: 2, nonDuplicates: 1)

        var lines: [String] = []
        let results = try await MarkdupCommand.parse([bam.path]).executeForTesting { lines.append($0) }

        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.wasAlreadyMarkduped, "the BAM carries the markdup header, so the command marks nothing")
        XCTAssertEqual(result.totalReads, 2, "the total counts the 2 primary records, not the 4 mapped records")
        XCTAssertEqual(result.duplicateReads, 1, "one of the two reads is a duplicate")
        XCTAssertTrue(lines.contains("Total reads: 2, duplicates: 1"), "the printed line, from \(lines)")
    }

    /// Red at the base, with 4 reads and a share of 1 in 4. The command marks the BAM, and counts the marked copy.
    func testMarkdupCommandCountsReadsAfterMarking() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let bam = try Self.makeBAM(in: root, named: "unmarked", marked: false, samtools: samtools)
        try Self.assertSamtoolsCounts(of: bam, samtools: samtools, records: 4, reads: 2, nonDuplicates: 2)

        var lines: [String] = []
        let results = try await MarkdupCommand.parse([bam.path]).executeForTesting { lines.append($0) }

        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.wasAlreadyMarkduped, "the BAM has no markdup header, so the command marks it")
        try Self.assertSamtoolsCounts(of: result.outputURL, samtools: samtools, records: 4, reads: 2, nonDuplicates: 1)
        XCTAssertEqual(result.totalReads, 2, "the total counts the 2 primary records, not the 4 mapped records")
        XCTAssertEqual(result.duplicateReads, 1, "markdup marks one of the two reads at A:101")
        XCTAssertTrue(lines.contains("Total reads: 2, duplicates: 1"), "the printed line, from \(lines)")
    }

    // MARK: - lungfish-cli build-db

    /// Red at the base, with 4 reads and a share of 1 in 4. The same BAM as the first test, through the markdup of the
    /// `build-db` samtools provenance.
    func testBuildDbMarkdupCountsReadsOnAnAlreadyMarkedBam() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let bam = try Self.makeBAM(in: root, named: "marked", marked: true, samtools: samtools)
        try Self.assertSamtoolsCounts(of: bam, samtools: samtools, records: 4, reads: 2, nonDuplicates: 1)

        let tracker = BuildDbSamtoolsProvenanceTracker(samtoolsPath: samtools.path, collector: BuildDbSamtoolsProvenanceCollector())
        let result = try await tracker.markdup(bamURL: bam)

        XCTAssertTrue(result.wasAlreadyMarkduped, "the BAM carries the markdup header, so nothing is marked")
        XCTAssertEqual(result.totalReads, 2, "the total counts the 2 primary records, not the 4 mapped records")
        XCTAssertEqual(result.duplicateReads, 1, "one of the two reads is a duplicate")
    }

    /// Red at the base, with 4 reads and a share of 1 in 4. The same BAM as the second test, which `build-db` marks in
    /// place.
    func testBuildDbMarkdupCountsReadsAfterMarking() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let bam = try Self.makeBAM(in: root, named: "unmarked", marked: false, samtools: samtools)
        try Self.assertSamtoolsCounts(of: bam, samtools: samtools, records: 4, reads: 2, nonDuplicates: 2)

        let tracker = BuildDbSamtoolsProvenanceTracker(samtoolsPath: samtools.path, collector: BuildDbSamtoolsProvenanceCollector())
        let result = try await tracker.markdup(bamURL: bam)

        XCTAssertFalse(result.wasAlreadyMarkduped, "the BAM has no markdup header, so build-db marks it")
        try Self.assertSamtoolsCounts(of: bam, samtools: samtools, records: 4, reads: 2, nonDuplicates: 1)
        XCTAssertEqual(result.totalReads, 2, "the total counts the 2 primary records, not the 4 mapped records")
        XCTAssertEqual(result.duplicateReads, 1, "markdup marks one of the two reads at A:101")
    }

    // MARK: - Staging

    /// The crafted BAM of the header comment, made by `samtools sort` and `samtools index` from a SAM. The marked form
    /// carries the markdup header and the duplicate flag on r2. The unmarked form has neither, and r2 and r1 share
    /// their place, so markdup marks one of them.
    private static func makeBAM(in root: URL, named name: String, marked: Bool, samtools: URL) throws -> URL {
        func record(_ fields: [String]) -> String { fields.joined(separator: "\t") }
        var lines = [record(["@HD", "VN:1.6"]), record(["@SQ", "SN:A", "LN:1000"])]
        if marked {
            lines.append(record(["@PG", "ID:samtools.markdup", "PN:samtools", "VN:1.21", "CL:samtools markdup in.bam out.bam"]))
        }
        lines += [
            record(["r1", "0", "A", "101", "60", "10M", "*", "0", "0", "ACGTACGTAC", "IIIIIIIIII"]),
            record(["r2", marked ? "1024" : "0", "A", "101", "60", "10M", "*", "0", "0", "ACGTACGTAC", "IIIIIIIIII"]),
            record(["r1", "256", "A", "301", "0", "10M", "*", "0", "0", "ACGTACGTAC", "IIIIIIIIII"]),
            record(["r2", "2048", "A", "501", "60", "5H5M", "*", "0", "0", "ACGTA", "IIIII"]),
        ]
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sam = folder.appendingPathComponent("\(name).sam")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: sam)
        let bam = folder.appendingPathComponent("\(name).bam")
        let sorted = try ProcessRunner.run(samtools, ["sort", "-o", bam.path, sam.path])
        XCTAssertEqual(sorted.status, 0, sorted.stderr)
        let indexed = try ProcessRunner.run(samtools, ["index", bam.path])
        XCTAssertEqual(indexed.status, 0, indexed.stderr)
        return bam
    }

    /// The three counts of the header comment, each from `samtools view -c -F` on `bam`.
    private static func assertSamtoolsCounts(
        of bam: URL,
        samtools: URL,
        records: Int,
        reads: Int,
        nonDuplicates: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        func count(_ mask: String) throws -> Int {
            let run = try ProcessRunner.run(samtools, ["view", "-c", "-F", mask, bam.path])
            XCTAssertEqual(run.status, 0, run.stderr, file: file, line: line)
            return Int(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
        let mapped = try count("0x4")
        let primary = try count("0x904")
        let primaryNonDuplicate = try count("0xD04")
        XCTAssertEqual(mapped, records, "samtools view -c -F 0x4 of \(bam.lastPathComponent)", file: file, line: line)
        XCTAssertEqual(primary, reads, "samtools view -c -F 0x904 of \(bam.lastPathComponent)", file: file, line: line)
        XCTAssertEqual(primaryNonDuplicate, nonDuplicates, "samtools view -c -F 0xD04 of \(bam.lastPathComponent)", file: file, line: line)
    }
}
