// ONTImportCLIRouteTests.swift - The ONT import's route onto lungfish-cli fastq import-ont, on a stand-in command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M3 (panel decisions C11, C4, C5 and P2, ARCH 2 and 7, UX 1, 3 and 4). The window's ONT
// import launches `lungfish-cli fastq import-ont --format json` on the L6 runner (`CLIReadsRunner`) and
// reports through `OperationCenterCLIBridge`. These tests run the coordinator against a stand-in
// `lungfish-cli` script that records its arguments and prints the lines a test gives it, so each fact of the
// route is checked without an import. The built command is exercised by ONTImportRouteFreezeTests (the
// window), FastqImportONTCancelTests (SIGTERM through the transport) and ONTImportCLIGUIParityReplayTests.
//
// - The row records the argv the runner launched (ARCH 2, U-c).
// - The row ends with the words the command's `complete` line gave, and lists its bundles in barcode order.
// - The bundles stay off the row, and the row stays cancellable, until the command has finished (UX 4).
// - A `failed` line fails the row with its words, and the call throws them (W3).
// - The row's cancel stops the command and the row reads Cancelled (UX 4).

import Foundation
import XCTest
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ONTImportCLIRouteTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ont-import-cli-route")
        source = try ONTImportFreezeFixture.makeSource(in: root)
        project = root.appendingPathComponent("project", isDirectory: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The argv

    func testTheRowRecordsTheArgvTheRunnerLaunched() async throws {
        let stub = try makeStub(lines: Self.successLines(bundles: ["barcode01", "barcode02"]), status: 0)
        let reporter = RecordingOperationReporter()

        try await runImport(reporter: reporter, stub: stub, includeUnclassified: true, concurrency: 2)

        let launched = try String(contentsOf: stub.argvFile, encoding: .utf8).split(separator: "\n").map(String.init)
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launched, try RecordedCLICommand.arguments(of: item.cliCommand), "the row records the argv that ran")
        XCTAssertEqual(Array(launched.prefix(3)), ["fastq", "import-ont", source.path])
        XCTAssertEqual(Array(launched.suffix(2)), ["--format", "json"], "the command prints events, so the row can show them")
        XCTAssertTrue(launched.contains("--include-unclassified"))
        XCTAssertEqual(launched.firstIndex(of: "--concurrency").map { launched[$0 + 1] }, "2")
    }

    // MARK: - The end of a run

    func testTheRowEndsWithTheCommandsWordsAndListsItsBundlesInBarcodeOrder() async throws {
        let stub = try makeStub(lines: Self.successLines(bundles: ["barcode02", "barcode01"]), status: 0)
        let reporter = RecordingOperationReporter()

        let outcome = try await runImport(reporter: reporter, stub: stub)

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "ONT Import: fastq_pass")
        XCTAssertEqual(item.initialDetail, "Detecting layout...")
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.detail, "2 barcode bundles, 3 reads", "the row ends with the words of the complete line")
        let expected = ["barcode02", "barcode01"].map { bundle($0).path }
        XCTAssertEqual(item.bundleURLs.map(\.path), expected, "the bundles keep the order the command listed them in")
        XCTAssertEqual(outcome.bundleURLs.map(\.path), expected, "the window opens the first of them")
        XCTAssertEqual(outcome.detail, "2 barcode bundles, 3 reads")
    }

    // MARK: - Hidden until complete

    func testTheBundlesStayOffTheRowAndTheRowStaysCancellableUntilTheCommandFinishes() async throws {
        let stub = try makeStub(lines: Self.successLines(bundles: ["barcode01"]), status: 0, waitsForGo: true)
        let reporter = RecordingOperationReporter()
        let coordinator = ONTImportOperationCoordinator(
            operationCenter: reporter, runner: CLIReadsRunner(cliURLOverride: stub.cli)
        )
        let task = Task {
            try await coordinator.importDirectory(
                sourceURL: self.source, projectURL: self.project, includeUnclassified: true, routeContext: nil
            )
        }

        let running = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: stub.pidFile.path) }
        XCTAssertTrue(running, "the command never started")
        let during = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(during.state, .running)
        XCTAssertTrue(during.bundleURLs.isEmpty, "no result is listed while the command runs")
        XCTAssertTrue(during.hasCancelCallback, "the row can be cancelled while the command runs")

        try Data().write(to: stub.goFile)
        let outcome = try await task.value

        let after = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(after.state, .completed)
        XCTAssertEqual(after.bundleURLs.map(\.path), [bundle("barcode01").path])
        XCTAssertEqual(outcome.bundleURLs.map(\.path), [bundle("barcode01").path])
    }

    // MARK: - A failure

    func testAFailedLineFailsTheRowWithItsWordsAndTheCallThrowsThem() async throws {
        let words = "Failed to concatenate barcode01: the chunk could not be read"
        let stub = try makeStub(lines: [Self.line("start", ["message": "Detecting layout...", "progress": 0]), Self.line("failed", ["error": words])], status: 64)
        let reporter = RecordingOperationReporter()

        do {
            try await runImport(reporter: reporter, stub: stub)
            XCTFail("a failed import must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, words, "the sheet shows the command's words alone")
        }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.failure?.detail, words)
        XCTAssertEqual(item.failure?.errorMessage, words)
        XCTAssertTrue(item.bundleURLs.isEmpty, "a failed run lists nothing")
    }

    // MARK: - A cancel

    func testTheRowsCancelStopsTheCommandAndTheRowReadsCancelled() async throws {
        let stub = try makeStub(lines: [], status: 0, hangs: true)
        let reporter = RecordingOperationReporter()
        let coordinator = ONTImportOperationCoordinator(
            operationCenter: reporter, runner: CLIReadsRunner(cliURLOverride: stub.cli)
        )
        let task = Task {
            try await coordinator.importDirectory(
                sourceURL: self.source, projectURL: self.project, includeUnclassified: false, routeContext: nil
            )
        }
        let running = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: stub.pidFile.path) }
        XCTAssertTrue(running, "the command never started")
        let id = try XCTUnwrap(reporter.items.first).id

        reporter.cancel(id: id)

        do {
            _ = try await task.value
            XCTFail("a cancelled import must throw")
        } catch is CancellationError {
            // The window shows no sheet for it.
        } catch {
            XCTFail("a cancel throws CancellationError, not \(error)")
        }
        XCTAssertEqual(reporter.items.first?.state, .cancelled)
        let pid = try XCTUnwrap(Int32(try String(contentsOf: stub.pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let gone = await waitUntil(timeout: .seconds(30)) { kill(pid, 0) != 0 }
        XCTAssertTrue(gone, "the command is still running after the cancel")
    }

    // MARK: - Helpers

    @discardableResult
    private func runImport(
        reporter: RecordingOperationReporter,
        stub: Stub,
        includeUnclassified: Bool = true,
        concurrency: Int = 4
    ) async throws -> (bundleURLs: [URL], detail: String) {
        let coordinator = ONTImportOperationCoordinator(
            operationCenter: reporter, runner: CLIReadsRunner(cliURLOverride: stub.cli)
        )
        return try await coordinator.importDirectory(
            sourceURL: source,
            projectURL: project,
            includeUnclassified: includeUnclassified,
            concurrency: concurrency,
            routeContext: nil
        )
    }

    /// The bundle the stand-in names for `barcode`. The stand-in writes nothing, so the path is its own.
    private func bundle(_ barcode: String) -> URL {
        URL(fileURLWithPath: Self.bundlePath(barcode), isDirectory: true)
    }

    private static func bundlePath(_ barcode: String) -> String {
        "/ont-import-cli-route/\(barcode).lungfishfastq"
    }

    /// The lines of a command that imported `bundles` and said so.
    private static func successLines(bundles: [String]) -> [String] {
        let outputs = bundles.map(bundlePath)
        return [
            line("start", ["message": "Detecting layout...", "progress": 0]),
            line("progress", ["message": "Detecting ONT directory layout...", "progress": 0]),
            line("progress", ["message": "Completed 2/2 barcodes", "progress": 1]),
            line("complete", [
                "message": "\(bundles.count) barcode bundles, 3 reads", "output": outputs[0], "outputs": outputs, "progress": 1,
            ]),
        ]
    }

    private static func line(_ event: String, _ fields: [String: Any]) -> String {
        var object = fields
        object["event"] = event
        object["schemaVersion"] = 2
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// A stand-in `lungfish-cli`. It writes the arguments it got and its process ID, waits for `goFile` when
    /// told to or sleeps until it is signaled, prints `lines` on standard output and exits with `status`.
    private struct Stub {
        let cli: URL
        let argvFile: URL
        let pidFile: URL
        let goFile: URL
    }

    private func makeStub(lines: [String], status: Int32, waitsForGo: Bool = false, hangs: Bool = false) throws -> Stub {
        let folder = root.appendingPathComponent("stub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stub = Stub(
            cli: folder.appendingPathComponent("lungfish-cli"),
            argvFile: folder.appendingPathComponent("argv.txt"),
            pidFile: folder.appendingPathComponent("pid.txt"),
            goFile: folder.appendingPathComponent("go")
        )
        var script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(stub.argvFile.path)'\necho $$ > '\(stub.pidFile.path)'\n"
        if hangs { script += "exec /bin/sleep 300\n" }
        if waitsForGo { script += "while [ ! -e '\(stub.goFile.path)' ]; do sleep 0.05; done\n" }
        for line in lines { script += "printf '%s\\n' '\(line)'\n" }
        script += "exit \(status)\n"
        try script.write(to: stub.cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.cli.path)
        return stub
    }
}
