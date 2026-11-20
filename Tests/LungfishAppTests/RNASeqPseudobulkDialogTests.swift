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

    // MARK: Import Embedding (CM-IMPORT-APP)
    //
    // The same three cases for the import route, then a refusal case for each control that unlocks one, and the row that must read
    // Failed when the new result does not load after the leaf exited 0.

    private var folder: URL!
    private let given = URL(fileURLWithPath: "/tmp/pb-project/given", isDirectory: true)

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "rnaseq-import-dialog")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    private var imported: RNASeqCellMapImportRunRequest {
        RNASeqCellMapImportRunRequest(
            resultURL: single,
            coordinateURLs: [given.appendingPathComponent("projection.csv"), given.appendingPathComponent("lge-cell-map.tsv")],
            clusterURLs: [given.appendingPathComponent("clusters.csv")], labelColumns: ["clusters", "celltype"],
            barcodeSuffix: .drop, skipBarcodesNotHeld: true, otherCounts: true, tool: "Seurat", toolVersion: "5.5.1",
            outputURL: URL(fileURLWithPath: "/tmp/pb-project/Analyses/map1.lungfishrnaseq", isDirectory: true))
    }

    /// A stand-in `lungfish-cli` that exits 0 after a `complete` event naming `output`, as a leaf that wrote its result does.
    private func standInCLI(completing output: URL) throws -> URL {
        let url = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString).sh")
        let body = "printf '%s\\n' '{\"event\":\"complete\",\"outputs\":[\"\(output.path)\"],\"progress\":1,\"schemaVersion\":2}'\nexit 0"
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testTheImportArgvParsesThroughTheRealImportSubcommandAndIsTheCommandItRecords() throws {
        let made = imported
        XCTAssertEqual(Array(made.argv.prefix(3)), ["rnaseq", "cell-map", "import"])
        let parsed = try RNASeqCellMapImportSubcommand.parse(Array(made.argv.dropFirst(3)))
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
        XCTAssertEqual(
            parsed.canonicalArgv(), [CLICommandIdentity.executableName] + made.argv.dropLast(2),
            "the record the leaf writes is the command the row shows")
    }

    func testBeginNamesIngestionTheTitleTheFirstStageAndTheImportCommandThatRuns() throws {
        let center = OperationCenter()
        let made = imported
        var launched: UUID?
        let result = RNASeqLeafRoute.begin(made.run, operations: center) { launched = $0 }
        guard case .started(let id) = result else { return XCTFail("begin refused the run") }
        XCTAssertEqual(launched, id)
        XCTAssertEqual(made.stageLines, [
            "Reading projection.csv", "Reading lge-cell-map.tsv", "Reading clusters.csv",
            "Checking barcodes against cells.lungfishrnaseq", "Writing map1.lungfishrnaseq",
        ])
        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertEqual(item.title, "Import Embedding")
        XCTAssertEqual(item.detail, "Reading projection.csv")
        XCTAssertEqual(item.cliCommand, made.run.cliCommand)
        let recorded = try RecordedCLICommand.parse(item.cliCommand, as: RNASeqCellMapImportSubcommand.self)
        XCTAssertEqual(recorded.canonicalArgv(), [CLICommandIdentity.executableName] + made.argv.dropLast(2))
    }

    func testALockedResultRefusesTheImportRowAndLaunchesNothing() {
        let center = OperationCenter()
        _ = center.begin(
            title: "Holder", detail: "", operationType: .rnaSeqQuantification, targetBundleURL: single, cliCommand: nil,
            routeContext: nil)
        var launched = false
        let result = RNASeqLeafRoute.begin(imported.run, operations: center) { _ in launched = true }
        guard case .refused = result else { return XCTFail("a result under another row's lock was accepted") }
        XCTAssertFalse(launched)
    }

    func testEachRefusalNamesTheControlOfThePaneThatUnlocksIt() throws {
        typealias Words = RNASeqCellMapImportWords
        let cases: [(RNASeqCellMapImportRefusal, String, String)] = [
            (.suffix(file: "projection.csv", sample: "pbmc", wouldMatch: 200, of: 1_222, suffix: .drop), Words.dropControl,
             "200 of its 1,222 barcodes would match"),
            (.suffix(file: "projection.csv", sample: "pbmc", wouldMatch: 200, of: 1_222, suffix: .add), Words.addControl,
             "200 of its 1,222 barcodes would match"),
            (.notHeld(file: "projection.csv", count: 1_022, first: ["AAACCTGAGAAACCTA-1"]), Words.skipControl,
             "1,022 barcodes that the result does not hold, such as AAACCTGAGAAACCTA-1"),
            (.otherCounts(file: "projection.csv", name: "cells", tool: "STARsolo"), Words.otherCountsControl,
             "cells holds the counts of STARsolo"),
        ]
        for (refusal, control, counts) in cases {
            let cli = try XCTUnwrap(refusal.errorDescription)
            XCTAssertTrue(cli.contains("--"), "the CLI's words name a flag: \(cli)")
            let pane = try XCTUnwrap(Words.paneWords(forCLIWords: cli), cli)
            XCTAssertTrue(pane.contains("Turn on \(control), then import again."), pane)
            XCTAssertFalse(pane.contains("--"), "the pane's words name no flag: \(pane)")
            XCTAssertTrue(pane.contains(counts), "the counts stay: \(pane)")
        }
        XCTAssertNil(Words.paneWords(forCLIWords: "The result cells is not a single-cell result."), "words without a flag show as they are")
    }

    /// Brief item 2: the row reads Completed when the leaf exited 0 and the new result loads. A load that fails leaves it Failed.
    func testALoadThatFailsAfterExitZeroLeavesTheRowFailedWithTheWordsAndOpensNothing() async throws {
        let output = folder.appendingPathComponent("map1.lungfishrnaseq", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var request = imported
        request.resultURL = folder.appendingPathComponent("cells.lungfishrnaseq", isDirectory: true)
        request.outputURL = output
        let probe = ImportProbe()
        let launched = try XCTUnwrap(RNASeqLeafRoute.launchImport(
            request, runner: CLIViewerExportRunner(cliURLOverride: try standInCLI(completing: output)),
            load: { _ in throw UnreadableCellMap() }, open: { _ in probe.opened += 1; return true },
            report: { _, words in probe.alerts.append(words) }))
        defer { OperationCenter.shared.clearItem(id: launched.operationID) }
        let end = await launched.task.value
        let words = RNASeqCellMapImportWords.loadFailedWords(name: "map1.lungfishrnaseq", reason: UnreadableCellMap().localizedDescription)
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == launched.operationID })
        XCTAssertEqual(end, .loadFailed(words))
        XCTAssertEqual(item.state, .failed, "the row reads Completed only when the new result loads")
        XCTAssertEqual(item.errorMessage, words)
        XCTAssertTrue(item.outputURLs.isEmpty)
        XCTAssertEqual(probe.alerts, [words])
        XCTAssertEqual(probe.opened, 0)
    }

    func testAResultThatLoadsEndsCompletedAndOpens() async throws {
        let output = folder.appendingPathComponent("map1.lungfishrnaseq", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var request = imported
        request.resultURL = folder.appendingPathComponent("cells.lungfishrnaseq", isDirectory: true)
        request.outputURL = output
        let probe = ImportProbe()
        let launched = try XCTUnwrap(RNASeqLeafRoute.launchImport(
            request, runner: CLIViewerExportRunner(cliURLOverride: try standInCLI(completing: output)),
            load: { _ in }, open: { _ in probe.opened += 1; return true }, report: { _, words in probe.alerts.append(words) }))
        defer { OperationCenter.shared.clearItem(id: launched.operationID) }
        let end = await launched.task.value
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == launched.operationID })
        XCTAssertEqual(end, .opened(output))
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.outputURLs, [output])
        XCTAssertEqual(probe.opened, 1)
        XCTAssertTrue(probe.alerts.isEmpty)
    }
}

/// What the closures of a launched import saw, on the main actor with the test.
@MainActor
private final class ImportProbe {
    var opened = 0
    var alerts: [String] = []
}

private struct UnreadableCellMap: LocalizedError {
    var errorDescription: String? { "The manifest is not readable." }
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

    /// How the row ends. The labels file always makes a note (the group of 9 cells), so a run that completed ends Completed with
    /// Warnings by the Label rule of `docs/contracts/CLI-EQUIVALENCE.md` (a warning log line), the same as a script's run does.
    private func end(of outcome: CLIViewerExportRunner.Outcome, row: OperationCenter.Item) -> RouteParityEnd {
        switch outcome {
        case .completed: return row.hasWarnings ? .completedWithWarnings : .completed
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
                    end: self.end(of: outcome, row: item), detail: item.errorMessage ?? item.detail, recordedCommand: item.cliCommand)
            }
        )
        let runs = result.runs
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completedWithWarnings, "side \(run.side): \(run.outcome.detail)")
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

    // MARK: Import Embedding (CM-IMPORT-APP)
    //
    // The STARsolo cut takes 10x's t-SNE and graph clusters with the suffix dropped and counts of another route stated, which is
    // case P2 of the plan's X1. The leaf is the built `lungfish-cli`, so the pane's run, a script's run and the replay of the
    // recorded command write the same label tables and keep the same given files.

    private static let projection = RNASeqFixtures.root
        .appendingPathComponent("tenx-analysis-pbmc_1k_v3/analysis/tsne/2_components/projection.csv")
    private static let clusters = RNASeqFixtures.root
        .appendingPathComponent("tenx-analysis-pbmc_1k_v3/analysis/clustering/graphclust/clusters.csv")

    private func importRequest(in root: URL, flags: Bool = true) -> RNASeqCellMapImportRunRequest {
        RNASeqCellMapImportRunRequest(
            resultURL: root.appendingPathComponent("Analyses/cells.lungfishrnaseq", isDirectory: true),
            coordinateURLs: [Self.projection], clusterURLs: [Self.clusters],
            barcodeSuffix: flags ? .drop : nil, otherCounts: flags,
            outputURL: root.appendingPathComponent("Analyses/map1.lungfishrnaseq", isDirectory: true))
    }

    private func importEnd(of end: RNASeqCellMapImportEnd, row: OperationCenter.Item) -> RouteParityEnd {
        switch end {
        case .opened, .notOpened: return row.hasWarnings ? .completedWithWarnings : .completed
        case .cancelled: return .cancelled
        case .loadFailed, .refused: return .failed
        }
    }

    /// The label tables and the given files kept under `source/` of the cell map in `root`, by their place in the folder.
    private func keptFiles(in root: URL) throws -> [String: Data] {
        let map = root.appendingPathComponent("Analyses/map1.lungfishrnaseq", isDirectory: true)
        var files: [String: Data] = [:]
        for name in ["labels", "source"] {
            guard let walker = FileManager.default.enumerator(
                at: map.appendingPathComponent(name, isDirectory: true), includingPropertiesForKeys: [.isRegularFileKey])
            else { continue }
            for case let url as URL in walker {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                      let marker = url.path.range(of: "/map1.lungfishrnaseq/") else { continue }
                files[String(url.path[marker.upperBound...])] = try Data(contentsOf: url)
            }
        }
        return files
    }

    func testTheImportRowsRunEqualsTheRunOfAScriptAndTheCommandItShowsReplaysToTheSame() async throws {
        var masks = OutputEquivalence.MaskPolicy.standard
        masks.payloads.append(OutputEquivalence.Masks.quantResultCreatedAt)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, masks: masks, replayTimeout: .seconds(120))
        let caseRoot = scratch.appendingPathComponent("cases/of/the/rnaseq-cell-map-import", isDirectory: true)
        let result = try await harness.assertParity(
            "starsoloCutByTenXTsne", declared: [], in: caseRoot,
            fixture: { root in try self.writeSingleCellResult(in: root) },
            sideA: { root in
                let run = await RouteParityHarness.runCLI(
                    self.cli, arguments: self.importRequest(in: root).argv, timeout: .seconds(120), environment: [:])
                return RouteParitySideOutcome(end: run.end, detail: run.detail)
            },
            sideC: { root in
                let request = self.importRequest(in: root)
                guard let launched = RNASeqLeafRoute.launchImport(
                    request, runner: CLIViewerExportRunner(cliURLOverride: self.cli), open: { _ in true }, report: { _, _ in })
                else { return RouteParitySideOutcome(end: .failed, detail: "begin refused the run") }
                let end = await launched.task.value
                guard let item = OperationCenter.shared.items.first(where: { $0.id == launched.operationID }) else {
                    return RouteParitySideOutcome(end: .failed, detail: "the row is gone")
                }
                XCTAssertEqual(item.operationType, .ingestion)
                let stages = item.logEntries.map(\.message).filter { request.stageLines.contains($0) }
                XCTAssertEqual(stages, request.stageLines, "the row shows the leaf's three stages once each, in order")
                return RouteParitySideOutcome(
                    end: self.importEnd(of: end, row: item), detail: item.errorMessage ?? item.detail, recordedCommand: item.cliCommand)
            }
        )
        let runs = result.runs
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completedWithWarnings, "side \(run.side): \(run.outcome.detail)")
        }
        let kept = try runs.all.map { try self.keptFiles(in: $0.root) }
        XCTAssertTrue(kept[0].keys.contains("source/1/projection.csv"), "the kept files are \(kept[0].keys.sorted())")
        XCTAssertFalse(kept[0].keys.filter { $0.hasPrefix("labels/") }.isEmpty, "the cell map holds a label table")
        XCTAssertEqual(kept[0], kept[1], "the label tables and kept files of the script and of the row")
        XCTAssertEqual(kept[1], kept[2], "the label tables and kept files of the row and of its replay")
        XCTAssertEqual(kept[1]["source/1/projection.csv"], try Data(contentsOf: Self.projection), "a kept file is the given file byte for byte")
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        XCTAssertTrue(command.hasPrefix("lungfish-cli rnaseq cell-map import "), command)
        XCTAssertEqual(runs.cPrime.replayedArguments.count, 1, "the row records one command")
    }

    /// A run with no flag on the pair is refused with the pane's control named, while the row keeps the CLI's own words.
    func testARunWithNoFlagsIsRefusedInThePanesWordsAndTheRowKeepsTheCLIsWords() async throws {
        let root = scratch.appendingPathComponent("import-refused", isDirectory: true)
        try writeSingleCellResult(in: root)
        let made = importRequest(in: root, flags: false)
        let probe = ImportProbe()
        let launched = try XCTUnwrap(RNASeqLeafRoute.launchImport(
            made, runner: CLIViewerExportRunner(cliURLOverride: cli), open: { _ in probe.opened += 1; return true },
            report: { _, words in probe.alerts.append(words) }))
        let end = await launched.task.value
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == launched.operationID })
        guard case .refused(let words) = end else { return XCTFail("the run ended \(end)") }
        XCTAssertTrue(words.contains("Turn on \(RNASeqCellMapImportWords.dropControl), then import again."), words)
        XCTAssertFalse(words.contains("--"), words)
        XCTAssertEqual(probe.alerts, [words])
        XCTAssertEqual(probe.opened, 0)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.errorMessage?.contains("--barcode-suffix drop") == true, "the row keeps the CLI's words: \(item.errorMessage ?? "")")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.outputURL.path), "a refusal leaves no result")
    }

    /// A cancel reads Cancelled on the row, shows no alert, opens nothing and leaves no folder and no stage.
    func testACancelOfTheImportLeavesNoResultNoStageAndNoAlert() async throws {
        let root = scratch.appendingPathComponent("import-cancel", isDirectory: true)
        try writeSingleCellResult(in: root)
        let hold = root.appendingPathComponent("held")
        let made = importRequest(in: root)
        let probe = ImportProbe()
        let launched = try XCTUnwrap(RNASeqLeafRoute.launchImport(
            made, runner: CLIViewerExportRunner(cliURLOverride: cli), environmentAdditions: [Self.holdFileVariable: hold.path],
            open: { _ in probe.opened += 1; return true }, report: { _, words in probe.alerts.append(words) }))
        let held = await waitUntil(timeout: WaitBudget.lookup.duration) { FileManager.default.fileExists(atPath: hold.path) }
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: launched.operationID)
        let end = await launched.task.value
        let item = OperationCenter.shared.items.first { $0.id == launched.operationID }
        XCTAssertEqual(end, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertNil(item?.errorMessage, "a cancel is not an error")
        XCTAssertTrue(probe.alerts.isEmpty, "a cancel shows no alert")
        XCTAssertEqual(probe.opened, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.outputURL.path), "a cancel leaves no result")
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true).path
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: analyses).sorted(), ["cells.lungfishrnaseq"],
            "a cancel leaves no stage beside the single-cell result")
    }
}
