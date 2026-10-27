// AssemblyFailureAlertTests.swift - A failed Reassemble shows the failure alert (backlog REASSEMBLE-FREE-NAME)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The walk of 2026-10-22 (obs-23) saw the second Reassemble fail on the Operations row only, "Failed" with an
// Issue button and no alert. ADDING-AN-OPERATION.md step 17 says a failure calls `fail` and shows an alert,
// and the failure alert of UX 4 names what happened and the next thing to try, with the log behind View Log.
// The managed assembly route runs a stand-in `lungfish-cli` here and a recorder takes the alert's place, since
// an alert in a unit test waits for a click that never comes.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class AssemblyFailureAlertTests: XCTestCase {
    /// A stand-in run ends in well under a second. The budget leaves room for a loaded Mac.
    private static let standInRun = WaitBudget(name: "stand-in CLI run", duration: .seconds(30))

    /// The alerts a run handed over, in order. The route hands them over on the main actor.
    @MainActor
    private final class AlertLog {
        var alerts: [AssemblyFailureAlert] = []
    }

    func testAFailedReassembleShowsTheFailureAlertWithWhatHappenedAndWhatToTry() async throws {
        let run = try await failedRun(failedLine: "SPAdes stopped: not enough memory")

        XCTAssertEqual(run.alerts.count, 1, "a failed run shows one alert")
        let alert = try XCTUnwrap(run.alerts.first)
        XCTAssertEqual(alert.title, "SPAdes Assembly Failed")
        // What happened: the run it names and the command's own words.
        XCTAssertTrue(alert.message.contains("demo"), alert.message)
        XCTAssertTrue(alert.message.contains("SPAdes stopped: not enough memory"), alert.message)
        // What to try next, and where the log is.
        XCTAssertTrue(alert.message.contains("View Log"), alert.message)
        XCTAssertTrue(alert.message.contains("run the assembly again"), alert.message)
        XCTAssertEqual(run.item.detail, "SPAdes stopped: not enough memory", "the row keeps the command's words")
    }

    func testAnAlertCarriesTheRefusalOfABundleThatAlreadyExists() async throws {
        let words = "Output assembly bundle already exists: /Projects/Demo.lungfish/Analyses/demo.lungfishref"
        let run = try await failedRun(failedLine: words)

        let alert = try XCTUnwrap(run.alerts.first)
        XCTAssertTrue(alert.message.contains(words), alert.message)
    }

    // MARK: - Helpers

    /// Runs a managed assembly on a stand-in `lungfish-cli` that fails with `failedLine`, and returns the
    /// ended row and the alerts the route handed over by the time the row ended.
    private func failedRun(failedLine: String) async throws -> (item: OperationCenter.Item, alerts: [AssemblyFailureAlert]) {
        let root = try TestTempDirectory.make(prefix: "assembly-failure-alert")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let script = root.appendingPathComponent("lungfish-cli")
        try """
        #!/bin/sh
        echo '{"error":"\(failedLine)","event":"failed","schemaVersion":2}'
        exit 1

        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [root.appendingPathComponent("reads.fastq")],
            projectName: "demo",
            outputDirectory: root.appendingPathComponent("Analyses", isDirectory: true),
            threads: 1
        ).normalizedForExecution()
        let log = AlertLog()

        let opID = try XCTUnwrap(AssemblyRunner.startManagedAssembly(
            request: request,
            routeContext: nil,
            runner: CLIReadsRunner(cliURLOverride: script),
            presentFailureAlert: { log.alerts.append($0) }
        ))
        let ended = await waitUntil(budget: Self.standInRun) {
            OperationCenter.shared.items.first { $0.id == opID }?.state == .failed
        }
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == opID })
        OperationCenter.shared.clearItem(id: opID)
        XCTAssertTrue(ended, "the stand-in's failed line ends the row: \(item.state)")
        // The route fails the row and hands over the alert in one stretch on the main actor, so a row
        // seen as failed has either shown its alert or never will.
        return (item, log.alerts)
    }
}
