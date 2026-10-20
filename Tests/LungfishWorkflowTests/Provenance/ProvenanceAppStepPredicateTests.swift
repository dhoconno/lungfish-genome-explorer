// ProvenanceAppStepPredicateTests.swift - The one list and one predicate for a step that ran inside the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.64 (V1-7, R3 of BIO-Q-A2, M2). `ProvenanceAppStep.names` and `isAppStep` replace the two lists
// of four names that the exporter and the export plan held. The predicate reads argv[0], or the first word of the
// script of an `sh -c` argv, as the exporter did. The exporter calls it, so the pins of M1 stay green.

import XCTest
@testable import LungfishWorkflow

final class ProvenanceAppStepPredicateTests: XCTestCase {
    func testTheListHoldsTheFourNamesTheTwoOldListsHeld() {
        XCTAssertEqual(
            ProvenanceAppStep.names,
            ["lungfish.app", "lungfish-app", "lungfish-gui", "lungfish genome explorer"]
        )
    }

    func testAnArgvWhoseFirstWordIsAnAppNameIsAnAppStep() {
        for name in ProvenanceAppStep.names {
            XCTAssertTrue(ProvenanceAppStep.isAppStep([name, "fastq", "merge"]), name)
            XCTAssertTrue(ProvenanceAppStep.isAppStep([name]), "\(name) alone")
        }
    }

    func testAPathAndCapitalLettersChangeNothing() {
        XCTAssertTrue(ProvenanceAppStep.isAppStep(["/Applications/Lungfish.app", "x"]))
        XCTAssertTrue(ProvenanceAppStep.isAppStep(["/Applications/Lungfish.app/Contents/MacOS/lungfish-app", "x"]))
        XCTAssertTrue(ProvenanceAppStep.isAppStep(["/Users/me/LUNGFISH-GUI", "x"]))
        XCTAssertTrue(ProvenanceAppStep.isAppStep(["/Applications/Lungfish Genome Explorer", "x"]))
    }

    func testTheFirstWordOfAShellScriptIsRead() {
        for shell in [["sh", "-c"], ["bash", "-lc"], ["/bin/zsh", "-c"]] {
            for name in ProvenanceAppStep.names {
                XCTAssertTrue(ProvenanceAppStep.isAppStep(shell + ["'\(name)' fastq merge"]), "\(shell) \(name)")
            }
        }
        XCTAssertTrue(ProvenanceAppStep.isAppStep(["sh", "-c", "/Applications/Lungfish.app --flag"]), "a path in the script")
    }

    func testAShellScriptThatIsNotReadIsNoAppStep() {
        XCTAssertFalse(ProvenanceAppStep.isAppStep(["sh", "-c", "lungfish-cli fastq merge"]), "a CLI script")
        XCTAssertFalse(ProvenanceAppStep.isAppStep(["sh", "-x", "lungfish-app fastq merge"]), "only -c and -lc")
        XCTAssertFalse(ProvenanceAppStep.isAppStep(["sh", "-c"]), "no script")
        XCTAssertFalse(ProvenanceAppStep.isAppStep(["python3", "-c", "lungfish-app"]), "only a shell")
        XCTAssertFalse(ProvenanceAppStep.isAppStep(["sh", "-c", ""]), "an empty script")
    }

    func testACLIOrToolStepIsNoAppStep() {
        XCTAssertFalse(ProvenanceAppStep.isAppStep(["lungfish-cli", "fastq", "merge"]))
        XCTAssertFalse(ProvenanceAppStep.isAppStep(["samtools", "sort"]))
        XCTAssertFalse(ProvenanceAppStep.isAppStep(["lungfish-app-helper", "x"]), "a name, not a prefix")
    }

    func testAnEmptyArgvIsNoAppStep() {
        XCTAssertFalse(ProvenanceAppStep.isAppStep([]))
        XCTAssertFalse(ProvenanceAppStep.isAppStep([""]))
    }
}
