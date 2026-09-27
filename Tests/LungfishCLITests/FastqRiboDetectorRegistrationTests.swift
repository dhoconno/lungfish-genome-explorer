// FastqRiboDetectorRegistrationTests.swift - `fastq ribodetector` is reachable from the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import ArgumentParser
@testable import LungfishCLI
@testable import LungfishWorkflow

/// `FastqRiboDetectorSubcommand` was dropped from `FastqCommand`'s
/// subcommand list when the Deacon rRNA filter was added, so
/// `lungfish-cli fastq ribodetector` was unreachable while the FASTQ
/// consumer registry (and the GUI operation built on it) still described it.
final class FastqRiboDetectorRegistrationTests: XCTestCase {
    func testRiboDetectorIsARegisteredFastqSubcommand() throws {
        let registered = FastqCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        XCTAssertTrue(registered.contains("ribodetector"), registered.joined(separator: ", "))
        XCTAssertTrue(registered.contains("deacon-ribo"), "the Deacon filter stays registered alongside it")
    }

    func testRiboDetectorHelpParsesThroughTheRootCommand() throws {
        // `--help` parses to ArgumentParser's help command for the subcommand
        // (an unregistered subcommand fails to parse instead).
        let parsed = try LungfishCLI.parseAsRoot(["fastq", "ribodetector", "--help"])
        XCTAssertTrue(String(describing: type(of: parsed)).contains("HelpCommand"), String(describing: type(of: parsed)))
        let help = LungfishCLI.helpMessage(for: FastqRiboDetectorSubcommand.self, columns: 200)
        XCTAssertTrue(help.contains("lungfish-cli fastq ribodetector"), help)
        XCTAssertTrue(help.contains("--retain"), help)
    }

    func testRiboDetectorParsesItsInputsAndOptions() throws {
        let parsed = try LungfishCLI.parseAsRoot([
            "fastq", "ribodetector", "R1.fastq.gz", "R2.fastq.gz", "--retain", "rrna", "--output", "out",
        ])
        let command = try XCTUnwrap(parsed as? FastqRiboDetectorSubcommand)
        XCTAssertEqual(command.inputs, ["R1.fastq.gz", "R2.fastq.gz"])
        XCTAssertEqual(command.retain, "rrna")
    }

    /// The consumer registry names the CLI operation it describes.
    func testConsumerRegistryStillDescribesTheRegisteredCommand() {
        let declaration = FASTQConsumerRegistry.declarations.first { $0.consumerID == "fastq.ribodetector" }
        XCTAssertNotNil(declaration)
        XCTAssertEqual(declaration?.displayName, "fastq ribodetector")
    }
}
