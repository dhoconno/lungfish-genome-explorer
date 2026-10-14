// DatabaseBrowserSRARowRouteReplayTests.swift - The CLI route of an SRA row launches one child for each run and records its command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3, panel decision C4 and UX 7. With the hidden key on `cli` and a project in the
// route context, the SRA row begins before the import sheet with no command, and `startSRADownloadTask`
// sets one line for each run once the sheet is confirmed. The row then launches `lungfish-cli fetch sra
// download` for the first run. A stand-in program takes the place of the CLI here, notes its arguments and
// waits, so the test checks what the route launches and what the row records without the real tools. The
// Operations panel's Cancel ends the row as Cancelled, launches no child for the second run and leaves
// nothing in the project. The real CLI's cancel in each stage, and the parity with the window's own task,
// are `DatabaseBrowserSRARowCancelReplayTests` and `DatabaseBrowserSRARowParityReplayTests`.
//
// It launches a script, so the class name ends in ReplayTests, which sends it to the integration tier.

import AppKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class DatabaseBrowserSRARowRouteReplayTests: XCTestCase {
    func testTheCLIRouteRecordsOneLinePerRunAndACancelEndsTheRowCancelled() async throws {
        // A batch with a project asks `AppDelegate.shared` whether the project is writable, which reads `NSApp`.
        _ = NSApplication.shared
        let root = try TestTempDirectory.make(prefix: "sra-row-route")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let tools = root.appendingPathComponent("stand-in", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let fakeCLI = tools.appendingPathComponent("lungfish-cli")
        let launches = tools.appendingPathComponent("launches")
        // A stand-in for the CLI that notes the arguments it was launched with, then waits. `exec` makes
        // the SIGTERM of the cancel reach the sleep.
        try "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/launches\"\nexec sleep 600\n"
            .write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let prior = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        defer { if let prior { setenv("LUNGFISH_CLI_PATH", prior, 1) } else { unsetenv("LUNGFISH_CLI_PATH") } }

        let suite = makeTestDefaultsSuite(prefix: "DatabaseBrowserSRARowRouteReplayTests")
        suite.defaults.set(SRARowDownloadRoute.cli.rawValue, forKey: SRARowDownloadRouteSettings.defaultsKey)
        let viewModel = DatabaseBrowserViewModel(
            source: .ena, ncbiService: NCBIService(apiKey: nil, environment: [:]), enaService: ENAService(environment: [:]),
            sraDownloadSuiteName: suite.name)
        viewModel.routeContext = OperationRouteContext(projectURL: project, windowStateScopeID: UUID())
        let id = OperationCenter.shared.begin(
            title: "SRA row route", detail: "Starting...", operationType: .download, cliCommand: nil).rowID
        defer { OperationCenter.shared.clearItem(id: id) }
        XCTAssertNil(item(id)?.cliCommand, "the row begins before the sheet, so it records nothing yet")

        let runs = ["SRR9000001", "SRR9000002"]
        viewModel.startSRADownloadTask(
            records: runs.map { SearchResultRecord(id: $0, accession: $0, title: $0, source: .ena) },
            importConfig: sheet(), downloadCenterTaskID: id, totalCount: runs.count)

        // The command is set at once, one line for each run in run order.
        let expected = runs.map { Self.arguments(of: $0, project: project) }
        let lines = try XCTUnwrap(item(id)?.cliCommand).split(separator: "\n").map(String.init)
        XCTAssertEqual(try lines.map { try RecordedCLICommand.arguments(of: $0) }, expected)

        // The first child is launched with the arguments of the first line.
        let reached = await waitUntil(timeout: .seconds(60)) { Self.launchedLines(launches).count >= 1 }
        XCTAssertTrue(reached, "the route launched the CLI")
        XCTAssertEqual(Self.launchedLines(launches), [expected[0].joined(separator: " ")])

        OperationCenter.shared.cancel(id: id)
        let ended = await waitUntil(timeout: .seconds(30)) { item(id)?.state == .cancelled }
        XCTAssertTrue(ended, "the row ends as Cancelled, not Failed: \(String(describing: item(id)?.state))")
        XCTAssertEqual(Self.launchedLines(launches).count, 1, "the second run launched nothing after the cancel")
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("Imports").path)) ?? [], [],
            "no bundle is left")
        XCTAssertEqual(
            ((try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".tmp").path)) ?? [])
                .filter { $0.hasPrefix("sra-batch-") || $0.hasPrefix("fetch-sra-") }, [],
            "no staging folder is left")
    }

    // MARK: - Helpers

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private static func launchedLines(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The arguments the route passes for `run`, with the sheet of ``sheet()``.
    private static func arguments(of run: String, project: URL) -> [String] {
        [
            "fetch", "sra", "download", run, "--bundle", "--project", project.path, "--platform", "auto",
            "--pairing", "single", "--quality-binning", "none", "--compression", "fast", "--no-optimize-storage",
            "--format", "json",
        ]
    }

    private func sheet() -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: [], detectedPlatform: .illumina, confirmedPlatform: .illumina, pairingMode: .singleEnd,
            qualityBinning: .none, skipClumpify: true, deleteOriginals: false, postImportRecipe: nil,
            resolvedPlaceholders: [:], recipeName: nil, compressionLevel: .fast)
    }
}
