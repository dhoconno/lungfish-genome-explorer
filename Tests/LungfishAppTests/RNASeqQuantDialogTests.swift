// RNASeqQuantDialogTests.swift - The quantify row of the FASTQ operations dialog (RS-DIALOG-M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// The argv of the row parses through the real `rnaseq quant`, `begin` names its type and the command that runs, a cancel
/// reaches the CLI process without waiting on the task, and the pane shows the CLI's own defaults.
@MainActor
final class RNASeqQuantDialogTests: XCTestCase {
    private func request(
        trim: Bool = false, polyG: Bool = false, decoys: RNASeqQuantRunRequest.Decoys = .genome, k: Int = 31
    ) -> RNASeqQuantRunRequest {
        RNASeqQuantRunRequest(
            bundleURLs: [
                URL(fileURLWithPath: "/tmp/quant-project/Sample A.lungfishfastq"),
                URL(fileURLWithPath: "/tmp/quant-project/Sample B.lungfishfastq"),
            ],
            projectURL: URL(fileURLWithPath: "/tmp/quant-project"), setID: "grch38-ensembl-112",
            k: k, decoys: decoys, trim: trim, polyGTrimming: polyG)
    }

    private struct StandInRunner: RNASeqQuantCommandRunning {
        let outcome: Result<RNASeqQuantRunOutcome, RNASeqQuantRunError>

        func run(
            argv: [String], cancellation: CLIRunCancellation, log: @escaping @Sendable (String) -> Void
        ) async throws -> RNASeqQuantRunOutcome {
            log("stand-in ran \(argv.count) words")
            return try outcome.get()
        }
    }

    // MARK: argv round trip

    func testArgvParsesThroughTheRealQuantSubcommand() throws {
        let cases: [(Bool, Bool, RNASeqQuantRunRequest.Decoys, Int)] = [
            (false, false, .genome, 31), (true, false, .none, 25), (true, true, .genome, 21),
        ]
        for (trim, polyG, decoys, k) in cases {
            let made = request(trim: trim, polyG: polyG, decoys: decoys, k: k)
            XCTAssertEqual(Array(made.argv.prefix(2)), ["rnaseq", "quant"])
            let parsed = try RNASeqCommand.QuantSubcommand.parse(Array(made.argv.dropFirst(2)))
            XCTAssertEqual(parsed.bundles, made.bundleURLs.map(\.path))
            XCTAssertEqual(parsed.project, "/tmp/quant-project")
            XCTAssertEqual(parsed.setID, "grch38-ensembl-112")
            XCTAssertEqual(parsed.k, k)
            XCTAssertEqual(parsed.decoys, decoys.rawValue)
            XCTAssertEqual(parsed.trim, trim)
            XCTAssertEqual(parsed.polyGTrimming, trim ? (polyG ? "on" : "off") : nil)
            XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
        }
    }

    func testAVirtualBundleIsNamedByItsFolderNeverByItsPreview() {
        let argv = request().argv
        XCTAssertTrue(argv.contains("/tmp/quant-project/Sample A.lungfishfastq"))
        XCTAssertFalse(argv.contains { $0.hasSuffix("preview.fastq") })
    }

    func testTheSummaryOfTheCLIIsRead() throws {
        let outcome = try CLIRNASeqQuantRunner.outcome(fromStdout: [
            "noise", #"{"index":"k31","result":"/tmp/quant-project/Analyses/rnaseq-1","samples":["a","b"],"setID":"s"}"#,
        ])
        XCTAssertEqual(outcome.resultURL.path, "/tmp/quant-project/Analyses/rnaseq-1")
        XCTAssertEqual(outcome.samples, ["a", "b"])
        XCTAssertThrowsError(try CLIRNASeqQuantRunner.outcome(fromStdout: ["Counted 2 samples"]))
    }

    // MARK: begin

    func testBeginNamesTheOperationTypeAndTheCommandThatRuns() async throws {
        let center = OperationCenter()
        let made = request(trim: true)
        let runner = StandInRunner(outcome: .success(RNASeqQuantRunOutcome(
            resultURL: URL(fileURLWithPath: "/tmp/quant-project/Analyses/rnaseq-1"), samples: ["a", "b"])))
        let task = try XCTUnwrap(RNASeqQuantRoute.launch(made, operations: center, runner: runner))
        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.operationType, .rnaSeqQuantification)
        XCTAssertEqual(item.cliCommand, (["lungfish-cli"] + made.argv).map(shellEscape).joined(separator: " "))
        XCTAssertEqual(item.cliCommand, made.cliCommand)
        // The command the row shows parses through the shipped binary's own entry point, as a script would run it.
        let recorded = try RecordedCLICommand.parse(item.cliCommand, as: RNASeqCommand.QuantSubcommand.self)
        XCTAssertEqual(recorded.bundles, made.bundleURLs.map(\.path))
        XCTAssertEqual(recorded.setID, made.setID)
        XCTAssertEqual(recorded.k, made.k)
        await task.value
        XCTAssertEqual(center.items.first?.state, .completed)
    }

    func testAFailedRunShowsTheCLIsWordsOnTheRow() async throws {
        let center = OperationCenter()
        let words = "The set grch38 has no index for k 31. Run lungfish-cli rnaseq index first."
        let runner = StandInRunner(outcome: .failure(.failed(status: 2, message: words)))
        let task = try XCTUnwrap(RNASeqQuantRoute.launch(request(), operations: center, runner: runner))
        await task.value
        XCTAssertEqual(center.items.first?.state, .failed)
        XCTAssertEqual(center.items.first?.errorMessage, words)
    }

    // MARK: cancel

    /// A stand-in for the CLI that says when it runs and ends with the CLI's cancel status when it gets SIGTERM.
    private func makeStandInCLI(in folder: URL) throws -> (cli: URL, marker: URL) {
        let marker = folder.appendingPathComponent("terminated.txt")
        let cli = folder.appendingPathComponent("stand-in-cli")
        let script = """
        #!/bin/bash
        trap 'kill $child 2>/dev/null; echo terminated > "\(marker.path)"; exit 125' TERM
        echo ready >&2
        sleep 60 &
        child=$!
        wait $child
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli, marker)
    }

    private struct ObservingRunner: RNASeqQuantCommandRunning {
        let inner: CLIRNASeqQuantRunner
        let seen: AsyncStream<String>.Continuation

        func run(
            argv: [String], cancellation: CLIRunCancellation, log: @escaping @Sendable (String) -> Void
        ) async throws -> RNASeqQuantRunOutcome {
            try await inner.run(argv: argv, cancellation: cancellation) { line in
                seen.yield(line)
                log(line)
            }
        }
    }

    func testACancelReachesTheCLIProcessAndLeavesNoResult() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnaseq-quant-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let standIn = try makeStandInCLI(in: folder)
        let (lines, sink) = AsyncStream<String>.makeStream()
        let runner = ObservingRunner(inner: CLIRNASeqQuantRunner(cliURLProvider: { standIn.cli }), seen: sink)
        let center = OperationCenter()
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var made = request()
        made.projectURL = project

        let task = try XCTUnwrap(RNASeqQuantRoute.launch(made, operations: center, runner: runner))
        for await line in lines where line == "ready" { break }
        let id = try XCTUnwrap(center.items.first?.id)
        center.cancel(id: id)
        await task.value
        sink.finish()

        XCTAssertEqual(try String(contentsOf: standIn.marker, encoding: .utf8), "terminated\n")
        XCTAssertEqual(center.items.first?.state, .cancelled)
        XCTAssertNil(center.items.first?.errorMessage)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
        XCTAssertEqual(left, [], "A cancelled quantify leaves no result and no stage in the project")
    }

    // MARK: the tool and its pane

    func testTheQuantToolSitsInItsOwnCategoryWithTheRNASeqPack() {
        XCTAssertEqual(FASTQOperationToolID.rnaSeqQuant.categoryID, .rnaSeq)
        XCTAssertEqual(FASTQOperationDialogState.toolIDs(for: .rnaSeq), [.rnaSeqQuant])
        XCTAssertEqual(FASTQOperationCategoryID.rnaSeq.requiredPackIDs, ["rna-seq"])
        XCTAssertEqual(FASTQOperationCategoryID.rnaSeq.defaultToolID, .rnaSeqQuant)
        XCTAssertTrue(ToolsMenuLayout.categories.contains(.rnaSeq))
        XCTAssertFalse(FASTQOperationToolID.rnaSeqQuant.usesEmbeddedConfiguration)
        XCTAssertFalse(FASTQOperationToolID.rnaSeqQuant.supportsFASTA)
        XCTAssertEqual(FASTQOperationToolID.rnaSeqQuant.defaultOutputMode, .fixedBatch)
        XCTAssertFalse(FASTQOperationToolID.rnaSeqQuant.supportsConfigurableOutput)
    }

    func testRunCapturesTheRequestOfThePane() throws {
        let project = URL(fileURLWithPath: "/tmp/quant-project", isDirectory: true)
        let bundle = project.appendingPathComponent("Sample A.lungfishfastq", isDirectory: true)
        let state = FASTQOperationDialogState(
            initialCategory: .rnaSeq, selectedInputURLs: [bundle], projectURL: project, availableToolIDs: nil)
        state.selectTool(.rnaSeqQuant)
        XCTAssertEqual(state.readinessText, "Download a reference set in Plugin Manager to count these reads.")
        state.rnaSeqQuant.availableSets = [RNASeqQuantReferenceSetChoice(id: "grch38", species: "Homo sapiens")]
        state.rnaSeqQuant.referenceSetID = "grch38"
        state.rnaSeqQuant.trim = true
        XCTAssertTrue(state.isRunEnabled)
        state.prepareForRun()
        XCTAssertNil(state.pendingLaunchRequest)
        let captured = try XCTUnwrap(state.pendingRNASeqQuantRequest)
        XCTAssertEqual(captured.bundleURLs, [bundle])
        XCTAssertEqual(captured.setID, "grch38")
        XCTAssertEqual(captured.argv.suffix(5), ["--trim", "--poly-g-trimming", "off", "--format", "json"])
    }

    func testAFileInsideABundleCountsAsItsBundleOnce() {
        let bundle = URL(fileURLWithPath: "/tmp/quant-project/Sample A.lungfishfastq", isDirectory: true)
        let inputs = [bundle, bundle.appendingPathComponent("reads.fastq.gz")]
        XCTAssertEqual(RNASeqQuantDialogModel.bundleURLs(from: inputs), [bundle])
    }

    func testThePaneShowsTheCLIsOwnDefaultsAsTheGoldenHelpStatesThem() throws {
        let golden = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden/cli-help/lungfish-cli.rnaseq.quant.txt")
        func words(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let help = words(try String(contentsOf: golden, encoding: .utf8))
        for line in [
            RNASeqQuantDefaults.kHelp, RNASeqQuantDefaults.decoysHelp,
            RNASeqQuantDefaults.trimHelp, RNASeqQuantDefaults.polyGHelp,
        ] {
            XCTAssertTrue(help.contains(words(line)), "The golden help of rnaseq quant does not state: \(line)")
        }
        XCTAssertEqual(RNASeqQuantDialogModel().k, RNASeqQuantDefaults.k)
        XCTAssertEqual(RNASeqQuantDialogModel().decoys.rawValue, "genome")
        XCTAssertFalse(RNASeqQuantDialogModel().trim)
    }

    func testTheSetsUnderTheStorageRootAreListedById() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnaseq-quant-sets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sets = root.appendingPathComponent("rnaseq-reference-sets", isDirectory: true)
        for name in ["grch38.lungfishrefset", "mmul10.lungfishrefset", ".grch38.lungfishrefset.creating-1", "notes"] {
            try FileManager.default.createDirectory(at: sets.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data(#"{"species":"Homo sapiens"}"#.utf8)
            .write(to: sets.appendingPathComponent("grch38.lungfishrefset/reference-set.json"))
        let choices = RNASeqQuantReferenceSets.choices(storageRoot: root)
        XCTAssertEqual(choices.map(\.id), ["grch38", "mmul10"])
        XCTAssertEqual(choices.first?.label, "grch38 (Homo sapiens)")
    }
}
