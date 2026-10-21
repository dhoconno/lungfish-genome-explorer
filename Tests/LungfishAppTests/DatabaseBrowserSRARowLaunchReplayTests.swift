// DatabaseBrowserSRARowLaunchReplayTests.swift - The CLI route of an SRA row launches one child for each run and records its command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3, panel decision C4 and UX 7. With a project in the
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
final class DatabaseBrowserSRARowLaunchReplayTests: XCTestCase {
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

        let suite = makeTestDefaultsSuite(prefix: "DatabaseBrowserSRARowLaunchReplayTests")
        let viewModel = DatabaseBrowserViewModel(
            source: .ena, ncbiService: NCBIService(apiKey: nil, environment: [:]), enaService: ENAService(environment: [:]),
            defaultsSuiteName: suite.name)
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
        let reached = await waitUntil(budget: .lookup) { Self.launchedLines(launches).count >= 1 }
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

    func testBrowserConfirmationLaunchesCLIAndCancelStillStopsIt() async throws {
        _ = NSApplication.shared
        let root = try TestTempDirectory.make(prefix: "sra-browser-confirm")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: project, name: "Project")
        let cli = root.appendingPathComponent("lungfish-cli")
        let launches = root.appendingPathComponent("launches")
        try "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/launches\"\nexec sleep 600\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let priorCLI = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        defer {
            if let priorCLI { setenv("LUNGFISH_CLI_PATH", priorCLI, 1) }
            else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        let delegate = makeAppDelegateWithTemporaryState()
        let oldDelegate = NSApp.delegate
        NSApp.delegate = delegate
        defer { NSApp.delegate = oldDelegate }
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        let sidebar = controller.mainSplitViewController.sidebarController!
        sidebar.openProject(at: project)
        sidebar.detachFilesystemWatcherForTesting()
        let parent = try XCTUnwrap(controller.window)
        defer { sidebar.closeProject(); controller.close() }
        let browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        parent.beginSheet(browser) { _ in }
        let client = MockHTTPClient(responses: [Data("[]".utf8)])
        let suite = makeTestDefaultsSuite(prefix: "sra-browser-confirm")
        let model = DatabaseBrowserViewModel(
            source: .ena, ncbiService: NCBIService(httpClient: client),
            enaService: ENAService(httpClient: client), defaultsSuiteName: suite.name)
        model.routeContext = OperationRouteContext(
            projectURL: project, windowStateScopeID: controller.projectSession.windowStateScope.id)
        model.onDownloadStarted = { parent.endSheet(browser) }
        model.selectedRecord = SearchResultRecord(id: "SRR9000001", accession: "SRR9000001", title: "Test", source: .ena)
        model.performBatchDownload()
        let id = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "SRR9000001" }?.id)
        addTeardownBlock { @MainActor in
            OperationCenter.shared.cancel(id: id)
            await waitUntil(timeout: .seconds(30)) {
                OperationCenter.shared.items.first { $0.id == id }?.state.isActive != true
            }
            OperationCenter.shared.clearItem(id: id)
        }
        await waitUntil { parent.attachedSheet?.contentViewController is FASTQImportConfigSheet }
        let settings = try XCTUnwrap(parent.attachedSheet)
        XCTAssertTrue(settings.contentViewController is FASTQImportConfigSheet)
        XCTAssertNil(item(id)?.cliCommand)
        func findImport(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Import" { return button }
            return view.subviews.compactMap { findImport(in: $0) }.first
        }
        let submit = try XCTUnwrap(findImport(in: try XCTUnwrap(settings.contentView)))
        XCTAssertTrue(submit.isEnabled)
        submit.performClick(nil)
        await waitUntil(timeout: .seconds(30)) { !Self.launchedLines(launches).isEmpty }
        let arguments = try RecordedCLICommand.arguments(of: XCTUnwrap(item(id)?.cliCommand))
        XCTAssertEqual(Array(arguments.prefix(5)), ["fetch", "sra", "download", "SRR9000001", "--bundle"])
        XCTAssertEqual(Self.launchedLines(launches), [arguments.joined(separator: " ")])
        XCTAssertTrue(arguments.contains(project.path))
        XCTAssertTrue(item(id)?.isCancellable == true)
        OperationCenter.shared.cancel(id: id)
        await waitUntil(timeout: .seconds(30)) { item(id)?.state == .cancelled }
        XCTAssertEqual(item(id)?.state, .cancelled)
        XCTAssertEqual(Self.launchedLines(launches).count, 1)
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
