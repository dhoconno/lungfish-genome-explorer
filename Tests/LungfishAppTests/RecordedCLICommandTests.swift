// RecordedCLICommandTests.swift - The recorded-command parser splits and parses like the shipped CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import LungfishKit
import LungfishWorkflow

/// `RecordedCLICommand` is how every launch-site test proves its recorded
/// command runs (R4). It must undo `OperationCenter.buildCLICommand` exactly,
/// including arguments that need shell quoting.
final class RecordedCLICommandTests: XCTestCase {
    func testArgumentsUndoTheShellQuotingOfBuildCLICommand() throws {
        let arguments = [
            "--kreport", "/tmp/My Project.lungfish/kraken2 run/classification.kreport",
            "--kraken-output", "/tmp/it's here/classification.kraken",
            "--source", "/tmp/reads (R1).fastq",
            "--taxid", "11320",
            "--include-children",
            "--reads", "20",
        ]
        let command = OperationCenter.buildCLICommand(subcommand: "blast verify", args: arguments)

        XCTAssertEqual(try RecordedCLICommand.arguments(of: command), ["blast", "verify"] + arguments)
    }

    func testParseReturnsTheSubcommandWithItsValues() throws {
        let command = OperationCenter.buildCLICommand(
            subcommand: "blast verify",
            args: [
                "--kreport", "/tmp/My Project.lungfish/classification.kreport",
                "--kraken-output", "/tmp/My Project.lungfish/classification.kraken",
                "--source", "/tmp/My Project.lungfish/reads.fastq",
                "--taxid", "11320",
                "--include-children",
                "--reads", "25",
                "--result-dir", "/tmp/My Project.lungfish/Analyses/kraken2",
            ]
        )

        let parsed = try RecordedCLICommand.parse(command, as: BlastCommand.VerifySubcommand.self)

        XCTAssertEqual(parsed.kreportFile, "/tmp/My Project.lungfish/classification.kreport")
        XCTAssertEqual(parsed.sourcePaths, ["/tmp/My Project.lungfish/reads.fastq"])
        XCTAssertEqual(parsed.taxId, 11320)
        XCTAssertEqual(parsed.readCount, 25)
        XCTAssertTrue(parsed.includeChildren)
        XCTAssertEqual(parsed.resultDirectory, "/tmp/My Project.lungfish/Analyses/kraken2")
    }

    func testANonLungfishCommandAndAMissingCommandAreRejected() {
        XCTAssertThrowsError(try RecordedCLICommand.parse("gatk HaplotypeCaller -R ref.fa")) { error in
            guard case RecordedCLICommand.ParseError.notALungfishCLICommand = error else {
                return XCTFail("expected notALungfishCLICommand, got \(error)")
            }
        }
        XCTAssertThrowsError(try RecordedCLICommand.parse(nil)) { error in
            guard case RecordedCLICommand.ParseError.missingCommand = error else {
                return XCTFail("expected missingCommand, got \(error)")
            }
        }
    }

    func testAnUnknownOptionFailsTheParse() {
        let command = OperationCenter.buildCLICommand(
            subcommand: "blast verify",
            args: ["--kreport", "/tmp/a.kreport", "--organism", "Influenza A"]
        )
        XCTAssertThrowsError(try RecordedCLICommand.parse(command))
    }

    /// A gap row records nil, never a descriptive text
    /// (docs/contracts/CLI-EQUIVALENCE.md, "Gaps until they close"). The ID
    /// is passed through a variable, so scripts/ratchets/cli-parity-gaps.sh
    /// does not read these calls as pins.
    func testAGapPinPassesOnlyForNil() {
        let id = "pin-self-test"
        assertCLIParityGap(nil, id: id)
        XCTExpectFailure("a gap row that records descriptive text fails its pin") {
            assertCLIParityGap("# No command merges these bundles yet.", id: id)
        }
        XCTExpectFailure("a gap row whose command now parses fails its pin") {
            assertCLIParityGap(
                OperationCenter.buildCLICommand(
                    subcommand: "blast verify",
                    args: [
                        "--kreport", "/tmp/a.kreport",
                        "--kraken-output", "/tmp/a.kraken",
                        "--source", "/tmp/reads.fastq",
                        "--taxid", "11320",
                        "--result-dir", "/tmp/kraken2",
                    ]
                ),
                id: id
            )
        }
    }
}
