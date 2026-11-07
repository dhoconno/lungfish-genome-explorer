// OperationsRowResultsButtonTests.swift - The Results button of a finished BLAST row and of a finished Call Variants row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane OPSWORDS, row OPS-RESULTS-BUTTON (walk W-2). Both rows ended Completed with no path, so the Operations
// panel's Results button stayed grey after every such run. Each test finishes a row the way its runner finishes it, then
// reads the real button in the real panel and the result its action opens. No BLAST reaches NCBI: the BLAST run is the
// Debug CLI answering from the recorded-reply stand-in the held-search tests use.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport

@MainActor
final class OperationsRowResultsButtonTests: XCTestCase {
    private var folder: URL!
    private var rows: [UUID] = []
    private var panel: OperationsPanelController?

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "ops-results-button")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        panel?.close()
        panel = nil
        for row in rows { OperationCenter.shared.clearItem(id: row) }
        rows = []
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    // MARK: - The panel's button

    /// The Results button the Operations panel draws for the row `id`, or nil when the panel draws none.
    private func resultsButton(for id: UUID) -> NSButton? {
        _ = NSApplication.shared
        let controller = OperationsPanelController()
        panel = controller
        guard let view = controller.window?.contentViewController?.view else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let table = Self.table(in: view),
              let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "action" }) else { return nil }
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) else { continue }
            if let button = cell.subviews.compactMap({ $0 as? NSButton }).first(where: {
                $0.accessibilityIdentifier() == "operations-results-\(id)"
            }) {
                return button
            }
        }
        return nil
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.accessibilityIdentifier() == "operations-table" { return table }
        for subview in view.subviews {
            if let found = table(in: subview) { return found }
        }
        return nil
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    // MARK: - Call Variants

    /// The run adds its track to the bundle in place and imports no file, so the bundle is the result the row links to.
    /// The row stays off `bundleURLs`, which would hand the bundle to the download import hook, and the button opens the bundle.
    func testCompletedVariantCallRowResultsButtonOpensItsResult() throws {
        let bundle = folder.appendingPathComponent("Project.lungfish/Sample.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let id = OperationCenter.shared.begin(
            title: "Calling variants with LoFreq", detail: "Running", operationType: .variantCalling,
            targetBundleURL: bundle, cliCommand: "lungfish-cli variants call"
        ).rowID
        rows.append(id)
        let result = CLIVariantCallingResult(
            trackID: "var-1", trackName: "Sample 1 LoFreq", databasePath: nil, vcfPath: nil, tbiPath: nil, provenancePath: nil
        )

        XCTAssertTrue(InspectorViewController.completeVariantCallingRow(id, bundleURL: bundle, result: result))

        let finished = try XCTUnwrap(item(id))
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.detail, "Created variant track Sample 1 LoFreq")
        XCTAssertEqual(finished.bundleURLs, [], "the run imports no file, so the import hook is not handed the bundle")
        XCTAssertEqual(
            OperationResultNavigation.resultURL(for: finished), bundle.standardizedFileURL,
            "the row names no result its Results button can open"
        )
        let button = try XCTUnwrap(resultsButton(for: id), "the panel draws no Results button for the row")
        XCTAssertTrue(button.isEnabled, "the Results button of a finished Call Variants row is grey")
    }

    // MARK: - BLAST

    /// A BLAST row that collected its record links to the search's folder, where the record sits, since that folder is the
    /// result the viewer's own BLAST Results button reads. The run is the Debug CLI on the stand-in, as in the held-search tests.
    func testCompletedBlastRowResultsButtonOpensItsResult() async throws {
        let server = try BlastFaultStandIn.start(scripts: [
            BlastFaultScript(search: .held, thereAreHits: true, body: try Self.reply("sars-cov-2-one-read-send-a")),
            BlastFaultScript(search: .readyAtOnce, thereAreHits: true, body: try Self.reply("sars-cov-2-one-read-send-b")),
        ])
        defer { server.stop() }
        let cli = try wrappedCLI(server.baseURL)
        let clock = try searchClock(server.baseURL)
        let monitor = BlastInFlightMonitor(worker: .cli(cliURLOverride: cli), now: clock.now)
        let plan = try makePlan()
        let id = OperationCenter.shared.begin(
            title: "BLAST fixture", detail: "Running", operationType: .blastVerification, cliCommand: plan.cliCommand
        ).rowID
        rows.append(id)
        let drawer = BlastSubmitDrawer(loading: { _ in }, results: { _, _ in }, failure: { _ in }, waiting: { _ in })

        let task = ViewerViewController.launchBlastSubmit(
            plan, operationID: id, runner: CLIBlastSubmitRunner(cliURLOverride: cli), drawer: drawer, monitor: monitor
        ) { result in "\(result.verifiedCount)/\(result.readResults.count) verified" }
        await task.value

        let finished = try XCTUnwrap(item(id))
        XCTAssertEqual(finished.state, .completed, finished.errorMessage ?? "")
        let record = plan.request.outputURL.appendingPathComponent("blast-result.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the result is on disk")
        XCTAssertEqual(
            OperationResultNavigation.resultURL(for: finished), plan.request.outputURL.standardizedFileURL,
            "the row names no result its Results button can open"
        )
        let button = try XCTUnwrap(resultsButton(for: id), "the panel draws no Results button for the row")
        XCTAssertTrue(button.isEnabled, "the Results button of a finished BLAST row is grey")
    }

    // MARK: - The BLAST stand-in, as BlastHeldSearchEndToEndTests stages it

    private static func reply(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appendingPathComponent("Fixtures/blast-replies/\(name).json"))
    }

    private var stateFolder: URL {
        folder.appendingPathComponent("stand-in-state", isDirectory: true)
    }

    private func environment(_ origin: URL) -> [String: String] {
        [
            BlastServiceEndpoints.standInOriginVariable: origin.absoluteString,
            BlastStandInState.stateVariable: stateFolder.path,
            BlastStandInState.timeScaleVariable: BlastSubmitParity.fastClock,
        ]
    }

    /// The built CLI under the stand-in's variables, which both the viewer's run and the monitor's passes launch.
    private func wrappedCLI(_ origin: URL) throws -> URL {
        let real = try BlastSubmitParity.cli(for: Self.self)
        let exports = environment(origin).sorted { $0.key < $1.key }.map { "export \($0.key)='\($0.value)'" }.joined(separator: "\n")
        let url = folder.appendingPathComponent("lungfish-cli-on-the-stand-in")
        try "#!/bin/bash\n\(exports)\nexec '\(real.path)' \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func searchClock(_ origin: URL) throws -> BlastSearchClock {
        try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        return BlastSearchClock(environment: environment(origin), sharedFolder: stateFolder)
    }

    private func makePlan() throws -> BlastSubmitPlan {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return try BlastSubmitPlan.make(
            sequences: [(id: "NODE_1_length_500_cov_10.0", sequence: String(repeating: "ACGTT", count: 100))],
            label: "Severe acute respiratory syndrome coronavirus 2",
            projectURL: project,
            taxId: 2_697_049,
            acceptedTaxIds: [2_697_049]
        )
    }
}
