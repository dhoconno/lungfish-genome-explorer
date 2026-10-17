// DatabaseBrowserSRARowCancelReplayTests.swift - The Cancel of an SRA row on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3 (SWIFT 3, UX 4, panel decision G1), as DatabaseBrowserPathoplexusRowCancelReplayTests
// checks a Pathoplexus row. An SRA row of the browser's download runs `lungfish-cli fetch sra download
// --bundle` once for each run on the CLI route. The Operations panel's Cancel reaches the child through the
// callback the row installs (`transport.cancel()`), so ToolProcess sends SIGTERM, and SIGKILL after
// `CLIProcessLauncher.operationGrace`. The child must exit 125 inside the grace, take the SRA Toolkit's tree
// with it, and leave no bundle, staging folder or process behind. The row ends as Cancelled with no alert,
// and the second run of the batch launches no child.
//
// Two cases, one for each step of a run. The toolkit stand-in holds `prefetch` while the run downloads, and
// writes generated reads so the import that follows lasts well past the first event of the import stage. The
// CLI alone and through the bare transport is pinned by `FetchSRASIGTERMReplayTests`.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import AppKit
import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class DatabaseBrowserSRARowCancelReplayTests: XCTestCase {
    func testACancelWhileTheToolkitDownloadsEndsTheRowCancelledAndStopsTheToolkitTree() async throws {
        try await cancelledRow(toolkitWaits: true) { _, marker in
            FileManager.default.fileExists(atPath: marker.path)
        }
    }

    func testACancelOnTheFirstImportEventEndsTheRowCancelledAndLeavesNothing() async throws {
        try await cancelledRow(toolkitWaits: false) { item, _ in
            guard let item else { return false }
            return item.detail.contains("Importing") || item.logEntries.contains { $0.message.contains("Importing") }
        }
    }

    /// Runs a batch of two runs on the CLI route, cancels its row once `reached` holds, and checks how the
    /// child, the row and the project ended.
    private func cancelledRow(
        toolkitWaits: Bool, reached: (OperationCenter.Item?, URL) -> Bool
    ) async throws {
        // A batch with a project asks `AppDelegate.shared` whether the project is writable, which reads `NSApp`.
        _ = NSApplication.shared
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()),
            "No lungfish-cli beside the tests and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "sra-row-cancel")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("prefetch-started")
        let scripts = root.appendingPathComponent("toolkit", isDirectory: true)
        try SRAToolkitStandInScripts.write(
            into: scripts, fixtures: SRAToolkitStandInScripts.fixturesFolder(testFile: #filePath),
            waitingMarker: toolkitWaits ? marker : nil, bulkReadCount: 200_000)
        // NCBI and ENA are asked at an origin that answers nothing, so the run reaches no network and takes the toolkit.
        let saved = ProcessEnvironmentOverride(
            set: [
                NCBIServiceEndpoints.standInOriginVariable: "http://127.0.0.1:1",
                ENAServiceEndpoints.standInOriginVariable: "http://127.0.0.1:1",
                SRAToolkitStandInScripts.variable: scripts.path,
                "LUNGFISH_CLI_PATH": cli.path,
            ],
            unset: ["NCBI_API_KEY"])
        defer { saved.restore() }
        let suite = makeTestDefaultsSuite(prefix: "DatabaseBrowserSRARowCancelReplayTests")
        let viewModel = DatabaseBrowserViewModel(
            source: .ena, ncbiService: NCBIService(apiKey: nil), enaService: ENAService(), sraDownloadSuiteName: suite.name)
        viewModel.routeContext = OperationRouteContext(projectURL: project, windowStateScopeID: UUID())
        let id = OperationCenter.shared.begin(
            title: "SRA row cancel", detail: "Starting...", operationType: .download, cliCommand: nil).rowID
        defer { OperationCenter.shared.clearItem(id: id) }
        let item = { OperationCenter.shared.items.first { $0.id == id } }

        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        let runs = ["SRR9000001", "SRR9000002"]
        viewModel.startSRADownloadTask(
            records: runs.map { SearchResultRecord(id: $0, accession: $0, title: $0, source: .ena) },
            importConfig: DatabaseBrowserSRARowParityReplayTests.sheet(), downloadCenterTaskID: id, totalCount: runs.count)

        let atStage = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            reached(item(), marker)
        }
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
        guard atStage, let child = tree.first.flatMap(ChildExitWatch.init(pid:)) else {
            OperationCenter.shared.cancel(id: id)
            return XCTFail("The run never reached the step: \(String(describing: item()?.detail)), tree \(tree)")
        }
        let sent = ContinuousClock.now
        OperationCenter.shared.cancel(id: id)
        let ended = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait) { item()?.state == .cancelled }
        let elapsed = ContinuousClock.now - sent
        XCTAssertTrue(ended, "the row ends as Cancelled, not Failed: \(String(describing: item()?.state))")

        CLISIGTERMHarness.assertCancelledExit(
            status: child.exitCode(timeoutSeconds: 5), elapsed: elapsed,
            within: CLIProcessLauncher.operationGrace + DatabaseBrowserGenomeRowCancelReplayTests.margin)
        await CLISIGTERMHarness.assertNoProcessLeft(tree)
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, "Imports").filter { $0.hasSuffix(".lungfishfastq") }, [],
            "no bundle is left")
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, ".tmp").filter {
                $0.hasPrefix("fetch-sra-") || $0.hasPrefix("sra-batch-")
            }, [],
            "no staging folder is left, and the second run staged none")
        let later = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
        XCTAssertEqual(later, [], "the second run launched no child")
    }
}
