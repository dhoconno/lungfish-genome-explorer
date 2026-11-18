// RNASeqPseudobulkDialogTests.swift - The pseudobulk row of the Workflow Operations dialog (RS-DIALOG-M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.4, lane RS-DIALOG-M2, brief items 2 and 3. The row runs the same `lungfish-cli rnaseq pseudobulk` a script runs.
//
// `RNASeqPseudobulkDialogTests` runs in every tier (argv round trip, `begin`, a locked result). `RNASeqPseudobulkDialogParityReplayTests`
// runs the built `lungfish-cli` with no external tool, so it runs serially in the integration tier. It holds the parity replay on the
// STARsolo cut of pbmc_1k_v3 with `Tests/Fixtures/rnaseq/pseudobulk-pbmc_1k_v3/labels-starsolo.tsv`, the note of a group under 10 cells
// as the CLI prints it, and a cancel that leaves no result and no stage.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow

@MainActor
final class RNASeqPseudobulkDialogTests: XCTestCase {
    private let single = URL(fileURLWithPath: "/tmp/pb-project/Analyses/cells.lungfishrnaseq", isDirectory: true)
    private var made: RNASeqPseudobulkRunRequest {
        RNASeqPseudobulkRunRequest(
            resultURL: single, labelsURL: URL(fileURLWithPath: "/tmp/pb-project/labels.tsv"),
            outputURL: URL(fileURLWithPath: "/tmp/pb-project/Analyses/pb1.lungfishrnaseq", isDirectory: true))
    }

    func testArgvParsesThroughTheRealPseudobulkSubcommand() throws {
        XCTAssertEqual(Array(made.argv.prefix(2)), ["rnaseq", "pseudobulk"])
        let parsed = try RNASeqPseudobulkSubcommand.parse(Array(made.argv.dropFirst(2)))
        XCTAssertEqual(parsed.resultPath, single.path)
        XCTAssertEqual(parsed.labelsPath, made.labelsURL.path)
        XCTAssertEqual(parsed.outputPath, made.outputURL.path)
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
    }

    func testBeginNamesTheOperationTypeAndTheCommandThatRuns() throws {
        let center = OperationCenter()
        var launched: UUID?
        let result = RNASeqLeafRoute.begin(made.run, operations: center) { launched = $0 }
        guard case .started(let id) = result else { return XCTFail("begin refused the run") }
        XCTAssertEqual(launched, id)
        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.operationType, .rnaSeqPseudobulk)
        XCTAssertEqual(item.cliCommand, made.run.cliCommand)
        let recorded = try RecordedCLICommand.parse(item.cliCommand, as: RNASeqPseudobulkSubcommand.self)
        XCTAssertEqual(recorded.resultPath, single.path)
        XCTAssertEqual(recorded.labelsPath, made.labelsURL.path)
        XCTAssertEqual(recorded.outputPath, made.outputURL.path)
    }

    func testALockedResultRefusesTheRowAndLaunchesNothing() {
        let center = OperationCenter()
        _ = center.begin(
            title: "Holder", detail: "", operationType: .rnaSeqQuantification, targetBundleURL: single, cliCommand: nil,
            routeContext: nil)
        var launched = false
        let result = RNASeqLeafRoute.begin(made.run, operations: center) { _ in launched = true }
        guard case .refused = result else { return XCTFail("a result under another row's lock was accepted") }
        XCTAssertFalse(launched)
    }
}

// MARK: - The built CLI

@MainActor
final class RNASeqPseudobulkDialogParityReplayTests: XCTestCase {
    private static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    private static let labels = RNASeqFixtures.root.appendingPathComponent("pseudobulk-pbmc_1k_v3/labels-starsolo.tsv")
    private var scratch: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "rnaseq-pseudobulk-dialog")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// The STARsolo cut of pbmc_1k_v3 as a single-cell result under `root/Analyses`, written by the one writer.
    private func writeSingleCellResult(in root: URL) throws {
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let folder = try SingleCellFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent("starsolo-pbmc_1k_v3", isDirectory: true))
        let samples = [RNASeqSampleRecord(id: folder.sample, animal: "A1", species: "Homo sapiens", runs: [folder.sample])]
        let request = try SingleCellFolderReader.request([folder], name: "cells", samples: samples, genomes: [])
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
            .write(request, to: analyses.appendingPathComponent("cells.lungfishrnaseq", isDirectory: true), envelope: envelope)
    }

    private func request(in root: URL) -> RNASeqPseudobulkRunRequest {
        RNASeqPseudobulkRunRequest(
            resultURL: root.appendingPathComponent("Analyses/cells.lungfishrnaseq", isDirectory: true), labelsURL: Self.labels,
            outputURL: root.appendingPathComponent("Analyses/pb1.lungfishrnaseq", isDirectory: true))
    }

    private func end(of outcome: CLIViewerExportRunner.Outcome) -> RouteParityEnd {
        switch outcome {
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .failed: return .failed
        }
    }

    // MARK: parity replay

    func testTheRowsRunEqualsTheRunOfAScriptAndTheCommandItShowsReplaysToTheSame() async throws {
        // The new result's manifest holds the date the command ran, which the Masks row of `docs/contracts/CLI-EQUIVALENCE.md`
        // masks, and the quant case's mask of that one key serves here.
        var masks = OutputEquivalence.MaskPolicy.standard
        masks.payloads.append(OutputEquivalence.Masks.quantResultCreatedAt)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, masks: masks, replayTimeout: .seconds(120))
        let caseRoot = scratch.appendingPathComponent("cases/of/the/rnaseq-pseudobulk-dialog", isDirectory: true)
        let result = try await harness.assertParity(
            "starsoloCutByLabels", declared: [], in: caseRoot,
            fixture: { root in try self.writeSingleCellResult(in: root) },
            sideA: { root in
                let run = await RouteParityHarness.runCLI(
                    self.cli, arguments: self.request(in: root).argv, timeout: .seconds(120), environment: [:])
                return RouteParitySideOutcome(end: run.end, detail: run.detail)
            },
            sideC: { root in
                guard let launched = RNASeqLeafRoute.launch(
                    self.request(in: root).run, runner: CLIViewerExportRunner(cliURLOverride: self.cli))
                else { return RouteParitySideOutcome(end: .failed, detail: "begin refused the run") }
                let outcome = await launched.task.value
                guard let item = OperationCenter.shared.items.first(where: { $0.id == launched.operationID }) else {
                    return RouteParitySideOutcome(end: .failed, detail: "the row is gone")
                }
                XCTAssertEqual(item.operationType, .rnaSeqPseudobulk)
                return RouteParitySideOutcome(
                    end: self.end(of: outcome), detail: item.errorMessage ?? item.detail, recordedCommand: item.cliCommand)
            }
        )
        let runs = result.runs
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let counts = try runs.all.map {
            try Data(contentsOf: $0.root.appendingPathComponent("Analyses/pb1.lungfishrnaseq/counts/genes.counts.tsv"))
        }
        XCTAssertFalse(counts[0].isEmpty)
        XCTAssertEqual(counts[0], counts[1], "the table of the script and of the row")
        XCTAssertEqual(counts[1], counts[2], "the table of the row and of its replay")
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        XCTAssertTrue(command.hasPrefix("lungfish-cli rnaseq pseudobulk "), command)
        XCTAssertEqual(runs.cPrime.replayedArguments.count, 1, "the row records one command")
    }

    // MARK: the note of a group under 10 cells

    func testTheNoteOfAGroupUnderTenCellsShowsOnTheRowAsTheCLIPrintsIt() async throws {
        let root = scratch.appendingPathComponent("note", isDirectory: true)
        try writeSingleCellResult(in: root)
        let launched = try XCTUnwrap(RNASeqLeafRoute.launch(
            request(in: root).run, runner: CLIViewerExportRunner(cliURLOverride: cli)))
        let outcome = await launched.task.value
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == launched.operationID })
        guard case .completed = outcome else { return XCTFail("the run ended \(outcome), \(item.errorMessage ?? "")") }
        let note = "Group starsolo-pbmc_1k_v3 nine holds 9 cells, under 10, and is left out."
        let warnings = item.logEntries.filter { $0.level == .warning }.map(\.message)
        XCTAssertTrue(warnings.contains(note), "the row's warnings are \(warnings)")
    }

    // MARK: cancel

    func testACancelLeavesNoResultAndNoStage() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try writeSingleCellResult(in: root)
        let hold = root.appendingPathComponent("held")
        let made = request(in: root)
        let launched = try XCTUnwrap(RNASeqLeafRoute.launch(
            made.run, runner: CLIViewerExportRunner(cliURLOverride: cli), environmentAdditions: [Self.holdFileVariable: hold.path]))
        let held = await waitUntil(timeout: WaitBudget.lookup.duration) { FileManager.default.fileExists(atPath: hold.path) }
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: launched.operationID)
        let outcome = await launched.task.value
        let item = OperationCenter.shared.items.first { $0.id == launched.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertNil(item?.errorMessage, "a cancel is not an error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.outputURL.path), "a cancel leaves no result")
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true).path
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: analyses).sorted(), ["cells.lungfishrnaseq"],
            "a cancel leaves no stage beside the single-cell result")
    }
}
