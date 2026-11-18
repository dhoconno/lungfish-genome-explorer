// RNASeqExportDialogTests.swift - The export row of the Workflow Operations dialog (RS-DIALOG-M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.4, lane RS-DIALOG-M2, brief items 1 and 3. The row runs the same `lungfish-cli rnaseq export` a script runs.
//
// `RNASeqExportDialogTests` runs in every tier. The argv of the row parses through the real `RNASeqExportSubcommand`, `begin` names
// the operation type and the command that runs, and a locked result refuses the row and launches nothing.
//
// `RNASeqExportDialogParityReplayTests` runs the built `lungfish-cli` (no external tool), so its name ends in `ReplayTests` and it runs
// serially in the integration tier. It holds the parity replay on a result written from `Tests/Fixtures/rnaseq/salmon-c1/`, a refusal
// under 3 animals that reaches the Operations row in the CLI's words, and a cancel that leaves no folder and no stage. The row's
// own `OperationCenter.shared` is the one `CLIViewerExportRunner` settles, as in the other viewer export replay tests.

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
final class RNASeqExportDialogTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/export-project/Analyses/a.lungfishrnaseq", isDirectory: true)
    private let second = URL(fileURLWithPath: "/tmp/export-project/Analyses/b.lungfishrnaseq", isDirectory: true)
    private let output = URL(fileURLWithPath: "/tmp/export-project/Exports/de", isDirectory: true)

    private var full: RNASeqExportRunRequest {
        RNASeqExportRunRequest(
            resultURLs: [first, second], outputURL: output,
            sampleSheetURL: URL(fileURLWithPath: "/tmp/export-project/sheet.tsv"),
            design: ["batch", "group"], contrasts: ["group:TB:HIV", "group:HIV:ctl"], padjCutoff: 0.1, lfcBar: 1,
            batch: "batch", batchCorrection: .combatSeq)
    }

    // MARK: argv round trip

    func testArgvParsesThroughTheRealExportSubcommand() throws {
        for made in [RNASeqExportRunRequest(resultURLs: [first], outputURL: output), full] {
            XCTAssertEqual(Array(made.argv.prefix(2)), ["rnaseq", "export"])
            let parsed = try RNASeqExportSubcommand.parse(Array(made.argv.dropFirst(2)))
            XCTAssertEqual(parsed.resultPaths, made.resultURLs.map(\.path))
            XCTAssertEqual(parsed.outputPath, made.outputURL.path)
            XCTAssertEqual(parsed.sheetPath, made.sampleSheetURL?.path)
            XCTAssertEqual(parsed.design, made.design)
            XCTAssertEqual(parsed.contrastWords, made.contrasts)
            XCTAssertEqual(parsed.padjCutoff, made.padjCutoff)
            XCTAssertEqual(parsed.lfcBar, made.lfcBar)
            XCTAssertEqual(parsed.batch, made.batch)
            XCTAssertEqual(parsed.batchCorrection, made.batchCorrection.rawValue)
            XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
        }
    }

    func testTheCutoffDefaultIsTheCLIsOwnAndTheWordsAreTheGoldenHelps() throws {
        let bare = try RNASeqExportSubcommand.parse(["/tmp/a.lungfishrnaseq", "--output", "/tmp/out"])
        XCTAssertEqual(RNASeqExportDefaults.padjCutoff, bare.padjCutoff)
        XCTAssertEqual(RNASeqExportDefaults.padjCutoff, 0.05)
        XCTAssertEqual(RNASeqExportRunRequest(resultURLs: [first], outputURL: output).padjCutoff, 0.05)
        XCTAssertTrue(RNASeqExportRunRequest(resultURLs: [first], outputURL: output).argv.contains("0.05"), "the cutoff is always named")
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden/cli-help/lungfish-cli.rnaseq.export.txt")
        func words(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let help = words(try String(contentsOf: golden, encoding: .utf8))
        for line in [
            RNASeqExportDefaults.cutoffHelp, RNASeqExportDefaults.designHelp, RNASeqExportDefaults.contrastHelp,
            RNASeqExportDefaults.lfcBarHelp, RNASeqExportDefaults.batchHelp,
        ] {
            XCTAssertTrue(help.contains(words(line)), "The golden help of rnaseq export does not state: \(line)")
        }
        XCTAssertTrue(RNASeqExportDefaults.cutoffHelp.contains("alpha in DESeq2"), "the words say that the cutoff is alpha")
    }

    // MARK: begin

    func testBeginNamesTheOperationTypeAndTheCommandThatRuns() throws {
        let center = OperationCenter()
        let made = full
        var launched: UUID?
        let result = RNASeqLeafRoute.begin(made.run, operations: center) { launched = $0 }
        guard case .started(let id) = result else { return XCTFail("begin refused the run") }
        XCTAssertEqual(launched, id)
        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.operationType, .rnaSeqExport)
        XCTAssertEqual(item.cliCommand, made.run.cliCommand)
        XCTAssertTrue(try XCTUnwrap(item.cliCommand).hasPrefix("lungfish-cli rnaseq export "), item.cliCommand ?? "nil")
        // The command the row shows parses through the shipped binary's own entry point, as a script would run it.
        let recorded = try RecordedCLICommand.parse(item.cliCommand, as: RNASeqExportSubcommand.self)
        XCTAssertEqual(recorded.resultPaths, made.resultURLs.map(\.path))
        XCTAssertEqual(recorded.design, made.design)
        XCTAssertEqual(recorded.contrastWords, made.contrasts)
        XCTAssertEqual(recorded.padjCutoff, 0.1)
        XCTAssertEqual(recorded.batchCorrection, "combat-seq")
    }

    func testALockedResultRefusesTheRowAndLaunchesNothing() {
        let center = OperationCenter()
        _ = center.begin(
            title: "Holder", detail: "", operationType: .rnaSeqQuantification, targetBundleURL: first, cliCommand: nil,
            routeContext: nil)
        var launched = false
        let result = RNASeqLeafRoute.begin(full.run, operations: center) { _ in launched = true }
        guard case .refused = result else { return XCTFail("a result under another row's lock was accepted") }
        XCTAssertFalse(launched)
    }
}

// MARK: - The built CLI

@MainActor
final class RNASeqExportDialogParityReplayTests: XCTestCase {
    private static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    private var scratch: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "rnaseq-export-dialog")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: fixtures

    /// `import rnaseq` of the two salmon-c1 folders as the import builds it, with each transcript summed to itself so the table holds
    /// the gene rows the export reads.
    @discardableResult
    private func writeC1Result(in root: URL) throws -> URL {
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let folders = try RNASeqFixtures.salmonRunIDs.map {
            try SalmonQuantFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent("salmon-c1/\($0)", isDirectory: true))
        }
        let transcripts = try SalmonQuantFolderReader.transcriptCounts(folders)
        let identity = SalmonTx2Gene(geneByTranscript: Dictionary(uniqueKeysWithValues: transcripts.rows.map { ($0.id, $0.id) }))
        let genes = try SalmonQuantFolderReader.geneCounts(folders, tx2gene: identity)
        let route = try SalmonQuantFolderReader.route(folders, tx2geneName: "identity.tsv")
        let request = RNASeqResultWriter.Request(
            name: "c1", modality: .bulk, origin: .init(kind: .imported, tool: SalmonQuantFolderReader.tool, toolVersion: route.toolVersion),
            route: route, referenceSet: nil, samples: folders.map { RNASeqSampleRecord(id: $0.sample, runs: [$0.sample]) },
            genes: .ids(genes.rows.map(\.id)),
            counts: [.init(rows: .gene, column: .default, unit: .estimated, table: genes)],
            sourceFiles: SalmonQuantFolderReader.sourceFiles(folders), notHost: [],
            quality: SalmonQuantFolderReader.qualityTable(folders))
        let url = analyses.appendingPathComponent("c1.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
    }

    /// The STARsolo cut summed by the analyst's labels, as `rnaseq pseudobulk` writes it, whose levels each hold one animal.
    @discardableResult
    private func writePseudobulkResult(in root: URL) throws -> URL {
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let folder = try SingleCellFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent("starsolo-pbmc_1k_v3", isDirectory: true))
        let samples = [RNASeqSampleRecord(id: folder.sample, animal: "A1", species: "Homo sapiens", runs: [folder.sample])]
        let single = try SingleCellFolderReader.request([folder], name: "cells", samples: samples, genomes: [])
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        let cells = try writer.write(single, to: analyses.appendingPathComponent("cells.lungfishrnaseq", isDirectory: true), envelope: envelope)
        let summed = try RNASeqPseudobulk.sum(
            result: cells, labels: RNASeqFixtures.root.appendingPathComponent("pseudobulk-pbmc_1k_v3/labels-starsolo.tsv"),
            name: "pb1", createdAt: Date())
        return try writer.write(summed.request, to: analyses.appendingPathComponent("pb1.lungfishrnaseq", isDirectory: true), envelope: envelope)
    }

    private func request(in root: URL) -> RNASeqExportRunRequest {
        RNASeqExportRunRequest(
            resultURLs: [root.appendingPathComponent("Analyses/c1.lungfishrnaseq", isDirectory: true)],
            outputURL: root.appendingPathComponent("export-out", isDirectory: true))
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
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let caseRoot = scratch.appendingPathComponent("cases/of/the/rnaseq-export-dialog", isDirectory: true)
        let result = try await harness.assertParity(
            "twoSalmonRunsOfC1", declared: [], in: caseRoot,
            fixture: { root in try self.writeC1Result(in: root) },
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
                XCTAssertEqual(item.operationType, .rnaSeqExport)
                return RouteParitySideOutcome(
                    end: self.end(of: outcome), detail: item.errorMessage ?? item.detail, recordedCommand: item.cliCommand)
            }
        )
        let runs = result.runs
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            for name in ["counts.tsv", "genes.tsv", "samples.tsv", "deseq2.R", "edger-limma-dream.R", ".lungfish-provenance.json"] {
                let file = run.root.appendingPathComponent("export-out/\(name)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "side \(run.side) has no \(name)")
            }
        }
        let counts = try runs.all.map { try Data(contentsOf: $0.root.appendingPathComponent("export-out/counts.tsv")) }
        XCTAssertFalse(counts[0].isEmpty)
        XCTAssertEqual(counts[0], counts[1], "counts.tsv of the script and of the row")
        XCTAssertEqual(counts[1], counts[2], "counts.tsv of the row and of its replay")
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        XCTAssertTrue(command.hasPrefix("lungfish-cli rnaseq export "), command)
        XCTAssertEqual(runs.cPrime.replayedArguments.count, 1, "the row records one command")
    }

    // MARK: refusal

    /// The CLI's refusal of a pseudobulk comparison under 3 animals reaches the row in the CLI's words and nothing is written.
    func testARefusalUnderThreeAnimalsReachesTheRowInTheCLIsWords() async throws {
        let root = scratch.appendingPathComponent("refusal", isDirectory: true)
        let pseudobulk = try writePseudobulkResult(in: root)
        let made = RNASeqExportRunRequest(
            resultURLs: [pseudobulk], outputURL: root.appendingPathComponent("export-out", isDirectory: true), design: ["group"])
        // The words come from the CLI's own code, run on the same argv.
        var words = ""
        do {
            _ = try RNASeqExportSubcommand.parse(Array(made.argv.dropFirst(2))).export()
            return XCTFail("the export of one animal a level was accepted")
        } catch let refusal as ViewerExportRefusal {
            words = refusal.message
        }
        XCTAssertTrue(words.contains("animals"), words)

        let launched = try XCTUnwrap(RNASeqLeafRoute.launch(made.run, runner: CLIViewerExportRunner(cliURLOverride: cli)))
        let outcome = await launched.task.value
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == launched.operationID })
        XCTAssertEqual(item.operationType, .rnaSeqExport)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(outcome, .failed(.init(message: item.errorMessage ?? "")))
        XCTAssertTrue(item.errorMessage?.contains(words) == true, "the row says \(item.errorMessage ?? "nothing"), the CLI says \(words)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.outputURL.path), "a refusal leaves no folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["Analyses"], "a refusal leaves no stage")
    }

    // MARK: cancel

    func testACancelLeavesNoFolderAndNoStage() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try writeC1Result(in: root)
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.outputURL.path), "a cancel leaves no folder")
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "Analyses" && $0 != "held" }
        XCTAssertEqual(left, [], "a cancel leaves no stage beside the output")
    }
}
