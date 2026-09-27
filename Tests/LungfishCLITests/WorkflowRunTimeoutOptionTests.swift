// WorkflowRunTimeoutOptionTests.swift - --timeout states its limitation and is refused as an input error
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

/// `--timeout` was listed in `workflow run --help` without a caveat, yet an
/// nf-core/viralrecon run refused it with a generic workflow failure (exit
/// 64). The help now states the limitation, and the refusal is the
/// documented input-error status (3).
final class WorkflowRunTimeoutOptionTests: XCTestCase {
    func testHelpStatesThatTimeoutIsNotSupportedYet() {
        let help = WorkflowCommand.helpMessage(for: RunSubcommand.self, columns: 200)
        let timeoutLine = help.split(separator: "\n").first { $0.contains("--timeout") }.map(String.init) ?? ""
        XCTAssertTrue(timeoutLine.contains("Not supported yet"), help)
        XCTAssertTrue(timeoutLine.contains("exit status 3"), help)
        XCTAssertTrue(timeoutLine.contains("not enforced for a local workflow"), help)
    }

    func testViralReconRefusesTimeoutWithTheInputErrorStatus() async throws {
        let command = try RunSubcommand.parse([
            "nf-core/viralrecon", "--input", "samplesheet.csv", "--timeout", "30", "--quiet",
        ])
        do {
            try await command.run()
            XCTFail("--timeout must be refused for nf-core/viralrecon")
        } catch let error as CLIError {
            guard case .validationFailed(let errors) = error else {
                return XCTFail("expected validationFailed, got \(error)")
            }
            XCTAssertEqual(errors, [RunSubcommand.timeoutUnsupportedForViralRecon])
            XCTAssertEqual(error.exitCode, .inputError)
            XCTAssertEqual(error.exitCode.rawValue, 3)
            XCTAssertTrue(error.localizedDescription.contains("--timeout is not supported for nf-core/viralrecon"), error.localizedDescription)
        }
    }
}
