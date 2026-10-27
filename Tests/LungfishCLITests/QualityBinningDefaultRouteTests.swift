// QualityBinningDefaultRouteTests.swift - The CLI's other import routes take their platform's binning default
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishWorkflow
@testable import LungfishCLI

/// BIO-BIN (Phase 3.0 lane BIN), narrowing lane C2-BINNING. Each route given no binning flag takes the default of the
/// platform it knows, `fiveStep` for Illumina and `none` for every other platform and for a route that reads no
/// platform. A route that knows its binning before the reads arrive names it in the argv it records, so a record
/// replays the same whatever the default is. The assertions read the parsed commands and the argv each one records.
final class QualityBinningDefaultRouteTests: XCTestCase {

    /// With `--platform auto` the import decides each sample's platform from its reads, so the download names no
    /// binning and the import bins with the detected platform's default.
    func testQualityBinningDefaultIsLeftToTheDetectedPlatformByTheSRABundleCommand() throws {
        let command = try SRADownloadSubcommand.parse(["SRR11140748", "--bundle", "--project", "/tmp/P.lungfish"])
        let argv = command.sraDownloadCommand()
        XCTAssertFalse(argv.contains("--quality-binning"), "\(argv)")
    }

    func testQualityBinningDefaultOfANamedPlatformReachesTheSRABundleCommand() throws {
        for (platform, binning) in [("illumina", "fiveStep"), ("ont", "none"), ("pacbio", "none")] {
            let command = try SRADownloadSubcommand.parse([
                "SRR11140748", "--bundle", "--project", "/tmp/P.lungfish", "--platform", platform,
            ])
            let argv = command.sraDownloadCommand()
            XCTAssertTrue(Self.names(argv, "--quality-binning", binning), "\(argv)")
        }
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
        XCTAssertEqual(command.binning, QualityBinningScheme.none, "the command reads no platform")
        XCTAssertTrue(Self.names(command.replayArgv(), "--binning", "none"), "\(command.replayArgv())")
        let fiveStep = try FastqIngestSubcommand.parse(["/tmp/reads.fastq.gz", "--binning", "fiveStep"])
        XCTAssertEqual(fiveStep.binning, .fiveStep)
    }

    func testQualityBinningDefaultReachesTheONTCommand() throws {
        let command = try FastqImportONTSubcommand.parse(["/tmp/fastq_pass", "--output", "/tmp/out"])
        XCTAssertEqual(command.qualityBinning, QualityBinningScheme.none, "an ONT import keeps every score")
        let explicit = try FastqImportONTSubcommand.parse(["/tmp/fastq_pass", "--output", "/tmp/out", "--quality-binning", "eightLevel"])
        XCTAssertEqual(explicit.qualityBinning, .eightLevel)
    }

    /// An older record names `illumina4`, and the CLI still runs it, so the record replays to the same bytes.
    func testIllumina4StaysAcceptedForReplays() throws {
        let ingest = try FastqIngestSubcommand.parse(["/tmp/reads.fastq.gz", "--binning", "illumina4"])
        XCTAssertEqual(ingest.binning, .illumina4)
        let ont = try FastqImportONTSubcommand.parse(["/tmp/fastq_pass", "--output", "/tmp/out", "--quality-binning", "illumina4"])
        XCTAssertEqual(ont.qualityBinning, .illumina4)
    }

    /// Whether `argv` holds `flag` followed by `value`.
    private static func names(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        zip(argv, argv.dropFirst()).contains { $0 == flag && $1 == value }
    }
}
