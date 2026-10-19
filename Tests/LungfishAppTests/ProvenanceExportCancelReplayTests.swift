// ProvenanceExportCancelReplayTests.swift - A cancelled provenance report export leaves its destination as it was
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, manager decision MGR-12.38-B9 item 5, row B9, on lane Q30's harness and the cancel recipe of
// `MetadataExportCLIGUIParityReplayTests`. `provenance export` builds the whole report in a hidden sibling of the
// output, reaches `ViewerExportLeaf.checkpointAfterStaging` (which holds on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE` in a
// debug build) and publishes only after it, so a cancel before the publish leaves the destination as it was.
//
// - A new folder. The row's Cancel and the launcher's SIGTERM each leave no output folder and no staging folder.
// - An existing folder, which holds a file the report does not write and a stale file it does. A cancel leaves the
//   folder's listing and digests as they were, and a finished run keeps the unrelated file and replaces the stale one.
//
// Each case root lies five levels below the temporary folder, since the record's walk up from each input lists five
// folders and the temporary folder holds tens of thousands of entries (`SCR/lanes/12.31/12.31-cancel.md`).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ProvenanceExportCancelReplayTests: XCTestCase {
    typealias Parity = ProvenanceExportCLIGUIParityReplayTests

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let cancelledWords = "The export was cancelled. No file was written."
    /// Both cases export the pinned record as JSON, whose primary artifact is `provenance.json`.
    static let parityCase = Parity.Case(format: .json, override: false)

    private var scratch: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "provenance-export-cancel")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// A new folder. The row's Cancel stops the leaf at its checkpoint, after it staged the whole report, and the row's
    /// command cancelled on the launcher every CLI route uses exits 125 inside the grace. Neither leaves the output
    /// folder or a staging folder beside it.
    func testACancelledExportToANewFolderLeavesNoFolderAndNoStagingFolder() async throws {
        let root = try deepDirectory("new-folder")
        try Parity.makeFixture(root, override: false)
        let parent = Parity.outputURL(in: root, Self.parityCase).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let arguments = try await cancelThroughTheRow(root)
        XCTAssertEqual(try Self.listing(of: parent), [], "the row's Cancel leaves no output folder and no staging folder")
        try await cancelThroughTheLauncher(arguments)
        XCTAssertEqual(try Self.listing(of: parent), [], "the launcher's SIGTERM leaves no output folder and no staging folder")
    }

    /// An existing folder keeps today's merge. A cancel before the checkpoint returns leaves the folder's listing and
    /// digests as they were, and a finished run keeps the file it does not write and replaces the stale one it does.
    func testACancelledExportIntoAnExistingFolderLeavesItAsItWasAndAFinishedOneKeepsItsFiles() async throws {
        let root = try deepDirectory("existing-folder")
        try Parity.makeFixture(root, override: false)
        let output = Parity.outputURL(in: root, Self.parityCase)
        let parent = output.deletingLastPathComponent()
        let primary = ProvenanceReportExport.primaryArtifactFileName(for: Self.parityCase.format)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: output.appendingPathComponent("unrelated.txt"))
        try Data("stale".utf8).write(to: output.appendingPathComponent(primary))
        let before = try Self.snapshot(of: output)

        let arguments = try await cancelThroughTheRow(root)
        XCTAssertEqual(try Self.snapshot(of: output), before, "the row's Cancel leaves the folder's listing and digests as they were")
        XCTAssertEqual(try Self.listing(of: parent), [output.lastPathComponent], "no staging folder is left beside the output")
        try await cancelThroughTheLauncher(arguments)
        XCTAssertEqual(try Self.snapshot(of: output), before, "the launcher's SIGTERM leaves the folder as it was")
        XCTAssertEqual(try Self.listing(of: parent), [output.lastPathComponent], "no staging folder is left beside the output")

        let finished = await RouteParityHarness.runCLI(cli, arguments: arguments, timeout: .seconds(60))
        XCTAssertEqual(finished.end, .completed, finished.detail)
        let after = try Self.snapshot(of: output)
        XCTAssertEqual(after["unrelated.txt"], before["unrelated.txt"], "a finished run keeps the unrelated file")
        XCTAssertNotNil(after[primary], "a finished run writes \(primary)")
        XCTAssertNotEqual(after[primary], before[primary], "a finished run replaces the stale \(primary)")
        XCTAssertNotNil(after["provenance/\(ProvenanceRecorder.provenanceFilename)"], "a finished run publishes the export record")
        XCTAssertEqual(try Self.listing(of: parent), [output.lastPathComponent], "a finished run leaves no staging folder")
    }
}

// MARK: - The two ways to cancel

extension ProvenanceExportCancelReplayTests {
    /// Begins the row with the leaf held at its checkpoint, cancels the row and returns the arguments of the command it
    /// recorded, which the launcher half runs.
    private func cancelThroughTheRow(_ root: URL) async throws -> [String] {
        let parityCase = Self.parityCase
        let hold = root.appendingPathComponent("held-by-the-row")
        let begun = try XCTUnwrap(AppDelegate.beginProvenanceExportOperation(
            invocation: ProvenanceReportExport.invocation(
                inputURL: Parity.inputURL(in: root), format: parityCase.format,
                outputDirectory: Parity.outputURL(in: root, parityCase), allowUnpinned: false
            ),
            format: parityCase.format,
            runner: CLIViewerExportRunner(cliURLOverride: cli),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { _ in })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its checkpoint with the report staged")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        return try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
    }

    /// Runs the row's command, posts the SIGTERM the app's Cancel posts once the leaf holds at its checkpoint, and
    /// checks that it exits 125 inside the grace, leaves no process and says nothing was written.
    private func cancelThroughTheLauncher(_ arguments: [String]) async throws {
        let hold = scratch.appendingPathComponent("held-by-the-launcher-\(UUID().uuidString)")
        let run = await RouteParityHarness.runCLI(
            cli, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains(Self.cancelledWords), run.stdout)
    }
}

// MARK: - Helpers

extension ProvenanceExportCancelReplayTests {
    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A case folder five levels below the temporary folder.
    private func deepDirectory(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent("l2/l3/l4", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The names in `folder`, hidden ones included.
    static func listing(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Every entry below `folder`, hidden ones included, by relative path, with a file's SHA-256 or "folder".
    static func snapshot(of folder: URL) throws -> [String: String] {
        var entries: [String: String] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            entries[relative] = isDirectory.boolValue
                ? "folder"
                : SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return entries
    }
}
