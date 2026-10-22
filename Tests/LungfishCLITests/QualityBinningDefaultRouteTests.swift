// QualityBinningDefaultRouteTests.swift - The CLI's other import routes take illumina4 binning and name it in their argv
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishCLI

/// Lane C2-BINNING (owner answer Q4, every route). Each route given no binning flag takes `illumina4`, and the argv it
/// records names the value, so a record replays the same whatever the default is. The assertions read the parsed
/// commands and the argv each one records.
final class QualityBinningDefaultRouteTests: XCTestCase {

    func testQualityBinningDefaultReachesTheSRABundleCommand() throws {
        let command = try SRADownloadSubcommand.parse(["SRR11140748", "--bundle", "--project", "/tmp/P.lungfish"])
        let argv = command.sraDownloadCommand()
        XCTAssertTrue(Self.names(argv, "--quality-binning", "illumina4"), "\(argv)")
    }

    func testQualityBinningDefaultGivesWayToTheSRABundlesFlag() throws {
        let command = try SRADownloadSubcommand.parse([
            "SRR11140748", "--bundle", "--project", "/tmp/P.lungfish", "--quality-binning", "none",
        ])
        let argv = command.sraDownloadCommand()
        XCTAssertTrue(Self.names(argv, "--quality-binning", "none"), "\(argv)")
        XCTAssertEqual(argv.filter { $0 == "--quality-binning" }.count, 1, "\(argv)")
    }

    func testQualityBinningDefaultReachesTheFastqIngestCommand() throws {
        let command = try FastqIngestSubcommand.parse(["/tmp/reads.fastq.gz"])
        XCTAssertEqual(command.binning, .illumina4)
        XCTAssertTrue(Self.names(command.replayArgv(), "--binning", "illumina4"), "\(command.replayArgv())")
    }

    func testQualityBinningDefaultReachesTheONTCommand() throws {
        let command = try FastqImportONTSubcommand.parse(["/tmp/fastq_pass", "--output", "/tmp/out"])
        XCTAssertEqual(command.qualityBinning, .illumina4)
        let explicit = try FastqImportONTSubcommand.parse(["/tmp/fastq_pass", "--output", "/tmp/out", "--quality-binning", "eightLevel"])
        XCTAssertEqual(explicit.qualityBinning, .eightLevel)
    }

    /// Whether `argv` holds `flag` followed by `value`.
    private static func names(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        zip(argv, argv.dropFirst()).contains { $0 == flag && $1 == value }
    }
}
