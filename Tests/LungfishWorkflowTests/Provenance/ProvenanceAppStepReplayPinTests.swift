// ProvenanceAppStepReplayPinTests.swift - A step that ran inside the app holds no replay line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.64 (V1-7, R3 of BIO-Q-A2, M1). A pin that passes at the base and after the lane. The exporter
// reads a step's replay argv through a list of four app names and a rule for `sh -c`. A record whose only step
// names the app, directly or as the first word of a shell script, gives the plan no replayable step and the shell
// script no line of that step. The lane moves the list and the rule into `ProvenanceAppStep` and changes neither.

import XCTest
@testable import LungfishWorkflow

final class ProvenanceAppStepReplayPinTests: XCTestCase {
    private static let names = ["lungfish.app", "lungfish-app", "lungfish-gui", "lungfish genome explorer"]
    /// A word no real step has, so that a line holding it is a line of the step under test.
    private static let marker = "--replay-pin-marker"

    private func record(_ argv: [String]) -> WorkflowRun {
        var run = WorkflowRun(name: "fastq merge", appVersion: "Lungfish 2026.10.20", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = [
            StepExecution(
                toolName: "lungfish fastq merge",
                toolVersion: "2026.10.20",
                command: argv,
                inputs: [],
                outputs: [],
                exitCode: 0,
                wallTime: 1
            ),
        ]
        return run
    }

    private func assertNoReplayLine(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) {
        let exporter = ProvenanceExporter(signingProvider: nil)
        let run = record(argv)
        XCTAssertTrue(exporter.exportPlan(run).replayableSteps.isEmpty, "the plan replays \(argv)", file: file, line: line)
        let script = exporter.exportShell(run, allowUnpinned: true)
        XCTAssertFalse(script.contains(Self.marker), "the shell script holds a line of \(argv):\n\(script)", file: file, line: line)
    }

    func testAnArgvWhoseFirstWordIsAnAppNameHoldsNoReplayLine() {
        for name in Self.names {
            assertNoReplayLine([name, "fastq", "merge", Self.marker])
        }
    }

    /// The name is the last path component in lower case, so a full path and capital letters change nothing.
    func testAPathAndCapitalLettersChangeNothing() {
        for name in Self.names {
            assertNoReplayLine(["/Applications/\(name.uppercased())", "fastq", "merge", Self.marker])
        }
        assertNoReplayLine(["/Applications/Lungfish.app/Contents/MacOS/lungfish-app", "fastq", "merge", Self.marker])
    }

    func testAShellScriptWhoseFirstWordIsAnAppNameHoldsNoReplayLine() {
        for name in Self.names {
            for shell in [["sh", "-c"], ["bash", "-lc"], ["/bin/zsh", "-c"]] {
                assertNoReplayLine(shell + ["'\(name)' fastq merge \(Self.marker)"])
            }
        }
    }

    /// The pin is not vacuous. A step that names the CLI, or a tool, is still replayed.
    func testAControlStepThatNamesTheCLIOrAToolIsReplayed() {
        let exporter = ProvenanceExporter(signingProvider: nil)
        XCTAssertEqual(exporter.exportPlan(record(["lungfish-cli", "fastq", "merge", Self.marker])).replayableSteps.count, 1)
        XCTAssertEqual(exporter.exportPlan(record(["samtools", "sort", Self.marker])).replayableSteps.count, 1)
    }
}
