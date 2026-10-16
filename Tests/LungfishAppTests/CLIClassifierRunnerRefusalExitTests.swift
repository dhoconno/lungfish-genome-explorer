// CLIClassifierRunnerRefusalExitTests.swift - The CLI route's runner reads exit status 3 as a refusal
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.11 lane U64 M1, row SW23, decision U4 and the SWIFT memo's condition on Q-U64. A classifier command
/// that refuses with exit status 3 (`kraken2 classify` on an input with no readable reads, as `esviritu detect`
/// always did) fails the row with the command's own message, as a command that ends with another status does, so
/// the app does not tell a refusal from a failure by its number. A shell script in place of `lungfish-cli` plays
/// the command (ClassifierRouteFixtures.standInCLI).
final class CLIClassifierRunnerRefusalExitTests: XCTestCase {
    private static let refusal = "Sequence input does not contain a readable FASTQ or FASTA payload: /work/reads.lungfishfastq"

    private static func refusedLines(_ message: String) -> [String] {
        [
            #"{"event":"start","message":"Starting classification.","progress":0,"schemaVersion":2}"#,
            #"{"detail":"the detail","error":"\#(message)","event":"failed","schemaVersion":2}"#,
        ]
    }

    func testAKraken2RefusalWithExitStatus3FailsWithItsMessageAndNoDetail() async throws {
        let root = try TestTempDirectory.make(prefix: "cli-classifier-runner-exit3-kraken2")
        defer { TestTempDirectory.cleanup(root) }
        let cli = try ClassifierRouteFixtures.standInCLI(in: root, lines: Self.refusedLines(Self.refusal), exitStatus: 3)

        do {
            _ = try await CLIClassifierRunner(cliURLOverride: cli).run(
                CLIClassifierRunRequest(tool: .kraken2, arguments: ["kraken2", "classify"], sampleIDs: ["reads"]),
                operationID: UUID()
            )
            XCTFail("a refused command must throw")
        } catch let failure as CLIClassifierFailure {
            XCTAssertEqual(failure, CLIClassifierFailure(message: Self.refusal, errorMessage: nil, errorDetail: nil))
        }
    }

    func testAnEsVirituRefusalWithExitStatus3FailsWithItsMessageAndTheLogTailHeading() async throws {
        let root = try TestTempDirectory.make(prefix: "cli-classifier-runner-exit3-esviritu")
        defer { TestTempDirectory.cleanup(root) }
        let cli = try ClassifierRouteFixtures.standInCLI(in: root, lines: Self.refusedLines(Self.refusal), exitStatus: 3)

        do {
            _ = try await CLIClassifierRunner(cliURLOverride: cli).run(
                CLIClassifierRunRequest(tool: .esViritu, arguments: ["esviritu", "detect"], sampleIDs: ["reads"]),
                operationID: UUID()
            )
            XCTFail("a refused command must throw")
        } catch let failure as CLIClassifierFailure {
            XCTAssertEqual(
                failure,
                CLIClassifierFailure(
                    message: Self.refusal,
                    errorMessage: Self.refusal,
                    errorDetail: CLIClassifierRowEvents.esVirituLogTailHeading + "the detail"
                )
            )
        }
    }

    /// A refusal that wrote no `failed` line still fails the row, with the status and the command's text.
    func testARefusalWithExitStatus3AndNoFailedLineFailsWithTheStatusAndItsText() async throws {
        let root = try TestTempDirectory.make(prefix: "cli-classifier-runner-exit3-text")
        defer { TestTempDirectory.cleanup(root) }
        let cli = try ClassifierRouteFixtures.standInCLI(in: root, lines: [], standardError: ["Error: \(Self.refusal)"], exitStatus: 3)

        do {
            _ = try await CLIClassifierRunner(cliURLOverride: cli).run(
                CLIClassifierRunRequest(tool: .kraken2, arguments: ["kraken2", "classify"], sampleIDs: ["reads"]),
                operationID: UUID()
            )
            XCTFail("a refused command must throw")
        } catch let failure as CLIClassifierFailure {
            XCTAssertTrue(failure.message.hasPrefix("lungfish-cli exited with status 3"), failure.message)
            XCTAssertTrue(failure.message.contains(Self.refusal), failure.message)
            XCTAssertNil(failure.errorDetail)
        }
    }
}
