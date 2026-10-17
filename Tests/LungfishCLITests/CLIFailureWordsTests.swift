// CLIFailureWordsTests.swift - the helper every failed command asks for its reason
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A69 (carry-in row SW11). `CLIFailedRowWordsTests` drives the commands that use it.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class CLIFailureWordsTests: XCTestCase {
    private struct Described: LocalizedError {
        var errorDescription: String? { "Its own description." }
    }

    /// Conforms to `LocalizedError` and gives no description, so the system's text stands.
    private struct Silent: LocalizedError {}

    private struct Plain: Error {}

    func testAValidationErrorGivesItsMessage() {
        let message = "Pass --all or --variant-id, not both."
        XCTAssertEqual(CLIFailureWords.describe(ValidationError(message)), message)
    }

    func testALocalizedErrorGivesItsDescription() {
        XCTAssertEqual(CLIFailureWords.describe(Described()), "Its own description.")
    }

    func testALocalizedErrorWithoutADescriptionGivesTheSystemsText() {
        let error = Silent()
        XCTAssertEqual(CLIFailureWords.describe(error), error.localizedDescription)
    }

    func testAnyOtherErrorGivesItsLocalizedDescription() {
        let missing = CocoaError(.fileNoSuchFile)
        XCTAssertEqual(CLIFailureWords.describe(missing), missing.localizedDescription)
        XCTAssertEqual(CLIFailureWords.describe(Plain()), Plain().localizedDescription)
    }

    /// A typed refusal of a Workflow action reads as its own words once it has them (the alignment rows).
    /// The system's text for a type with no words names no file, so this fails until the type has them.
    func testTheStaleEvidenceRefusalReadsAsItsOwnWords() {
        let stale = AlignmentActionContext.EvidenceError.staleEvidence(URL(fileURLWithPath: "/work/sample.bam"))
        let words = CLIFailureWords.describe(stale)
        XCTAssertEqual(words, stale.localizedDescription)
        XCTAssertTrue(words.contains("sample.bam"), words)
    }

    /// The reason the helper exists. The system's text for a `ValidationError` holds none of its
    /// words, so a command that printed `localizedDescription` lost the refusal. If ArgumentParser ever
    /// gives the type localized text this fails, and the helper may go.
    func testTheSystemsTextForAValidationErrorLosesItsWords() {
        let error = ValidationError("Pass --all or --variant-id, not both.")
        XCTAssertFalse(error.localizedDescription.contains("--variant-id"), error.localizedDescription)
    }
}
