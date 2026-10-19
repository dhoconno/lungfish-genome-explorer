// BlastSubmitRouteRowTests.swift - The row and the drawer when a BLAST read action's leaf fails or is cancelled
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A65 M2, review fix F4 (UX 1, SWIFT SC4). The three parity classes run a leaf that ends well.
// These tests run the route's launch (`ViewerViewController.launchBlastSubmit`) on a stand-in `lungfish-cli`
// script and a row begun on `OperationCenter.shared`, then read the row and the drawer as the person sees
// them. A leaf that prints a `failed` event fails the row and the drawer with the leaf's words, and a cancel
// of the row stops a running leaf and ends the row cancelled with no failure text. No network and no tool run.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

/// What the drawer of a BLAST action was told, in order.
@MainActor
private final class DrawerSpy {
    private(set) var phases: [BlastJobPhase] = []
    private(set) var results: [BlastVerificationResult] = []
    private(set) var failures: [String] = []

    var drawer: BlastSubmitDrawer {
        BlastSubmitDrawer(
            loading: { [self] phase in phases.append(phase) },
            results: { [self] result, _ in results.append(result) },
            failure: { [self] text in failures.append(text) }
        )
    }
}

@MainActor
final class BlastSubmitRouteRowTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "blast-submit-row")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    /// The leaf's `failed` event is the shape of `Tests/Fixtures/cli-events/commands/blast-submit/failed.ndjson`.
    /// The runner throws its words, so the row fails with them as its error text and detail, the drawer shows
    /// the same string once, and no result reaches the drawer.
    func testAFailedLeafFailsTheRowAndTheDrawerWithTheLeafsWords() async throws {
        let words = "BLAST search failed: NCBI did not answer the status request"
        let events = folder.appendingPathComponent("failed.ndjson")
        let lines = [
            #"{"event":"start","message":"Preparing to BLAST query.fasta","progress":0,"schemaVersion":2}"#,
            #"{"error":"\#(words)","event":"failed","schemaVersion":2}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: events, atomically: true, encoding: .utf8)
        let cli = try standInCLI("/bin/cat '\(events.path)'\nexit 1\n")
        let plan = try makePlan()
        let id = beginRow(for: plan)
        defer { OperationCenter.shared.clearItem(id: id) }
        let spy = DrawerSpy()

        let task = ViewerViewController.launchBlastSubmit(
            plan, operationID: id, runner: CLIBlastSubmitRunner(cliURLOverride: cli), drawer: spy.drawer
        ) { _ in "completed" }
        await task.value

        let item = try XCTUnwrap(self.item(id))
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertEqual(item.errorMessage, words, "the row's error text is the leaf's message")
        XCTAssertEqual(item.detail, words)
        XCTAssertEqual(spy.failures, [words], "the drawer shows the leaf's message once")
        XCTAssertEqual(spy.results.count, 0)
        XCTAssertEqual(spy.phases.first, .submitting)
    }

    /// A cancel of the row reaches the running leaf through the runner, which sends SIGTERM to the leaf's
    /// group. The leaf is gone inside the 6 s grace of `CLIProcessLauncher.operationGrace` (7 s here), the row
    /// reads Cancelled with no error text, and the drawer is told nothing of a failure or a result.
    func testCancellingTheRowStopsARunningLeaf() async throws {
        let pidFile = folder.appendingPathComponent("leaf.pid")
        let partial = folder.appendingPathComponent("leaf.pid.partial")
        // The script is the leaf. It records its process ID, then becomes `sleep`, so the ID stays its own.
        let cli = try standInCLI(
            "/bin/echo $$ > '\(partial.path)'\n/bin/mv '\(partial.path)' '\(pidFile.path)'\nexec /bin/sleep 30\n"
        )
        let plan = try makePlan()
        let id = beginRow(for: plan)
        defer { OperationCenter.shared.clearItem(id: id) }
        let spy = DrawerSpy()
        let task = ViewerViewController.launchBlastSubmit(
            plan, operationID: id, runner: CLIBlastSubmitRunner(cliURLOverride: cli), drawer: spy.drawer
        ) { _ in "completed" }

        let started = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: pidFile.path) }
        XCTAssertTrue(started, "the stand-in leaf never started")
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(Self.processExists(pid), "the leaf runs before the cancel")

        let cancelledAt = ContinuousClock.now
        OperationCenter.shared.cancel(id: id)
        await task.value
        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(7), "the leaf stopped inside the grace, not at its 30 s end")
        let gone = await waitUntil(timeout: .seconds(7)) { !Self.processExists(pid) }
        XCTAssertTrue(gone, "the leaf process \(pid) is still there")

        let item = try XCTUnwrap(self.item(id))
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(item.displayStateLabel, "Cancelled")
        XCTAssertEqual(item.detail, "Cancelled by user")
        XCTAssertNil(item.errorMessage, "a cancel carries no failure text")
        XCTAssertEqual(spy.failures, [], "the drawer is told of no failure")
        XCTAssertEqual(spy.results.count, 0)
    }

    // MARK: - Fixtures

    /// A plan for two reads under a project of this test's folder.
    private func makePlan() throws -> BlastSubmitPlan {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return try BlastSubmitPlan.make(
            sequences: [(id: "read_1", sequence: "ACGTACGTACGTACGTACGT"), (id: "read_2", sequence: "GGCCTTAAGGCCTTAAGGCC")],
            label: "Row fixture", projectURL: project
        )
    }

    /// The row the viewer begins for `plan`, with the command the run executes.
    private func beginRow(for plan: BlastSubmitPlan) -> UUID {
        OperationCenter.shared.begin(
            title: "BLAST Row fixture", detail: "Preparing BLAST verification\u{2026}", operationType: .blastVerification,
            cliCommand: plan.cliCommand
        ).rowID
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// A shell script in place of `lungfish-cli` that runs `body`.
    private func standInCLI(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private nonisolated static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }
}
