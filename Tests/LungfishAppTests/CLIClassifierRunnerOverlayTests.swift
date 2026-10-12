// CLIClassifierRunnerOverlayTests.swift - The CLI route shows a command's line on the overlay only while its row runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishTestSupport

/// Row T2 of the Phase 2.9 UX inventory on the app's CLI route (lane U10, second milestone). The
/// runner hands the viewer's overlay a line of the command only while the command's row runs. A
/// line the command prints once its row is cancelling, here from its SIGTERM handler, reaches
/// neither the row nor the overlay.
@MainActor
final class CLIClassifierRunnerOverlayTests: XCTestCase {
    override func tearDown() async throws {
        OperationCenter.shared.clearCompleted()
        try await super.tearDown()
    }

    func testALineThatArrivesOnceTheRowIsCancellingNeverReachesTheOverlay() async throws {
        let root = try TestTempDirectory.make(prefix: "cli-classifier-runner-overlay")
        defer { TestTempDirectory.cleanup(root) }
        let lateLine = "A line after the cancel"
        let cli = try ClassifierRouteFixtures.cancellableCLI(
            in: root,
            lines: [
                #"{"event":"start","message":"Starting Kraken2.","progress":0,"schemaVersion":2}"#,
                #"{"event":"progress","message":"Running kraken2...","progress":0.2,"schemaVersion":2}"#,
            ],
            ready: root.appendingPathComponent("ready"),
            terminated: root.appendingPathComponent("terminated"),
            lastLine: #"{"event":"progress","message":"\#(lateLine)","progress":0.5,"schemaVersion":2}"#
        )
        let runner = CLIClassifierRunner(cliURLOverride: cli)
        let rowID = OperationCenter.shared.begin(
            title: "Kraken2 overlay case",
            detail: "Starting",
            operationType: .classification,
            cliCommand: nil,
            onCancel: { runner.cancel() }
        ).rowID
        let overlay = OverlayLines()
        let run = Task { @MainActor in
            try await runner.run(
                CLIClassifierRunRequest(tool: .kraken2, arguments: ["kraken2", "classify"], sampleIDs: ["reads"]),
                operationID: rowID
            ) { line in overlay.lines.append(line) }
        }

        let shownWhileRunning = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(10)) {
            overlay.lines.contains("Running kraken2...")
        }
        XCTAssertTrue(shownWhileRunning, "a line of the running row never reached the overlay, \(overlay.lines)")
        OperationCenter.shared.cancel(id: rowID)
        let outcome = await run.result
        guard case .failure(let error) = outcome, error is CancellationError else {
            return XCTFail("a cancelled run must end in CancellationError, got \(outcome)")
        }

        // The runner hands the overlay each line before it returns, and the main actor runs those
        // hand-overs in order, so by now the late line has been offered and refused.
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == rowID })
        XCTAssertEqual(row.state, .cancelling)
        XCTAssertEqual(row.detail, "Cancelling...", "the row refuses the late line")
        XCTAssertFalse(overlay.lines.contains(lateLine), "the overlay refuses it too, \(overlay.lines)")
        OperationCenter.shared.acknowledgeCancellation(id: rowID)
    }
}

/// The lines a case's overlay showed.
@MainActor
private final class OverlayLines {
    var lines: [String] = []
}
