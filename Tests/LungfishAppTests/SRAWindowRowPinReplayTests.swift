// SRAWindowRowPinReplayTests.swift - What the SRA row of the browser leaves behind today, side A of M3
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3, ruling A45-M3 section 1 ("Pins first, passing at the base"). The SRA row still
// downloads and imports in the app process (`startENADownloadTask`), so these pins run the window's own
// task on the project of a temporary folder and fix what it leaves, before M3 moves the row onto `fetch
// sra download --bundle`. They pass at the base.
//
// - A run served by the SRA Toolkit imports through the built `lungfish-cli import fastq` into
//   `<project>/Imports/`, the reads keep their payload, the metadata sidecar names the download source and
//   NCBI's run info, the bundle carries the window's provenance record with the toolkit steps, and the
//   batch folder under `<project>/.tmp/` is gone. This is side A of the parity M3 adds.
// - A cancel while the toolkit downloads, and a cancel while the import child runs, end the row as
//   Cancelled, leave no bundle in `Imports/` and no `sra-batch-` folder in `.tmp/`. The window reports a
//   cancel through the row, never through an alert (UX 4). A cancel while ENA's lookup waits is pinned by
//   `SRAWindowDownloadCancelTests`.
//
// The ENA mirror run is not pinned here, because `startENADownloadTask` fetches the files with
// `streamingDownload` from the host the portal names. M3's parity serves that host from the loopback
// stand-in (see the lane report's Handoff). These tests launch the built `lungfish-cli` or a stand-in script,
// so the class name ends in ReplayTests, which sends it to the integration tier.

import AppKit
import Foundation
import os
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class SRAWindowRowPinReplayTests: XCTestCase {
    private func makeProject() throws -> (root: URL, project: URL) {
        let root = try TestTempDirectory.make(prefix: "sra-window-row-pin")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, project)
    }

    /// Points the window's CLI lookup at `binary` until the returned closure runs.
    private func useCLI(_ binary: URL) -> () -> Void {
        let prior = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", binary.path, 1)
        return {
            if let prior { setenv("LUNGFISH_CLI_PATH", prior, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
    }

    private func sheet() -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: [], detectedPlatform: .illumina, confirmedPlatform: .illumina, pairingMode: .singleEnd,
            qualityBinning: .none, skipClumpify: true, deleteOriginals: false, postImportRecipe: nil,
            resolvedPlaceholders: [:], recipeName: nil, compressionLevel: .fast)
    }

    private func startWindowRun(
        _ accession: String, service: SRAService, archives: SRAScriptedArchives, project: URL
    ) -> UUID {
        // A batch with a project asks `AppDelegate.shared` whether the project is writable, which reads `NSApp`.
        _ = NSApplication.shared
        let suite = makeTestDefaultsSuite(prefix: "SRAWindowRowPinReplayTests")
        let viewModel = DatabaseBrowserViewModel(
            source: .ena,
            ncbiService: NCBIService(httpClient: archives, environment: [:]),
            enaService: ENAService(httpClient: archives),
            sraDownloadSuiteName: suite.name)
        viewModel.routeContext = OperationRouteContext(projectURL: project, windowStateScopeID: UUID())
        let id = OperationCenter.shared.begin(
            title: "SRA window row pin", detail: "Starting...", operationType: .download, cliCommand: nil).rowID
        SRAWindowDownloadSeams.$sraService.withValue(service) {
            viewModel.startENADownloadTask(
                records: [SearchResultRecord(id: accession, accession: accession, title: accession, source: .ena)],
                importConfig: sheet(), downloadCenterTaskID: id, totalCount: 1)
        }
        return id
    }

    private func state(of id: UUID) -> OperationCenter.Item.State? {
        OperationCenter.shared.items.first { $0.id == id }?.state
    }

    private func importedBundles(in project: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("Imports").path)) ?? []
        return names.filter { $0.hasSuffix(".lungfishfastq") }.sorted()
    }

    private func batchFolders(in project: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".tmp").path)) ?? []
        return names.filter { $0.hasPrefix("sra-batch-") }.sorted()
    }

    private func toolkitServiceThatWaits(_ started: Flag, archives: SRAScriptedArchives) -> SRAService {
        let prefetch = URL(fileURLWithPath: "/scripted/sra-tools/bin/prefetch")
        let waiting = SRAToolkitRunner(prefetch: prefetch, fasterqDump: URL(fileURLWithPath: "/scripted/sra-tools/bin/fasterq-dump")) { _, _ in
            started.set()
            try await Task.sleep(for: .seconds(600))
            return SRAToolkitRunner.Result(exitCode: 0)
        }
        return SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives, toolkitRunner: waiting)
    }

    // MARK: - A finished run

    func testAToolkitRunImportsABundleWithItsReadsSidecarAndRecord() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let restore = useCLI(cli)
        defer { restore() }
        let (_, project) = try makeProject()
        let run = SRAToolkitRecordedRunner.singleEndRun
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        archives.listOnNCBI(run, layout: "SINGLE")
        let recorded = SRAToolkitRecordedRunner(testFile: #filePath)
        let service = SRAService(
            ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives, toolkitRunner: recorded.runner)

        let id = startWindowRun(run, service: service, archives: archives, project: project)
        defer { OperationCenter.shared.clearItem(id: id) }
        let finished = await waitUntil(timeout: .seconds(120)) { state(of: id) != .running }
        XCTAssertTrue(finished, "the row ends")
        XCTAssertEqual(state(of: id), .completed, "\(OperationCenter.shared.items.first { $0.id == id }?.logEntries.map(\.message) ?? [])")

        let bundles = importedBundles(in: project)
        XCTAssertEqual(bundles, ["\(run).lungfishfastq"])
        let bundle = project.appendingPathComponent("Imports/\(run).lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        XCTAssertEqual(try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 100).headers.count, 53, "the payload holds the run's 53 reads")

        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.downloadSource, SRAFASTQDownloadSource.sraToolkit.rawValue)
        XCTAssertEqual(metadata.sraRunInfo?.accession, run, "NCBI's run info is kept when ENA gave no record")
        XCTAssertNil(metadata.enaReadRecord, "ENA was down, so there is no ENA record")
        XCTAssertNotNil(metadata.downloadDate)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle), "the window writes a record into the bundle")
        let toolNames = envelope.steps.map(\.toolName)
        XCTAssertEqual(envelope.workflowName, "gui-sra-fastq-import")
        XCTAssertEqual(envelope.status, .completed)
        // The toolkit's two steps come first, then the steps the CLI's own record held, among them its import.
        XCTAssertEqual(Array(toolNames.prefix(2)), ["prefetch", "fasterq-dump"], "\(toolNames)")
        XCTAssertTrue(toolNames.contains("lungfish import fastq"), "\(toolNames)")

        let leftover = await waitUntil(timeout: .seconds(30)) { batchFolders(in: project).isEmpty }
        XCTAssertTrue(leftover, "the batch folder under .tmp is removed: \(batchFolders(in: project))")
    }

    // MARK: - A cancel in each step

    func testACancelWhileTheToolkitDownloadsEndsCancelledAndLeavesNothing() async throws {
        let (_, project) = try makeProject()
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        let started = Flag()
        let service = toolkitServiceThatWaits(started, archives: archives)

        let id = startWindowRun("SRR9000001", service: service, archives: archives, project: project)
        defer { OperationCenter.shared.clearItem(id: id) }
        let reached = await waitUntil(timeout: .seconds(30)) { started.isSet }
        XCTAssertTrue(reached, "the download reached the toolkit")
        XCTAssertFalse(batchFolders(in: project).isEmpty, "the run stages in a batch folder of the project")

        OperationCenter.shared.cancel(id: id)
        let ended = await waitUntil(timeout: .seconds(30)) { state(of: id) == .cancelled }
        XCTAssertTrue(ended, "the row ends as Cancelled, not Failed: \(String(describing: state(of: id)))")
        let cleaned = await waitUntil(timeout: .seconds(30)) { batchFolders(in: project).isEmpty }
        XCTAssertTrue(cleaned, "no sra-batch folder is left: \(batchFolders(in: project))")
        XCTAssertEqual(importedBundles(in: project), [], "no bundle is left")
    }

    func testACancelWhileTheImportChildRunsEndsCancelledAndLeavesNothing() async throws {
        let (root, project) = try makeProject()
        let tools = root.appendingPathComponent("stand-in", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let fakeCLI = tools.appendingPathComponent("lungfish-cli")
        // A stand-in that notes it started, then waits. `exec` makes the SIGTERM of the cancel reach the sleep.
        try "#!/bin/sh\ntouch \"$(dirname \"$0\")/started\"\nexec sleep 600\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let restore = useCLI(fakeCLI)
        defer { restore() }

        let run = SRAToolkitRecordedRunner.singleEndRun
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        let recorded = SRAToolkitRecordedRunner(testFile: #filePath)
        let service = SRAService(
            ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives, toolkitRunner: recorded.runner)

        let id = startWindowRun(run, service: service, archives: archives, project: project)
        defer { OperationCenter.shared.clearItem(id: id) }
        let reached = await waitUntil(timeout: .seconds(60)) { FileManager.default.fileExists(atPath: tools.appendingPathComponent("started").path) }
        XCTAssertTrue(reached, "the download finished and the import child started")

        OperationCenter.shared.cancel(id: id)
        let ended = await waitUntil(timeout: .seconds(30)) { state(of: id) == .cancelled }
        XCTAssertTrue(ended, "the row ends as Cancelled, not Failed: \(String(describing: state(of: id)))")
        let cleaned = await waitUntil(timeout: .seconds(30)) { batchFolders(in: project).isEmpty }
        XCTAssertTrue(cleaned, "no sra-batch folder is left: \(batchFolders(in: project))")
        XCTAssertEqual(importedBundles(in: project), [], "no bundle is left")
    }
}

/// A flag one task sets and another reads.
private final class Flag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
