// FastqIngestCancelReplayTests.swift - The Cancel of `fastq ingest` through the app's transport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M2 and M3 (SWIFT 3, panel decisions C5, P2 and G1, and the ruling on M3
// section 5). The window's Cancel reaches a CLI route through `CLISubprocessTransport.cancel()`,
// so ToolProcess sends SIGTERM to the command and its tree, and SIGKILL after
// `CLIProcessLauncher.operationGrace`. `FastqIngestSIGTERMTests` signals the command alone. These
// tests cancel the way the app does, while a stand-in clumpify holds a half-written output in the
// command's staging folder. The command must exit 125 inside the grace and leave no process behind.
//
// - A folder with no record gets the command's `cancelled` record, and the original is as it was.
// - A folder that holds a record already is the file's history, so the cancel writes nothing and
//   every file in it keeps its digest, with nothing staged beside the input.
// - The first case again with every core busy, since the handler that writes the record races the
//   death of the tool on a loaded machine.
// - Since 2.11 S8 the command stages in the system temp folder, so each run gives it a `TMPDIR` of its own
//   through the process environment. One `lungfish-ingest-*` folder sits there while the stand-in holds its
//   output, and the folder is empty once the cancel ends.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier. It needs no real tool.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class FastqIngestCancelReplayTests: XCTestCase {
    /// Past the grace, for the hop of the cancel to the transport and the drain of the output.
    static let margin: Duration = .seconds(2)

    private static let reads = "@read1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n@read2\nTTGGCCAATTGG\n+\nIIIIIIIIIIII\n"

    /// What one cancel through the transport observed.
    private struct Cancelled {
        let outcome: Result<CLISubprocessTransport.Result, Error>
        let status: Int32?
        let elapsed: Duration
        let tree: [Int32]
        /// The system temp folder the command was given, and what it held while the stand-in clumpify ran.
        let systemTemp: URL
        let staged: [String]
    }

    /// Runs `fastq ingest` on `input` through the transport the L6 runner uses, against a stand-in
    /// clumpify under `root`, cancels once the clumpify holds a half-written output, and returns
    /// what the cancel observed.
    private func cancelIngest(of input: URL, in root: URL) async throws -> Cancelled {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
        // A stand-in for the managed clumpify.sh, in a conda root of this test's own. It records its
        // pid, writes half an output where `out=` says, and waits.
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let script = condaRoot.appendingPathComponent("envs/bbtools/bin/clumpify.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo $$ > "$CLUMPIFY_PID_FILE"
        for argument in "$@"; do
          case "$argument" in
            out=*) printf 'half' > "${argument#out=}" ;;
          esac
        done
        exec /bin/sleep 300
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("clumpify.pid")
        // 2.11 S8. The command stages in the system temp folder it inherits, here a folder of this test's own.
        let systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)
        let previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", systemTemp.path, 1)
        defer { if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") } }

        // The route's transport, as the L6 runner builds it: a real grace, events on standard output.
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let environment = [
            "LUNGFISH_CONDA_ROOT": condaRoot.path,
            "LUNGFISH_STORAGE_ROOT": root.appendingPathComponent("storage", isDirectory: true).path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            "CFFIXED_USER_HOME": home.path,
            "CLUMPIFY_PID_FILE": pidFile.path,
        ]
        let arguments = try FASTQIngestionService.inPlaceIngestionCLIArguments(url: input)
        let run = Task {
            try await transport.run(
                arguments: arguments,
                terminationGracePeriod: CLIProcessLauncher.operationGrace,
                environmentAdditions: environment,
                isCancelled: { false },
                onEvent: { _ in }
            )
        }

        // The stand-in runs, so the command is listening for SIGTERM and its output is half written.
        guard await CLISIGTERMHarness.waitForProcessID(in: pidFile) != nil else {
            transport.cancel()
            _ = await run.result
            XCTFail("The command never started the stand-in clumpify")
            throw CancellationError()
        }
        let staged = ((try? FileManager.default.contentsOfDirectory(atPath: systemTemp.path)) ?? []).sorted()
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
        let cliPID = try XCTUnwrap(tree.min(), "the command and its tree run")
        let watch = try XCTUnwrap(ChildExitWatch(pid: cliPID), "cannot watch \(tree)")
        let sent = ContinuousClock.now
        transport.cancel()
        let outcome = await run.result
        let elapsed = ContinuousClock.now - sent
        return Cancelled(
            outcome: outcome, status: watch.exitCode(timeoutSeconds: 5), elapsed: elapsed, tree: tree,
            systemTemp: systemTemp, staged: staged
        )
    }

    private func assertCancelledInsideTheGrace(_ cancelled: Cancelled) async {
        XCTAssertThrowsError(try cancelled.outcome.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        CLISIGTERMHarness.assertCancelledExit(
            status: cancelled.status,
            elapsed: cancelled.elapsed,
            within: CLIProcessLauncher.operationGrace + Self.margin
        )
        await CLISIGTERMHarness.assertNoProcessLeft(cancelled.tree)
        // The stage sat in the system temp folder the command inherited, and the cancel removed it.
        XCTAssertEqual(cancelled.staged.count, 1, "the command stages in the system temp folder it inherits: \(cancelled.staged)")
        XCTAssertTrue(cancelled.staged.allSatisfy { $0.hasPrefix("lungfish-ingest-") }, "\(cancelled.staged)")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cancelled.systemTemp.path), [],
            "a cancelled ingest leaves no staging folder"
        )
    }

    /// The SHA-256 of every entry directly in `folder` by name, with a marker for a folder.
    private func digests(in folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            result[name] = isDirectory.boolValue ? "folder" : try ProvenanceFileHasher.sha256(of: url)
        }
        return result
    }

    func testACancelThroughTheTransportExits125RecordsTheCancelAndLeavesTheOriginal() async throws {
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-transport-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let recordURL = folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)

        await assertCancelledInsideTheGrace(try await cancelIngest(of: input, in: root))

        CLISIGTERMHarness.assertRecordCancelled {
            try ProvenanceEnvelopeReader.load(fromSidecar: recordURL)?.status.rawValue
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            [ProvenanceRecorder.provenanceFilename, "SRR9_1.fastq"],
            "the original and the cancelled record remain, with no output, sidecar or hidden folder"
        )
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), Self.reads, "the original is as it was")
    }

    /// Ruling on M3, section 5. A bundle that holds the import record is the file's history, so the
    /// cancel writes nothing there. Every file keeps its digest and nothing is staged beside the input.
    func testACancelWhereARecordStandsChangesNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-transport-record-stands")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let imported = try ProvenanceRunBuilder(
            workflowName: "FASTQ Import", workflowVersion: "1", toolName: "lungfish-cli", toolVersion: "1"
        )
        .argv([CLICommandIdentity.executableName, "import", "fastq"])
        .output(input, format: .fastq, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 11))
        try ProvenanceWriter(signingProvider: nil).write(imported, to: folder)
        let before = try digests(in: folder)
        XCTAssertNotNil(before[ProvenanceRecorder.provenanceFilename], "a record stands in the folder")

        await assertCancelledInsideTheGrace(try await cancelIngest(of: input, in: root))

        XCTAssertEqual(try digests(in: folder), before, "every file keeps its digest, and nothing is staged beside the input")
    }

    /// Ruling on M3, section 5. The handler that writes the cancelled record runs while every core
    /// is busy, and it still finishes inside the grace.
    func testACancelWithEveryCoreBusyStillExits125InsideTheGrace() async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")

        let root = try TestTempDirectory.make(prefix: "fastq-ingest-transport-busy")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)

        await assertCancelledInsideTheGrace(try await cancelIngest(of: input, in: root))

        CLISIGTERMHarness.assertRecordCancelled {
            try ProvenanceEnvelopeReader.load(
                fromSidecar: folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            )?.status.rawValue
        }
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), Self.reads, "the original is as it was")
    }

    // MARK: - import rnaseq (Phase 5.4 lane RS-GLUE)
    //
    // The Import Center's two RNA-seq cards run `lungfish-cli import rnaseq` through `AppDelegate.startRNASeqImport`, the
    // runner every FASTQ import uses. The cases below run the built command. The inputs sit inside the project, since a
    // command that names an input outside it does not replay (BACKLOG RNASEQ-IMPORT-EXTERNAL-NO-REPLAY).
    //
    // - Parity. The sheet's argv runs on side A as a script runs it, on side C as the card runs it, and on side C' as the
    //   command side C's row recorded. The three give one output tree and one record with the clocks masked.
    // - Cancel. The row's Cancel stops the command in its read of 40 large salmon folders, and the project holds no
    //   result and no stage.
    // - Refusal. A sheet whose sample ids differ from the folders is refused in the command's words, on the row and in
    //   the sheet (X5).

    private enum RNASeqCard: String {
        case salmon = "salmon-c1"
        case cellRanger = "cellranger-pbmc_1k_v3"
    }

    @MainActor
    private final class RNASeqRunBox {
        var outcome: RNASeqImportOutcome?
        var operationID: UUID?
    }

    private func rnaSeqCLI() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
        // The app's runner finds the command as the app does, through this variable.
        let prior = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        addTeardownBlock { if let prior { setenv("LUNGFISH_CLI_PATH", prior, 1) } else { unsetenv("LUNGFISH_CLI_PATH") } }
        return cli
    }

    nonisolated private static func writeRNASeqProject(_ cards: [RNASeqCard], in root: URL) throws {
        let inputs = root.appendingPathComponent("Project.lungfish/Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        for card in cards {
            try FileManager.default.copyItem(
                at: RNASeqFixtures.root.appendingPathComponent(card.rawValue, isDirectory: true),
                to: inputs.appendingPathComponent(card.rawValue, isDirectory: true)
            )
        }
    }

    /// The sheet of a card with the values a person would give, over the fixture copied into `root`'s project.
    private static func rnaSeqModel(_ card: RNASeqCard, in root: URL, sampleSheet: URL? = nil) -> RNASeqImportSheetModel {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputs = project.appendingPathComponent("Inputs", isDirectory: true)
        let model: RNASeqImportSheetModel
        switch card {
        case .salmon:
            let folders = RNASeqFixtures.salmonRunIDs.map { inputs.appendingPathComponent("salmon-c1/\($0)", isDirectory: true) }
            model = RNASeqImportSheetModel(kind: .bulk, inputs: folders, projectURL: project)
            model.name = "SEQC pair"
        case .cellRanger:
            let folder = inputs.appendingPathComponent("cellranger-pbmc_1k_v3", isDirectory: true)
            model = RNASeqImportSheetModel(kind: .singleCell, inputs: [folder], projectURL: project)
            model.name = "pbmc 1k"
        }
        model.sampleSheet = sampleSheet
        return model
    }

    /// Side C. The card's row and run, on the app's runner, and the command the row recorded.
    private func rnaSeqSideC(_ request: RNASeqImportRequest) async -> RouteParitySideOutcome {
        var operationID: UUID?
        let outcome: RNASeqImportOutcome = await withCheckedContinuation { continuation in
            operationID = AppDelegate.startRNASeqImport(request: request, routeContext: nil) { continuation.resume(returning: $0) }
            if operationID == nil { continuation.resume(returning: .refused("the row was refused")) }
        }
        let command = OperationCenter.shared.items.first { $0.id == operationID }?.cliCommand
        switch outcome {
        case .imported(let bundle):
            return RouteParitySideOutcome(end: .completed, detail: "Imported \(bundle.lastPathComponent)", recordedCommand: command)
        case .refused(let words):
            return RouteParitySideOutcome(end: .failed, detail: words, recordedCommand: command)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: "cancelled", recordedCommand: command)
        }
    }

    private func assertRNASeqCardParity(_ card: RNASeqCard, file: StaticString = #filePath, line: UInt = #line) async throws {
        await OperationCenter.useTemporaryFailureReportsForTesting()
        let cli = try rnaSeqCLI()
        let scratch = try TestTempDirectory.make(prefix: "rnaseq-card-parity")
        defer { TestTempDirectory.cleanup(scratch) }
        // The three sides run the command at three seconds, and the record states its second in `createdAt`. That one
        // wall-clock key of rnaseq-result.json is masked and nothing else is, and the difference is never declared
        // (`OutputEquivalence.MaskPolicy.rnaSeqImport` below).
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, masks: .rnaSeqImport, replayTimeout: .seconds(120))
        let result = try await harness.assertParity(
            card.rawValue,
            declared: [],
            in: scratch.appendingPathComponent(card.rawValue, isDirectory: true),
            fixture: { root in try Self.writeRNASeqProject([card], in: root) },
            sideA: { root in
                let request = try XCTUnwrap(Self.rnaSeqModel(card, in: root).request())
                let run = await RouteParityHarness.runCLI(cli, arguments: request.arguments, timeout: .seconds(120))
                return RouteParitySideOutcome(end: run.end, detail: run.detail)
            },
            sideC: { root in
                let request = try XCTUnwrap(Self.rnaSeqModel(card, in: root).request())
                return await self.rnaSeqSideC(request)
            },
            file: file,
            line: line
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)", file: file, line: line)
            let analyses = run.root.appendingPathComponent("Project.lungfish/Analyses", isDirectory: true)
            let made = (try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? []
            XCTAssertEqual(made.count, 1, "side \(run.side) made one result: \(made)", file: file, line: line)
            XCTAssertTrue(made.allSatisfy { $0.hasSuffix(".lungfishrnaseq") }, "\(made)", file: file, line: line)
        }
    }

    func testTheBulkCardImportsWhatTheCLIImportsFromTheSalmonFolders() async throws {
        try await assertRNASeqCardParity(.salmon)
    }

    func testTheSingleCellCardImportsWhatTheCLIImportsFromTheCellRangerFolder() async throws {
        try await assertRNASeqCardParity(.cellRanger)
    }

    /// 40 salmon folders of 50,000 transcripts each, so the command is still reading them when the cancel lands.
    nonisolated private static func writeLargeSalmonFolders(count: Int, transcripts: Int, in root: URL) throws -> [URL] {
        var quant = "Name\tLength\tEffectiveLength\tTPM\tNumReads\n"
        for index in 0..<transcripts { quant += "T\(index)\t1000\t850.5\t1.25\t\(index % 97).5\n" }
        let data = Data(quant.utf8)
        let fixture = RNASeqFixtures.salmonRun("SRR896663")
        return try (0..<count).map { index in
            let folder = root.appendingPathComponent("held\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("aux_info"), withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("quant.sf"))
            for file in ["cmd_info.json", "lib_format_counts.json", "aux_info/meta_info.json"] {
                try FileManager.default.copyItem(at: fixture.appendingPathComponent(file), to: folder.appendingPathComponent(file))
            }
            return folder
        }
    }

    /// The row's Cancel stops the command through the app's runner. The row reads Cancelled, the outcome is a cancel,
    /// and the project holds no result and no stage in its Analyses folder.
    func testACancelOfTheRNASeqRowLeavesNoResultAndNoStage() async throws {
        await OperationCenter.useTemporaryFailureReportsForTesting()
        _ = try rnaSeqCLI()
        let root = try TestTempDirectory.make(prefix: "rnaseq-card-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folders = try Self.writeLargeSalmonFolders(count: 40, transcripts: 50_000, in: root)
        let model = RNASeqImportSheetModel(kind: .bulk, inputs: folders, projectURL: project)
        model.name = "held"
        let request = try XCTUnwrap(model.request())

        let box = RNASeqRunBox()
        box.operationID = AppDelegate.startRNASeqImport(request: request, routeContext: nil) { box.outcome = $0 }
        let operationID = try XCTUnwrap(box.operationID)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let reached = await CLISIGTERMHarness.waitForFile(analyses)
        XCTAssertTrue(reached, "the command never made the Analyses folder")
        OperationCenter.shared.cancel(id: operationID)
        let ended = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) { box.outcome != nil }

        XCTAssertTrue(ended, "the run ended after the cancel")
        XCTAssertEqual(box.outcome, .cancelled)
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == operationID }?.state, .cancelled)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? ["missing"], [], "no result and no stage")
        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue, "cancelled")
    }

    /// X5. A sheet whose sample ids differ from the folders is refused, and the refusal shows the command's own words on
    /// the Operations row and in the sheet, which stays open with its values so a person can change them and run again.
    func testASheetWhoseIdsDifferFromTheFoldersIsRefusedInTheCommandsWordsOnTheRowAndInTheSheet() async throws {
        await OperationCenter.useTemporaryFailureReportsForTesting()
        _ = try rnaSeqCLI()
        let root = try TestTempDirectory.make(prefix: "rnaseq-card-refused")
        defer { TestTempDirectory.cleanup(root) }
        try Self.writeRNASeqProject([.salmon], in: root)
        let sheet = root.appendingPathComponent("sheet.tsv")
        try "sample\tgroup\nA\tx\nB\ty\n".write(to: sheet, atomically: true, encoding: .utf8)
        let model = Self.rnaSeqModel(.salmon, in: root, sampleSheet: sheet)
        let box = RNASeqRunBox()
        model.start = { request, completion in
            box.operationID = AppDelegate.startRNASeqImport(request: request, routeContext: nil, completion: completion)
            return box.operationID
        }

        model.importClicked()
        XCTAssertEqual(model.phase, .running)
        let refused = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) { model.failure != nil }

        XCTAssertTrue(refused, "the run ended in a refusal")
        let words = RNASeqImportError.sampleIDsDiffer(onlyInFiles: ["SRR896663", "SRR896743"], onlyInSheet: ["A", "B"]).errorDescription
        XCTAssertEqual(model.failure, words, "the sheet shows the command's words")
        XCTAssertTrue(model.failure?.contains("Only in the files: SRR896663, SRR896743. Only in the sheet: A, B.") == true)
        XCTAssertEqual(model.phase, .editing, "the sheet stays open, ready to run again")
        XCTAssertEqual(model.sampleSheet, sheet)
        let row = OperationCenter.shared.items.first { $0.id == box.operationID }
        XCTAssertEqual(row?.state, .failed)
        XCTAssertEqual(row?.detail, words, "the Operations row shows the command's words")
        let analyses = root.appendingPathComponent("Project.lungfish/Analyses", isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? [], [], "a refusal writes nothing")
    }
}

// MARK: - The clock of rnaseq-result.json (Phase 5.4 lane RS-GLUE)

extension OutputEquivalence.Masks {
    /// The second `import rnaseq` wrote its record, set to `<TIMESTAMP>` in the top-level `createdAt` of a
    /// `rnaseq-result.json` whose `kind` is `rnaseq-result`, and only when the value is an ISO 8601 date-time.
    ///
    /// Sides A, C and C' of a parity case run the same command at three different seconds, so no two records agree in
    /// that one key. It is a wall-clock time, which the Masks row of `docs/contracts/CLI-EQUIVALENCE.md` already masks
    /// ("Wall-clock times"), so this adds no row to that table (the manager's ruling on lane RS-GLUE, 2026-11-18). The
    /// same key in another document or one level down, a value that is no date-time, a record of another kind and every
    /// other value of the record are compared as written, and `MaskPolicy.standard` is not changed.
    static let rnaSeqResultCreatedAt = OutputEquivalence.Mask(name: "rnaSeqResultCreatedAt") { text, context in
        guard context.recordName == RNASeqResultManifest.filename,
              let data = text.data(using: .utf8),
              var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              record["kind"] as? String == RNASeqResultManifest.kindName,
              let stamp = record["createdAt"] as? String,
              ISO8601DateFormatter().date(from: stamp) != nil
        else { return text }
        record["createdAt"] = "<TIMESTAMP>"
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        ), let masked = String(data: encoded, encoding: .utf8) else { return text }
        return masked
    }
}

extension OutputEquivalence.MaskPolicy {
    /// The standard masks and the clock of `rnaseq-result.json` in payload text, which only the parity cases of
    /// `import rnaseq` ask for. A declared difference is never the answer to a clock.
    static var rnaSeqImport: OutputEquivalence.MaskPolicy {
        var policy = OutputEquivalence.MaskPolicy.standard
        policy.payloads.append(OutputEquivalence.Masks.rnaSeqResultCreatedAt)
        return policy
    }
}
