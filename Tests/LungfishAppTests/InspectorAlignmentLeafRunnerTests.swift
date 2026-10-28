// InspectorAlignmentLeafRunnerTests.swift - The Inspector's alignment workflows on the L3 runner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A54. Create Filtered Alignment Track, Convert Mapped Reads to Annotations and the two
// duplicate workflows launch `lungfish-cli` leaves on A51's runner when their route says so. These tests
// run the one run helper, `runAlignmentLeafThroughCLI`, against a stand-in CLI that prints the events of
// a leaf. A run that completes hands its outputs back and leaves the row running, so the result stays
// hidden until the caller completes the row. A run that fails carries the leaf's own words. A run the
// row's Cancel stops ends the row Cancelled, resets the caller and never reaches `finish`.

import Foundation
import XCTest
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class InspectorAlignmentLeafRunnerTests: XCTestCase {
    private var root: URL!
    private var overlayMessages: [String] = []
    private var cancelledCalls = 0
    private var finishCalls = 0

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "alignment-leaf-runner")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private let arguments = ["bundle", "deduplicate-alignments", "/tmp/leaf runner/Sample.lungfishref", "--format", "json"]

    /// A row on the shared center, which the runner's bridge writes to.
    private func beginRow() throws -> UUID {
        guard case .started(let id) = OperationCenter.shared.begin(
            title: "Leaf runner test", detail: "Starting", operationType: .bamImport, cliCommand: nil
        ) else {
            throw XCTSkip("the shared center refused the row")
        }
        return id
    }

    private func row(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    func testTheRunnerRunsTheArgvItWasGivenAndHandsBackWhatCompleteNamed() async throws {
        let stand = try StandInAlignmentCLI.make(in: root, body: [
            StandInAlignmentCLI.line(#"{"event":"start","message":"Creating deduplicated bundle...","progress":0}"#),
            StandInAlignmentCLI.line(#"{"event":"progress","progress":0.5,"message":"Sample BAM: removing duplicates..."}"#),
            StandInAlignmentCLI.line(#"{"event":"complete","output":"/tmp/out.lungfishref","outputs":["/tmp/out.lungfishref"],"message":"Created out.lungfishref."}"#),
        ].joined(separator: "\n"))
        let id = try beginRow()
        defer { OperationCenter.shared.finishAndClearForTest(id: id) }

        let outcome = await withCheckedContinuation { continuation in
            InspectorViewController.runAlignmentLeafThroughCLI(
                arguments: arguments,
                operationID: id,
                runner: CLIAlignmentActionRunner(cliURLOverride: stand.cli),
                overlay: { [self] message in overlayMessages.append(message) },
                finish: { continuation.resume(returning: $0) }
            )
        }

        let completion = try outcome.get()
        XCTAssertEqual(completion.outputs, ["/tmp/out.lungfishref"])
        XCTAssertEqual(completion.message, "Created out.lungfishref.")
        XCTAssertEqual(stand.arguments(), arguments, "the leaf got the argv the row records")
        XCTAssertEqual(row(id)?.state, .running, "the runner completes nothing, so the result stays hidden until the caller completes the row")
        await waitUntil(timeout: .seconds(30)) { row(id)?.detail == "Sample BAM: removing duplicates..." }
        XCTAssertEqual(row(id)?.detail, "Sample BAM: removing duplicates...", "the bridge puts the leaf's words in the row")
        await waitUntil(timeout: .seconds(30)) { overlayMessages.contains("Sample BAM: removing duplicates...") }
        XCTAssertEqual(overlayMessages, ["Sample BAM: removing duplicates..."], "the overlay gets each progress message the row takes")
    }

    func testALeafThatFailsFailsTheRunWithItsOwnWords() async throws {
        let stand = try StandInAlignmentCLI.make(in: root, body: [
            StandInAlignmentCLI.line(#"{"event":"start","message":"Creating deduplicated bundle...","progress":0}"#),
            StandInAlignmentCLI.line(#"{"event":"failed","error":"No alignment tracks are loaded in this bundle."}"#),
            "exit 3",
        ].joined(separator: "\n"))
        let id = try beginRow()
        defer { OperationCenter.shared.finishAndClearForTest(id: id) }

        let outcome = await withCheckedContinuation { continuation in
            InspectorViewController.runAlignmentLeafThroughCLI(
                arguments: arguments,
                operationID: id,
                runner: CLIAlignmentActionRunner(cliURLOverride: stand.cli),
                finish: { continuation.resume(returning: $0) }
            )
        }

        guard case .failure(let error) = outcome else { return XCTFail("a failed leaf is a failure: \(outcome)") }
        XCTAssertEqual(error.localizedDescription, "No alignment tracks are loaded in this bundle.")
        XCTAssertEqual(cancelledCalls, 0)
    }

    func testTheRowsCancelEndsTheRowCancelledAndResetsTheCaller() async throws {
        let stand = try StandInAlignmentCLI.make(in: root, body: "exec sleep 120")
        let id = try beginRow()
        defer { OperationCenter.shared.finishAndClearForTest(id: id) }

        InspectorViewController.runAlignmentLeafThroughCLI(
            arguments: arguments,
            operationID: id,
            runner: CLIAlignmentActionRunner(cliURLOverride: stand.cli),
            cancelled: { [self] in cancelledCalls += 1 },
            finish: { [self] _ in finishCalls += 1 }
        )
        await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: stand.startedFile.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stand.startedFile.path), "the leaf started")

        OperationCenter.shared.cancel(id: id)
        await waitUntil(timeout: .seconds(30)) { cancelledCalls > 0 }

        XCTAssertEqual(cancelledCalls, 1, "the caller resets its own state once")
        XCTAssertEqual(row(id)?.state, .cancelled)
        XCTAssertEqual(finishCalls, 0, "a cancelled run is neither a success nor a failure")
    }
}
