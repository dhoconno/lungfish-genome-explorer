// CLIImportRunnerCancelTests.swift - A cancel before launch, during the import, and the CLI's cleanup time
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// Review findings S4-S2 and S4-S3. Each test runs a shell script in place
/// of `lungfish-cli`, so no real import runs.
final class CLIImportRunnerCancelTests: XCTestCase {

    private var folder: URL!
    private var priorCLIPath: String??

    override func setUp() async throws {
        try await super.setUp()
        await OperationCenter.useTemporaryFailureReportsForTesting()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-import-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let priorCLIPath {
            if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    /// S4-S2: a cancel that arrives before the launch keeps the CLI from
    /// ever running.
    func testACancelBeforeTheLaunchNeverRunsTheCLI() async throws {
        let marker = folder.appendingPathComponent("launched")
        try useFakeCLI("""
        #!/bin/sh
        touch "\(marker.path)"
        """)
        let row = await beginRow()
        let run = startRun(row: row, cancelledBeforeTheRun: true)

        let ended = await waitUntil(timeout: .seconds(10)) { run.finished.values.count == 1 }
        XCTAssertTrue(ended, "the run returns promptly")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the CLI never ran")
        XCTAssertFalse(run.errors.values.isEmpty, "the caller hears that nothing was imported")
        let state = await MainActor.run { OperationCenter.shared.items.first { $0.id == row }?.state }
        XCTAssertEqual(state, .running, "the caller, not the runner, ends the row")
    }

    /// S4 nit: after a cancel the runner leaves the row to the caller, so
    /// the caller's cleanup runs before the row ends.
    func testACancelDuringTheImportLeavesTheRowToTheCaller() async throws {
        let marker = folder.appendingPathComponent("launched")
        try useFakeCLI("""
        #!/bin/sh
        touch "\(marker.path)"
        while true; do sleep 0.1; done
        """)
        let row = await beginRow()
        let run = startRun(row: row)
        let launched = await waitUntil(timeout: .seconds(10)) { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(launched)

        run.task.cancel()

        let ended = await waitUntil(timeout: .seconds(10)) { run.finished.values.count == 1 }
        XCTAssertTrue(ended, "the run returns after the cancel")
        let state = await MainActor.run { OperationCenter.shared.items.first { $0.id == row }?.state }
        XCTAssertEqual(state, .running, "the runner does not fail the row before the caller cleans up")
    }

    /// S4-S3: the CLI gets SIGTERM and time to remove its staging folder
    /// before it is killed. The fake CLI takes a second to clean up, longer
    /// than the old half-second grace period.
    func testACancelGivesTheCLITimeToRemoveItsStagingFolder() async throws {
        let marker = folder.appendingPathComponent("launched")
        let staging = folder.appendingPathComponent("Imports/.SRR1.building-test", isDirectory: true)
        try useFakeCLI("""
        #!/bin/sh
        trap 'sleep 1; rm -rf "\(staging.path)"; exit 125' TERM
        mkdir -p "\(staging.path)"
        touch "\(marker.path)"
        while true; do sleep 0.1; done
        """)
        let row = await beginRow()
        let run = startRun(row: row)
        let launched = await waitUntil(timeout: .seconds(10)) { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(launched)

        run.task.cancel()

        let ended = await waitUntil(timeout: .seconds(15)) { run.finished.values.count == 1 }
        XCTAssertTrue(ended, "the run returns after the CLI exits")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the CLI's own cleanup ran")
    }

    // MARK: - Helpers

    private struct Run {
        let task: Task<Void, Never>
        let errors: Collector
        let finished: Collector
    }

    private func startRun(row: UUID, cancelledBeforeTheRun: Bool = false) -> Run {
        let errors = Collector()
        let finished = Collector()
        let folder = self.folder!
        let task = Task.detached {
            if cancelledBeforeTheRun {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            await CLIImportRunner().run(
                arguments: [],
                operationID: row,
                projectDirectory: folder,
                onBundleCreated: { _ in },
                onError: { errors.append($0) }
            )
            finished.append("finished")
        }
        return Run(task: task, errors: errors, finished: finished)
    }

    private func useFakeCLI(_ script: String) throws {
        let cli = folder.appendingPathComponent("lungfish-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        if priorCLIPath == nil {
            priorCLIPath = .some(ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"])
        }
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
    }

    private func beginRow() async -> UUID {
        let row = await MainActor.run {
            OperationCenter.shared.begin(
                title: "CLI import cancel test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await MainActor.run {
                _ = OperationCenter.shared.complete(id: row, detail: "Test finished")
                OperationCenter.shared.clearItem(id: row)
            }
        }
        return row
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}
