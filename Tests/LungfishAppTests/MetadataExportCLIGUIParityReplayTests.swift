// MetadataExportCLIGUIParityReplayTests.swift - The folder and project metadata CSV export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, ARCH ruling on the export shape 1.7, row B12, on lane Q30's harness. Each case runs on three
// sides that start as copies of one root that holds a folder and a project folder.
//
// - Side A is the in-process write both sheets made at d98291e8c, frozen in `frozenExport` since the lane deleted it
//   from the sheets. They serialized the samples they held, edits not saved included, and wrote with `String.write`.
//   Nothing recorded that write, so side A leaves no record.
// - Side C is `AppDelegate.runMetadataExport`, which writes the selection file beside the output, begins the row and
//   runs the built `lungfish-cli metadata export` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded, with the selection file copied to root C'.
//
// A against C compares what 1.7 names, which is the payload byte for byte, and the output digest, size and the
// `resolved` count of the record that only side C writes. The record itself (tool, kind, argv, workflow name, the one
// input) is a prediction row of the lane report (BIO 4, 6 and 7), pinned on side C by `assertPredictedRecord`. C
// against C' compares everything under the contract's masks. Nothing is declared, so the old writer goes in the lane
// with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14). Each case root lies five levels below the temporary folder, since the record's walk up from
// each input lists five folders and the temporary folder holds tens of thousands of entries
// (`SCR/lanes/12.31/12.31-cancel.md`).
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
private final class MetadataExportReports {
    var messages: [String] = []
}

@MainActor
final class MetadataExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case folderSheetWithAnEdit
        case projectSubsetWithSpecialCharacters

        /// The folder the sheet is for.
        var folderName: String { self == .folderSheetWithAnEdit ? "RunFolder" : "Project" }

        /// The samples the sheet passes, in the order it exports them.
        var samples: [FASTQSampleMetadata] {
            switch self {
            case .folderSheetWithAnEdit:
                // The second row's name and date were edited in the sheet and not saved, so no file holds them.
                var alpha = FASTQSampleMetadata(sampleName: "Alpha")
                alpha.sampleType = "stool"
                alpha.host = "human"
                alpha.customFields = ["Batch": "b1"]
                var edited = FASTQSampleMetadata(sampleName: "Edited")
                edited.collectionDate = "2026-01-02"
                edited.customFields = ["Cohort": "case"]
                return [alpha, edited]
            case .projectSubsetWithSpecialCharacters:
                // The project export holds three discovered samples and the user ticked the first and the third.
                var first = FASTQSampleMetadata(sampleName: "Run1/Alpha")
                first.notes = "has, comma"
                var second = FASTQSampleMetadata(sampleName: "Run1/Beta")
                second.notes = "not selected"
                var third = FASTQSampleMetadata(sampleName: "Run2/Alpha")
                third.notes = "say \"hi\"\nand two lines"
                third.host = " padded "
                return [first, third]
            }
        }
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let outputName = "samples.csv"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "metadata-export-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// The folder sheet's table with a name and a date edited and not saved. Both sides write the edited rows.
    func testFolderSheetWithAnEditMatches() async throws {
        let runs = try await assertParity(.folderSheetWithAnEdit)
        let csv = try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8)
        XCTAssertTrue(csv.contains("Edited"), csv)
        XCTAssertTrue(csv.contains("Batch") && csv.contains("Cohort"), "both custom columns are written: \(csv)")
    }

    /// The project export of a ticked subset, with a comma, a quote, a line break and padding in the values.
    func testProjectSubsetWithSpecialCharactersMatches() async throws {
        let runs = try await assertParity(.projectSubsetWithSpecialCharacters)
        let csv = try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8)
        XCTAssertFalse(csv.contains("Run1/Beta"), "the unticked sample is not written: \(csv)")
        XCTAssertTrue(csv.contains("\"has, comma\""), csv)
        XCTAssertTrue(csv.contains("\"say \"\"hi\"\"\nand two lines\""), csv)
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no message, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = try deepDirectory("cancel")
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")

        let reports = MetadataExportReports()
        let begun = try XCTUnwrap(AppDelegate.runMetadataExport(
            folderURL: root.appendingPathComponent(Case.folderSheetWithAnEdit.folderName, isDirectory: true),
            samples: Case.folderSheetWithAnEdit.samples, outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { reports.messages.append($0) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(reports.messages, [], "a cancel shows nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }
}

// MARK: - The sides and the comparison

extension MetadataExportCLIGUIParityReplayTests {
    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent(outputName)
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The root every side starts from, a folder and a project folder. The leaf checks that the folder exists and reads
    /// the selection file for its rows.
    static func makeFixture(_ root: URL) throws {
        for name in [Case.folderSheetWithAnEdit.folderName, Case.projectSubsetWithSpecialCharacters.folderName] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

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

    /// Side A. The sheets' writer before the leaf, frozen below.
    private func sideA(_ root: URL, _ parityCase: Case) throws -> RouteParitySideOutcome {
        do {
            try Self.frozenExport(samples: parityCase.samples, to: Self.outputURL(in: root))
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(Self.outputName).")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// The body of `FolderMetadataEditorSheet.exportCSV`'s panel completion and `MetadataExportSheet.performExport` as
    /// they held it at d98291e8c. Both serialized the samples they held and wrote with `String.write`, and neither
    /// recorded anything.
    private static func frozenExport(samples: [FASTQSampleMetadata], to outputURL: URL) throws {
        let csv = FASTQSampleMetadata.serializeMultiSampleCSV(samples)
        try csv.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Side C. The shared run, which writes the selection file, begins the row and runs the built CLI behind it on the
    /// shared runner. The selection folder is then copied to root C', so the rebased command reads it there.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let reports = MetadataExportReports()
        guard let begun = AppDelegate.runMetadataExport(
            folderURL: root.appendingPathComponent(parityCase.folderName, isDirectory: true),
            samples: parityCase.samples, outputURL: Self.outputURL(in: root),
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { reports.messages.append($0) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start: \(reports.messages)")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(reports.messages, [], "a completed export shows nothing")
            try RegionExtractionWithoutBundleParityReplayTests.copyStage(
                root.appendingPathComponent(ViewerExportSelection.inputsFolderName, isDirectory: true), from: root
            )
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }

    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on the compared facts, and the
    /// predicted record holds.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: try deepDirectory(parityCase.rawValue),
            fixture: Self.makeFixture,
            sideA: { root in try self.sideA(root, parityCase) },
            sideC: { root in try await self.sideC(root, parityCase) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "side \(side) names no other side's root")
        }
        XCTAssertEqual(found[.cAgainstCPrime]?.map(\.description) ?? [], [], "C against C' declares nothing")
        try assertAEqualsC(runs, parityCase)
        try assertPredictedRecord(runs, parityCase)
        return runs
    }

    /// A against C on the facts of 1.7. No file but the record and the selection file differs, the payload is the same
    /// bytes, and the record's digest, size and count describe it.
    private func assertAEqualsC(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(sidecarName) && !$0.id.contains(ViewerExportSelection.inputsFolderName)
        }
        XCTAssertEqual(others.map(\.description), [], "only the record and the selection file may differ between A and C")

        let payloadA = try Data(contentsOf: Self.outputURL(in: runs.a.root))
        XCTAssertEqual(payloadA, try Data(contentsOf: Self.outputURL(in: runs.c.root)), "the payload byte for byte")
        let c = try Self.envelope(in: runs.c.root)
        let outputC = try XCTUnwrap(c.output)
        XCTAssertEqual(outputC.checksumSHA256, SHA256.hash(data: payloadA).map { String(format: "%02x", $0) }.joined(), "the output digest")
        XCTAssertEqual(outputC.fileSize, UInt64(payloadA.count), "the output size")
        XCTAssertEqual(Set(c.options.resolvedDefaults.keys), ["sampleCount"])
        XCTAssertEqual(c.options.resolvedDefaults["sampleCount"], .integer(parityCase.samples.count))
    }

    /// The prediction rows of the lane report (BIO 4, 6 and 7). Side A recorded nothing. Side C's record names the
    /// leaf as the tool, the row's command as its argv, the workflow `lungfish metadata export`, and the one selection
    /// file it read as its input, with its digest.
    private func assertPredictedRecord(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let sidecarA = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarA.path), "the in-process write recorded nothing")

        let c = try Self.envelope(in: runs.c.root)
        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(Array(rowArguments.prefix(2)), FolderMetadataExport.commandPath)
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, FolderMetadataExport.workflowName)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["folder", "outputPath", "selection"])
        XCTAssertTrue(c.options.defaults.isEmpty)

        let inputsC = Self.inputs(of: c, under: runs.c.root)
        XCTAssertEqual(inputsC.count, 1, "\(inputsC)")
        let selectionPath = try XCTUnwrap(inputsC.keys.first)
        XCTAssertTrue(selectionPath.hasPrefix("/" + ViewerExportSelection.inputsFolderName + "/"), selectionPath)
        XCTAssertTrue(selectionPath.hasSuffix("/" + ViewerExportSelection.fileName), selectionPath)
        let selectionBytes = try Data(contentsOf: URL(fileURLWithPath: runs.c.root.path + selectionPath))
        let digest = SHA256.hash(data: selectionBytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(inputsC[selectionPath], digest, "the record names the selection file with its digest")
        XCTAssertEqual(FolderMetadataExport.samples(in: try ViewerExportSelection.read(from: URL(fileURLWithPath: runs.c.root.path + selectionPath))), parityCase.samples)
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}
