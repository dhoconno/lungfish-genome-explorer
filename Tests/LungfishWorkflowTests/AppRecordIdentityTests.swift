// AppRecordIdentityTests.swift - One tool name and kind for a record of work the app does in its own process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.27 REC-TOOL (R1 of BIO-Q-A2, M1). Every record of work the app does in its own process names the
// app by `LungfishAppIdentity.recordedToolName` with kind `LungfishAppIdentity.recordedToolKind`, and a record that
// a `lungfish-cli` process writes names `CLICommandIdentity.executableName` with kind `CLICommandIdentity.recordedToolKind`.
// The readers of `ProvenanceAppStep` give the app's name no replay line, whatever the channel the app runs as.

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class AppRecordIdentityTests: XCTestCase {
    /// A word no real step has, so that a line holding it is a line of the step under test.
    private static let marker = "--app-record-identity-marker"

    private func record(_ argv: [String]) -> WorkflowRun {
        var run = WorkflowRun(name: "app record identity", appVersion: "Lungfish 2026.10.20", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = [
            StepExecution(
                toolName: LungfishAppIdentity.recordedToolName,
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

    func testTheRecordedToolNameIsTheStableChannelsFullName() {
        XCTAssertEqual(LungfishAppIdentity.recordedToolName, "Lungfish Genome Explorer")
        XCTAssertEqual(LungfishAppIdentity.recordedToolName, LungfishAppIdentity.stable.fullName)
    }

    /// F2 and F3. A Preview or Debug run records the same name and kind, since only the stable name is in the readers' list.
    func testTheRecordedToolNameAndKindDoNotFollowTheChannel() {
        XCTAssertNotEqual(LungfishAppIdentity.preview.fullName, LungfishAppIdentity.recordedToolName)
        XCTAssertNotEqual(LungfishAppIdentity.debug.fullName, LungfishAppIdentity.recordedToolName)
        XCTAssertFalse(ProvenanceAppStep.isAppStep([LungfishAppIdentity.preview.fullName, "x"]))
        XCTAssertFalse(ProvenanceAppStep.isAppStep([LungfishAppIdentity.debug.fullName, "x"]))
        XCTAssertEqual(LungfishAppIdentity.recordedToolKind, "gui")
        XCTAssertEqual(CLICommandIdentity.recordedToolKind, "cli")
    }

    func testTheRecordedToolNameIsAnAppStepToTheReaders() {
        XCTAssertTrue(ProvenanceAppStep.isAppStep([LungfishAppIdentity.recordedToolName, "x"]))
        XCTAssertTrue(ProvenanceAppStep.names.contains(LungfishAppIdentity.recordedToolName.lowercased()))
        XCTAssertFalse(ProvenanceAppStep.isAppStep([CLICommandIdentity.executableName, "x"]))
    }

    func testTheExporterScriptHoldsNoReplayLineForAStepWhoseArgvStartsWithTheRecordedToolName() {
        let exporter = ProvenanceExporter(signingProvider: nil)
        let appRun = record([LungfishAppIdentity.recordedToolName, "haplotypes", "save", Self.marker])
        XCTAssertTrue(exporter.exportPlan(appRun).replayableSteps.isEmpty)
        let script = exporter.exportShell(appRun, allowUnpinned: true)
        XCTAssertFalse(script.contains(Self.marker), "the shell script holds a line of the app step:\n\(script)")
    }

    /// The pin is not vacuous. A step that names the CLI is still replayed, with a line that holds its words.
    func testAControlStepThatNamesTheCLIIsReplayed() {
        let exporter = ProvenanceExporter(signingProvider: nil)
        let cliRun = record([CLICommandIdentity.executableName, "haplotypes", "save", Self.marker])
        XCTAssertEqual(exporter.exportPlan(cliRun).replayableSteps.count, 1)
        XCTAssertTrue(exporter.exportShell(cliRun, allowUnpinned: true).contains(Self.marker))
    }
}
