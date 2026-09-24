// CLIRunnerArgvRoundTripTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishWorkflow

/// P6-B acceptance test (WFL-11): for each migrated CLI runner family, the
/// argv `buildCLIArguments` produces is both what gets executed
/// (`runner.run(arguments:)`) and what the Operations panel displays
/// (`OperationCenter.buildCLICommand(subcommand:args:)` is built from the
/// same array at each call site) -- there is one array, not two. This test
/// closes the loop by asserting that same argv also parses through the real
/// CLI subcommand parser, so the displayed/recorded command is genuinely
/// runnable, not just self-consistent within the app.
final class CLIRunnerArgvRoundTripTests: XCTestCase {
    func testVariantCallingArgvParsesThroughCallSubcommand() throws {
        let request = BundleVariantCallingRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            caller: .lofreq,
            outputTrackName: "Sample 1 \u{2022} LoFreq",
            threads: 4,
            minimumAlleleFrequency: 0.05,
            minimumDepth: 10
        )
        let arguments = CLIVariantCallingRunner.buildCLIArguments(request: request)

        // arguments == ["variants", "call", ...]; VariantsCommand.CallSubcommand
        // parses only its own subcommand's arguments.
        XCTAssertEqual(Array(arguments.prefix(2)), ["variants", "call"])
        let parsed = try VariantsCommand.CallSubcommand.parse(Array(arguments.dropFirst(2)))

        XCTAssertEqual(parsed.bundlePath, "/tmp/Sample.lungfishref")
        XCTAssertEqual(parsed.alignmentTrackID, "aln-1")
        XCTAssertEqual(parsed.caller, "lofreq")
        XCTAssertEqual(parsed.outputTrackName, "Sample 1 \u{2022} LoFreq")
        XCTAssertEqual(parsed.minimumAlleleFrequency, 0.05)
        XCTAssertEqual(parsed.minimumDepth, 10)
    }

    func testVariantCallingArgvParsesThroughTopLevelCLI() throws {
        let request = BundleVariantCallingRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            caller: .ivar,
            outputTrackName: "Sample 1",
            threads: 2
        )
        let arguments = CLIVariantCallingRunner.buildCLIArguments(request: request)
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        XCTAssertTrue(parsed is VariantsCommand.CallSubcommand)
    }

    func testPrimerTrimArgvParsesThroughPrimerTrimSubcommand() throws {
        let arguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: URL(fileURLWithPath: "/tmp/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            schemeURL: URL(fileURLWithPath: "/tmp/QIASeq.lungfishprimers"),
            outputTrackName: "Primer-trimmed Sample",
            targetReferenceName: "MT192765.1"
        )

        // arguments == ["bam", "primer-trim", ...]; BAMCommand.PrimerTrimSubcommand
        // parses only its own subcommand's arguments.
        XCTAssertEqual(Array(arguments.prefix(2)), ["bam", "primer-trim"])
        let parsed = try BAMCommand.PrimerTrimSubcommand.parse(Array(arguments.dropFirst(2)))

        XCTAssertEqual(parsed.bundlePath, "/tmp/Sample.lungfishref")
        XCTAssertEqual(parsed.alignmentTrackID, "aln-1")
        XCTAssertEqual(parsed.schemePath, "/tmp/QIASeq.lungfishprimers")
        XCTAssertEqual(parsed.outputTrackName, "Primer-trimmed Sample")
        XCTAssertEqual(parsed.targetReferenceName, "MT192765.1")
    }

    func testPrimerTrimArgvParsesThroughTopLevelCLI() throws {
        let arguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: URL(fileURLWithPath: "/tmp/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            schemeURL: URL(fileURLWithPath: "/tmp/QIASeq.lungfishprimers"),
            outputTrackName: "Primer-trimmed Sample"
        )
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        XCTAssertTrue(parsed is BAMCommand.PrimerTrimSubcommand)
    }
}
