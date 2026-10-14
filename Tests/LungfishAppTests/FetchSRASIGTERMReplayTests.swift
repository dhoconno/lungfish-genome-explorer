// FetchSRASIGTERMReplayTests.swift - SIGTERM to lungfish-cli fetch sra download --bundle cancels the run at its import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3c and the SIGTERM test of ADDING-AN-OPERATION.md, as FetchPathoplexusSIGTERMReplayTests
// checks `fetch pathoplexus`. The ruling (A45-M3-FXA section 1) asks for the cancel on the first event of the
// import stage, alone and through the transport. The leaf downloads and imports in one process with one
// SIGTERM handler, so a cancel that lands in the import must stop the import's tools, remove the staging
// folder `<project>/.tmp/fetch-sra-<UUID>`, publish no bundle, write one `failed` line `Fetch cancelled`
// and exit 125 inside `operationGrace`.
//
// The toolkit stand-in scripts write 200,000 generated reads, so the import lasts well past the moment the
// test sees its first event, a progress line of the import stage. The first test starts the built CLI under
// `sh -c 'exec ...'` with its events in a file, so it reads them while the run goes on, and sends the one
// SIGTERM to the CLI alone, as `kill <pid>` does. The second test runs the CLI on the app's transport and
// cancels it as the Operations panel's Cancel does.
//
// They launch the built lungfish-cli and the managed tools of the import, so the class name ends in
// ReplayTests, which sends it to the integration tier.

import Darwin
import Foundation
import os
import XCTest
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class FetchSRASIGTERMReplayTests: XCTestCase {
    private static let accession = SRAToolkitRecordedRunner.singleEndRun
    private static let bulkReadCount = 200_000

    func testSIGTERMToTheCLIAloneOnTheFirstImportEventCancelsTheRun() async throws {
        let (root, project, environment) = try arrange()
        let events = root.appendingPathComponent("events.ndjson")
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "No lungfish-cli built beside the tests")
        // exec makes the CLI the process the test signals, and its standard output lands in the file.
        let run = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec \"$0\" \"$@\" > \"\(events.path)\"", cli.path] + Self.arguments(project: project),
            environment: CLISIGTERMHarness.childEnvironment(overriding: environment),
            workingDirectory: root)
        defer { run.stop() }

        let reached = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            Self.hasImportStageEvent(Self.lines(of: events))
        }
        let stop = await CLISIGTERMHarness.cancel(run)
        guard reached else {
            return XCTFail("The run never reached its import stage: \(Self.lines(of: events)).\(stop.diagnostics)")
        }
        CLISIGTERMHarness.assertCancelledExit(stop)
        let lines = Self.lines(of: events)
        CLISIGTERMHarness.assertRecordCancelled { Self.status(ofLines: lines) }
        XCTAssertEqual(lines.filter { $0.contains("\"event\":\"failed\"") }.count, 1, "one failed line: \(lines.suffix(3))")
        XCTAssertFalse(lines.contains { $0.contains("bundle created") }, "the cancel landed before the import finished")
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        assertNothingLeft(in: project)
    }

    func testACancelThroughTheTransportOnTheFirstImportEventCancelsTheRun() async throws {
        let (_, project, environment) = try arrange()
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "No lungfish-cli built beside the tests")
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let importReached = OSAllocatedUnfairLock(initialState: false)
        let arguments = Self.arguments(project: project)
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        let task = Task {
            try await transport.run(
                arguments: arguments,
                terminationGracePeriod: CLIProcessLauncher.operationGrace,
                drainGracePeriod: CLIProcessLauncher.operationDrain,
                environmentAdditions: environment,
                isCancelled: { false },
                onEvent: { event in
                    if case let .progress(_, message) = event, message.hasPrefix("Importing") {
                        importReached.withLock { $0 = true }
                    }
                })
        }
        let reached = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            importReached.withLock { $0 }
        }
        guard reached else {
            transport.cancel()
            _ = await task.result
            return XCTFail("The run never reached its import stage")
        }
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
        let watch = try XCTUnwrap(tree.first.flatMap(ChildExitWatch.init(pid:)), "cannot watch \(tree)")
        let sent = ContinuousClock.now
        transport.cancel()
        let result = await task.result
        let elapsed = ContinuousClock.now - sent

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        CLISIGTERMHarness.assertCancelledExit(
            status: watch.exitCode(timeoutSeconds: 5), elapsed: elapsed,
            within: CLIProcessLauncher.operationGrace + DatabaseBrowserGenomeRowCancelReplayTests.margin)
        await CLISIGTERMHarness.assertNoProcessLeft(tree)
        assertNothingLeft(in: project)
    }

    func testSIGTERMToTheCLIAloneWhileTheToolkitDownloadsStopsTheToolkitTree() async throws {
        // The stand-in prefetch notes that it started and waits, so the cancel lands in the download stage
        // with the toolkit's tree running under the CLI.
        let (root, project, environment) = try arrange(toolkitWaits: true)
        let run = try CLISIGTERMHarness.launchCLI(
            Self.arguments(project: project), environment: environment, workingDirectory: root, testClass: Self.self)
        defer { run.stop() }

        let reached = await CLISIGTERMHarness.waitForFile(Self.prefetchMarker(in: root))
        let stop = await CLISIGTERMHarness.cancel(run)
        guard reached else { return XCTFail("The toolkit never started.\(stop.diagnostics)") }
        XCTAssertGreaterThan(stop.tree.count, 1, "the toolkit's tree ran under the CLI: \(stop.tree)")
        CLISIGTERMHarness.assertCancelledExit(stop)
        let lines = stop.standardOutput.split(separator: "\n").map(String.init)
        CLISIGTERMHarness.assertRecordCancelled { Self.status(ofLines: lines) }
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        assertNothingLeft(in: project)
    }

    // MARK: - Arrangement

    /// The file the waiting `prefetch` touches when it starts.
    private static func prefetchMarker(in root: URL) -> URL {
        root.appendingPathComponent("prefetch-started")
    }

    /// A scratch root with a project, the toolkit stand-in scripts, and the child's environment. The scripts
    /// write the generated reads, or `prefetch` waits when `toolkitWaits` is set. NCBI and ENA are asked at an
    /// origin that answers nothing, so no run reaches a network.
    private func arrange(toolkitWaits: Bool = false) throws -> (root: URL, project: URL, environment: [String: String]) {
        let root = try TestTempDirectory.make(prefix: "fetch-sra-sigterm")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let scripts = root.appendingPathComponent("toolkit", isDirectory: true)
        try SRAToolkitStandInScripts.write(
            into: scripts, fixtures: SRAToolkitStandInScripts.fixturesFolder(testFile: #filePath),
            waitingMarker: toolkitWaits ? Self.prefetchMarker(in: root) : nil, bulkReadCount: Self.bulkReadCount)
        return (
            root, project,
            [
                SRAToolkitStandInScripts.variable: scripts.path,
                NCBIServiceEndpoints.standInOriginVariable: "http://127.0.0.1:1",
                ENAServiceEndpoints.standInOriginVariable: "http://127.0.0.1:1",
                "NCBI_API_KEY": "",
            ])
    }

    private static func arguments(project: URL) -> [String] {
        [
            "fetch", "sra", "download", accession, "--bundle", "--project", project.path, "--use-toolkit",
            "--platform", "illumina", "--compression", "fast", "--no-optimize-storage", "--format", "json",
        ]
    }

    // MARK: - Reading the events

    private static func lines(of file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The first progress line of the import stage, `Importing <run> (1/1)`, as the transcripts show it.
    private static func hasImportStageEvent(_ lines: [String]) -> Bool {
        let decoder = CLIEventLineDecoder()
        return lines.contains { line in
            if case let .progress(_, message)? = try? decoder.decode(line: line) { return message.hasPrefix("Importing") }
            return false
        }
    }

    private static func status(ofLines lines: [String]) -> String? {
        FetchNCBIBundleSIGTERMReplayTests.status(ofEvents: lines.joined(separator: "\n"))
    }

    // MARK: - Assertions

    /// A cancelled run leaves no bundle and no staging folder or batch folder in the project.
    private func assertNothingLeft(in project: URL) {
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, "Imports").filter { $0.hasSuffix(".lungfishfastq") }, [],
            "a cancelled run publishes no bundle")
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, ".tmp").filter {
                $0.hasPrefix("fetch-sra-") || $0.hasPrefix("sra-batch-")
            }, [],
            "a cancelled run leaves no staging folder")
    }
}
