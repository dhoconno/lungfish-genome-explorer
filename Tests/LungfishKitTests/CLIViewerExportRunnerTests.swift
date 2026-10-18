// CLIViewerExportRunnerTests.swift - The shared viewer export runner through the real transport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M2 (ARCH ruling X-4, rule 2 of 1.5). Each test runs a stand-in `lungfish-cli` through
// `CLISubprocessTransport` and reads the row the runner settled on `OperationCenter.shared`.

import Darwin
import Foundation
import XCTest
import LungfishCore
@testable import LungfishKit

@MainActor
final class CLIViewerExportRunnerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIViewerExportRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheRunnerGivesTheLeafTheOperationGraceAndDrain() {
        XCTAssertEqual(CLIViewerExportRunner.terminationGracePeriod, CLIProcessLauncher.operationGrace)
        XCTAssertEqual(CLIViewerExportRunner.drainGracePeriod, CLIProcessLauncher.operationDrain)
    }

    func testACompletedLeafCompletesTheRowWithTheFileItNamed() async throws {
        let output = folder.appendingPathComponent("table.tsv")
        let cli = try standInCLI("""
        printf '%s\\n' '{"event":"progress","progress":0.5,"message":"Writing the table.","schemaVersion":2}'
        printf 'a\\tb\\n' > "\(output.path)"
        printf '%s\\n' '{"event":"complete","outputs":["\(output.path)"],"progress":1,"schemaVersion":2}'
        exit 0
        """)
        let id = try beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }

        let outcome = await CLIViewerExportRunner(cliURLOverride: cli).run(
            arguments: ["test", "export", "table", "-o", output.path, "--format", "json"],
            outputURL: output, operationID: id, completionDetail: "Exported table.tsv"
        )

        XCTAssertEqual(outcome, .completed(output))
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(row.state, .completed)
        XCTAssertEqual(row.detail, "Exported table.tsv")
        XCTAssertEqual(row.outputURLs, [output])
        XCTAssertTrue(row.logEntries.contains { $0.message == "Writing the table." }, "the bridge logs the leaf's progress")
    }

    func testAFailedLeafFailsTheRowWithItsMessage() async throws {
        let cli = try standInCLI("""
        printf '%s\\n' '{"error":"Result folder not found: /missing","event":"failed","schemaVersion":2}'
        exit 64
        """)
        let id = try beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }

        let outcome = await CLIViewerExportRunner(cliURLOverride: cli).run(
            arguments: [], outputURL: folder.appendingPathComponent("never.tsv"), operationID: id,
            completionDetail: "unused"
        )

        let failure = CLIViewerExportRunner.Failure(message: "Result folder not found: /missing")
        XCTAssertEqual(outcome, .failed(failure))
        XCTAssertEqual(failure.localizedDescription, "Result folder not found: /missing", "the alert reads the message alone")
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == id }?.state, .failed)
    }

    /// An existing leaf whose contract row is not `.events` writes no `complete` line, and its row completes on exit 0.
    func testALeafWithoutEventsCompletesOnExitZero() async throws {
        let output = folder.appendingPathComponent("definitions.tsv")
        let cli = try standInCLI("""
        printf 'x\\n' > "\(output.path)"
        echo "Wrote definitions.tsv" >&2
        exit 0
        """)
        let id = try beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }

        let outcome = await CLIViewerExportRunner(cliURLOverride: cli).run(
            arguments: [], outputURL: output, operationID: id, completionDetail: "Exported definitions.tsv",
            emitsEvents: false
        )

        XCTAssertEqual(outcome, .completed(output))
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == id }?.state, .completed)
    }

    /// A cancel reaches the leaf as SIGTERM through the real transport. The stand-in rolls its partial output back
    /// inside the grace and exits 125, as a leaf on `writeAtomically` does, and the row reads Cancelled.
    func testACancelSendsTheLeafSIGTERMAndTheRowReadsCancelled() async throws {
        let output = folder.appendingPathComponent("partial.tsv")
        let pidFile = folder.appendingPathComponent("leaf.pid")
        let cli = try standInCLI("""
        trap 'rm -f "\(output.path)"; exit 125' TERM
        printf 'partial\\n' > "\(output.path)"
        echo $$ > "\(pidFile.path)"
        while true; do /bin/sleep 1; done
        """)
        let id = try beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }
        let runner = CLIViewerExportRunner(cliURLOverride: cli)
        let run = Task { await runner.run(arguments: [], outputURL: output, operationID: id, completionDetail: "unused") }

        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "the stand-in leaf started")
        runner.cancel()
        let outcome = await run.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the leaf rolled its output back on SIGTERM")
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == id }?.state, .cancelled)
    }

    // MARK: - Helpers

    private func beginRow() throws -> UUID {
        let result = OperationCenter.shared.begin(
            title: "Export Table", detail: "Exporting table...", operationType: .export,
            cliCommand: "lungfish-cli test export table"
        )
        guard case .started(let id) = result else {
            throw XCTSkip("the operation center refused the row")
        }
        return id
    }

    private func standInCLI(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
