// CLIImportRunnerTests - Tests for CLI subprocess management actor
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

private final class CLIImportRunnerStringCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock {
            values.append(value)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { values }
    }
}

private final class CLIImportRunnerCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.withLock {
            completed = true
        }
    }

    func isCompleted() -> Bool {
        lock.withLock { completed }
    }

    func waitUntilCompleted(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCompleted() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return isCompleted()
    }
}

final class CLIImportRunnerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await OperationCenter.useTemporaryFailureReportsForTesting()
    }


    // MARK: - Events

    func testRunForwardsNoticeEventToOperationCenter() async throws {
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        try """
        #!/bin/sh
        echo '{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}'
        echo '{"event":"log","level":"warning","message":"Sample1 — Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads.","schemaVersion":2}'
        echo '{"event":"complete","outputs":["/project/Imports/Sample1.lungfishfastq"],"schemaVersion":2}'
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        defer {
            if let priorCLIPath {
                setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }

        let operationID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "FASTQ Import: Trim Galore notice test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await Self.finishAndClearOperation(operationID)
        }

        await CLIImportRunner().run(
            arguments: [],
            operationID: operationID,
            projectDirectory: tempDir,
            onBundleCreated: { _ in },
            onError: { _ in }
        )

        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == operationID }
        }
        XCTAssertTrue(item?.logEntries.contains {
            $0.level == .warning
                && $0.message == "Sample1 — Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads."
        } == true)
    }

    // MARK: - import rnaseq (Phase 5.4 lane RS-GLUE)

    func testBuildRNASeqImportArgumentsPutsEveryOptionAfterTheInputs() {
        let project = URL(fileURLWithPath: "/p")
        let folders = [URL(fileURLWithPath: "/p/Inputs/SRR1"), URL(fileURLWithPath: "/p/Inputs/SRR2")]
        XCTAssertEqual(
            CLIImportRunner.buildRNASeqImportArguments(
                inputs: folders, projectDirectory: project, name: "SEQC pair",
                samples: URL(fileURLWithPath: "/p/sheet.tsv"), tx2gene: URL(fileURLWithPath: "/p/t2g.tsv")
            ),
            ["import", "rnaseq", "/p/Inputs/SRR1", "/p/Inputs/SRR2", "--project", "/p", "--name", "SEQC pair",
             "--tx2gene", "/p/t2g.tsv", "--samples", "/p/sheet.tsv", "--format", "json"]
        )
        XCTAssertEqual(
            CLIImportRunner.buildRNASeqImportArguments(
                inputs: [URL(fileURLWithPath: "/p/counts.tsv")], projectDirectory: project, name: "counts", unit: "umis"
            ),
            ["import", "rnaseq", "/p/counts.tsv", "--project", "/p", "--name", "counts", "--unit", "umis", "--format", "json"]
        )
        XCTAssertEqual(
            CLIImportRunner.buildRNASeqImportArguments(
                inputs: [URL(fileURLWithPath: "/p/S1")], projectDirectory: project, name: "pbmc", genomes: ["hg19", "mm10"],
                referenceSet: URL(fileURLWithPath: "/p/set"), notHostBAMs: [("S1", URL(fileURLWithPath: "/p/a.bam"))]
            ),
            ["import", "rnaseq", "/p/S1", "--project", "/p", "--name", "pbmc", "--genome", "hg19", "--genome", "mm10",
             "--reference-set", "/p/set", "--not-host-bam", "S1=/p/a.bam", "--format", "json"]
        )
    }

    /// `begin` gets the FASTQ import's `OperationType` and a `cliCommand` that splits into the argv the run executes.
    @MainActor
    func testTheRNASeqRowNamesItsTypeAndRecordsTheArgvThatRuns() throws {
        let root = try makeTemporaryDirectory()
        let table = root.appendingPathComponent("counts.tsv")
        try "gene_id\tS1\nG1\t1\n".write(to: table, atomically: true, encoding: .utf8)
        let model = RNASeqImportSheetModel(kind: .bulk, inputs: [table], projectURL: root.appendingPathComponent("Project.lungfish"))
        model.unit = "estimated"
        let request = try XCTUnwrap(model.request())
        let reporter = RecordingOperationReporter()
        var launched: [UUID] = []

        let result = AppDelegate.beginRNASeqImportOperation(request: request, routeContext: nil, reporter: reporter) { launched.append($0) }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launched, [item.id])
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertEqual(item.title, "RNA-seq Import: counts")
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), request.arguments)
        _ = try RecordedCLICommand.parse(item.cliCommand)
        XCTAssertEqual(try RecordedCLICommand.parseScript(item.cliCommand).count, 1, "one command that the shipped parser accepts")
    }

    @MainActor
    func testTheRNASeqSheetAsksForWhatTheCommandNeedsAndNothingMore() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let table = root.appendingPathComponent("counts.tsv")
        try "gene_id\tS1\nG1\t1\n".write(to: table, atomically: true, encoding: .utf8)
        let folders = try ["SRR1", "SRR2", "S1/outs", "S2"].map { name -> URL in
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let bulkTable = RNASeqImportSheetModel(kind: .bulk, inputs: [table], projectURL: project)
        XCTAssertEqual(bulkTable.missingChoice, "A count table states no unit. Choose the unit its numbers are in.")
        XCTAssertNil(bulkTable.request())
        bulkTable.unit = "reads"
        XCTAssertNil(bulkTable.missingChoice)
        XCTAssertEqual(RNASeqImportSheetModel.unitChoices.map(\.id), ["reads", "pairs", "umis", "estimated"])
        XCTAssertTrue(RNASeqImportSheetModel.unitChoices.allSatisfy { RNASeqResultManifest.CountEntry.Unit(rawValue: $0.id) != nil })
        bulkTable.name = "   "
        XCTAssertEqual(bulkTable.missingChoice, "Give the result a name.")

        XCTAssertNil(RNASeqImportSheetModel(kind: .bulk, inputs: Array(folders.prefix(2)), projectURL: project).missingChoice)
        // A table is imported on its own. A table with folders, or two tables, cannot be mended in the sheet (RS-GLUE-UX SF-1).
        let tableOnItsOwn = "A count table is imported on its own. Cancel, then choose one table, or choose only salmon folders."
        let table2 = root.appendingPathComponent("counts2.tsv")
        try "gene_id\tS2\nG1\t1\n".write(to: table2, atomically: true, encoding: .utf8)
        XCTAssertEqual(RNASeqImportSheetModel(kind: .bulk, inputs: [folders[0], table], projectURL: project).missingChoice, tableOnItsOwn)
        XCTAssertEqual(RNASeqImportSheetModel(kind: .bulk, inputs: [table, table2], projectURL: project).missingChoice, tableOnItsOwn)
        // Two folders of one name are refused by the command, so the sheet says so before Import is offered.
        let twins = try ["A/quant", "B/quant"].map { name -> URL in
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let twinSheet = RNASeqImportSheetModel(kind: .bulk, inputs: twins, projectURL: project)
        XCTAssertEqual(
            twinSheet.missingChoice,
            "Two folders are named quant, and a folder's name is its sample's name. Cancel, then rename one of them or choose others."
        )
        XCTAssertNil(twinSheet.request())
        // The single-cell sheet takes the folders the command reads as Cell Ranger or STARsolo, and no other.
        XCTAssertEqual(
            RNASeqImportSheetModel(kind: .singleCell, inputs: [folders[0]], projectURL: project).missingChoice,
            "SRR1 is not a Cell Ranger or STARsolo folder. Cancel, then choose the outs folder of a Cell Ranger run, or the folder of a STARsolo run that holds Solo.out."
        )
        for marker in ["S1/outs/filtered_feature_bc_matrix", "S2/Solo.out"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(marker, isDirectory: true), withIntermediateDirectories: true)
        }

        let cells = RNASeqImportSheetModel(kind: .singleCell, inputs: Array(folders.suffix(2)), projectURL: project)
        XCTAssertNil(cells.missingChoice, "a single-cell import needs no set")
        cells.referenceSet = root.appendingPathComponent("set")
        XCTAssertEqual(cells.missingChoice, "Choose the sorted, indexed BAM of S1, or remove the reference set.")
        cells.notHostBAMs[0] = root.appendingPathComponent("a.bam")
        XCTAssertEqual(cells.missingChoice, "Choose the sorted, indexed BAM of S2, or remove the reference set.")
        cells.notHostBAMs[1] = root.appendingPathComponent("b.bam")
        XCTAssertNil(cells.missingChoice)
    }

    @MainActor
    func testTheRNASeqSheetSaysWhenAnInputIsOutsideTheProject() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inside = project.appendingPathComponent("Inputs/SRR1", isDirectory: true)
        let outside = root.appendingPathComponent("scratch/SRR2", isDirectory: true)
        for folder in [inside, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        XCTAssertNil(RNASeqImportSheetModel(kind: .bulk, inputs: [inside], projectURL: project).outsideProjectNote)
        let note = try XCTUnwrap(RNASeqImportSheetModel(kind: .bulk, inputs: [inside, outside], projectURL: project).outsideProjectNote)
        XCTAssertTrue((note.range(of: "Outside this project: SRR2.") != nil), note)
        XCTAssertTrue((note.range(of: "<external>/<name>") != nil) && (note.range(of: "does not replay") != nil), note)
    }

    /// A sample sheet whose run column names the folders gives them its sample names, and the command looks each BAM up by
    /// that name, so the BAM rows of the single-cell sheet carry the sheet's names (RS-GLUE-UX SF-2).
    @MainActor
    func testTheRNASeqBAMRowsUseTheSampleNamesOfASheetThatRenamesTheFolders() throws {
        let root = try makeTemporaryDirectory()
        let folder = root.appendingPathComponent("S1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("outs/filtered_feature_bc_matrix", isDirectory: true), withIntermediateDirectories: true)
        let sheet = root.appendingPathComponent("sheet.tsv")
        try "sample\trun\nPatient1\tS1\n".write(to: sheet, atomically: true, encoding: .utf8)
        let model = RNASeqImportSheetModel(kind: .singleCell, inputs: [folder], projectURL: root.appendingPathComponent("Project.lungfish"))
        XCTAssertEqual(model.sampleIDs, ["S1"])
        model.sampleSheet = sheet
        XCTAssertEqual(model.sampleIDs, ["Patient1"])
        model.referenceSet = root.appendingPathComponent("set")
        XCTAssertEqual(model.missingChoice, "Choose the sorted, indexed BAM of Patient1, or remove the reference set.")
        let bam = root.appendingPathComponent("a.bam")
        model.notHostBAMs[0] = bam
        let request = try XCTUnwrap(model.request())
        let named = "Patient1=" + bam.path
        XCTAssertTrue(request.arguments.contains(named), "the command looks the BAM up by the sheet's sample name: \(request.arguments)")
        // A sheet that does not name the folders leaves their own names, and the command refuses it in its own words.
        let other = root.appendingPathComponent("other.tsv")
        try "sample\trun\nPatient1\tZZ\n".write(to: other, atomically: true, encoding: .utf8)
        model.sampleSheet = other
        XCTAssertEqual(model.sampleIDs, ["S1"])
    }

    /// A refusal keeps the command's words and adds the way back. A cancel is not an error and carries no way back
    /// (RS-GLUE-UX SF-3).
    @MainActor
    func testTheRNASeqSheetKeepsTheCommandsWordsAndAddsTheWayBackOnlyToARefusal() {
        let model = RNASeqImportSheetModel(kind: .bulk, inputs: [], projectURL: URL(fileURLWithPath: "/p"))
        let words = "The sample quant appears twice. Each sample is one folder or one column."
        model.finish(.refused(words))
        XCTAssertEqual(model.failure, words, "the command's words stay as written")
        XCTAssertEqual(model.hint, RNASeqImportWords.afterARefusal)
        model.finish(.cancelled)
        XCTAssertEqual(model.failure, "The import was cancelled. Nothing was imported.")
        XCTAssertNil(model.hint, "a cancel is not a refusal")
        model.finish(.refused(words))
        model.finish(.imported(URL(fileURLWithPath: "/p/Analyses/x.lungfishrnaseq")))
        XCTAssertNil(model.failure)
        XCTAssertNil(model.hint)
    }

    /// The sheet names a single-cell sample as the command does, for `outs/` and for the run folder above it.
    func testTheRNASeqSheetNamesASingleCellSampleAsTheReaderDoes() throws {
        let run = RNASeqFixtures.root.appendingPathComponent("cellranger-pbmc_1k_v3", isDirectory: true)
        for folder in [run, run.appendingPathComponent("outs", isDirectory: true)] {
            XCTAssertEqual(
                RNASeqImportSheetModel.sampleID(ofSingleCellFolder: folder),
                try SingleCellFolderReader.read(folder: folder).sample
            )
        }
    }

    @MainActor
    func testTheRNASeqCardsOpenTheirPanelsAndSayWhereCountingFASTQFilesStarts() throws {
        let model = ImportCenterViewModel()
        let bulk = try XCTUnwrap(model.allCards.first { $0.id == "rnaseq-counts" })
        let cells = try XCTUnwrap(model.allCards.first { $0.id == "rnaseq-single-cell" })
        guard case .openPanel(let bulkPanel, let bulkAction) = bulk.importKind,
              case .openPanel(let cellPanel, let cellAction) = cells.importKind else {
            return XCTFail("both cards ask for their inputs in an open panel")
        }
        XCTAssertEqual(bulkAction, .rnaseqCounts)
        XCTAssertEqual(cellAction, .rnaseqSingleCell)
        XCTAssertTrue(bulkPanel.canChooseFiles && bulkPanel.canChooseDirectories && bulkPanel.allowsMultipleSelection)
        XCTAssertFalse(cellPanel.canChooseFiles)
        XCTAssertTrue(cellPanel.canChooseDirectories && cellPanel.allowsMultipleSelection)
        // The cards name what they import and where counting FASTQ files starts (focus group 2026-11-26). The words on
        // inputs outside the project moved to the two sheets.
        XCTAssertEqual(bulk.title, "Existing Bulk RNA-seq Counts")
        XCTAssertEqual(cells.title, "Existing Single-cell Counts")
        XCTAssertNotNil(bulk.description.range(of: "import them as Sequencing Read Files, then use Tools > RNA-seq > "
            + FASTQOperationToolID.rnaSeqQuant.title), bulk.description)
        XCTAssertTrue(model.allCards.contains { $0.title == "Sequencing Read Files" })
        XCTAssertNotNil(cells.description.range(of: "use Single-cell Plan for a Linux Machine"), cells.description)
        XCTAssertTrue(model.allCards.contains { $0.title == "Single-cell Plan for a Linux Machine" })
        XCTAssertNotNil(RNASeqImportWords.externalInputs.range(of: "<external>/<name>"))
        for card in [bulk, cells] {
            XCTAssertLessThanOrEqual(card.description.count, 190, "the card shows three lines of its description (ImportCenterView.swift:217)")
            XCTAssertEqual(card.tab, .sequencingReads)
        }
        XCTAssertEqual(model.historyLabel(for: .rnaseqCounts), "RNA-seq Counts")
        XCTAssertEqual(model.historyLabel(for: .rnaseqSingleCell), "Single-cell Counts")
        XCTAssertFalse(model.panelMessage(for: .rnaseqCounts).isEmpty)
        XCTAssertFalse(model.panelMessage(for: .rnaseqSingleCell).isEmpty)
    }

    func testTheRNASeqRowEndsAsTheRunnerReportedIt() {
        let bundle = URL(fileURLWithPath: "/p/Analyses/x.lungfishrnaseq")
        XCTAssertEqual(AppDelegate.rnaSeqImportEnd(RNASeqImportSeen(bundles: [bundle])), .completed(bundle))
        XCTAssertEqual(AppDelegate.rnaSeqImportEnd(RNASeqImportSeen(error: "Import cancelled")), .cancelled)
        XCTAssertEqual(AppDelegate.rnaSeqImportEnd(RNASeqImportSeen(error: "Import cancelled before it started")), .cancelled)
        XCTAssertEqual(AppDelegate.rnaSeqImportEnd(RNASeqImportSeen(error: "Input not found: /x")), .failedByRunner("Input not found: /x"))
        XCTAssertEqual(
            AppDelegate.rnaSeqImportEnd(RNASeqImportSeen()),
            .noBundle("The import finished without naming the result it made.")
        )
    }

    /// The adopt card's row (Phase 5.4 lane EX-APP) ends as the runner reported it. A run with no error ends in the result
    /// the command named, or in a passed check for `--dry-run`, which names none. The two cancel messages of
    /// `CLIImportRunner.run` end it as a cancel, and any other message is the command's own words.
    func testTheRNASeqAdoptEndsInTheResultACheckOrTheCommandsWords() {
        let bundle = URL(fileURLWithPath: "/data/Project.lungfish/Analyses/S1.lungfishrnaseq")
        XCTAssertEqual(AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(bundles: [bundle]), dryRun: false), .adopted(bundle))
        XCTAssertEqual(AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(), dryRun: true), .checked, "a dry run names no result")
        XCTAssertEqual(AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(error: "Import cancelled"), dryRun: false), .cancelled)
        XCTAssertEqual(AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(error: "Import cancelled before it started"), dryRun: false), .cancelled)
        XCTAssertEqual(
            AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(error: "S1 was refused."), dryRun: true), .refused("S1 was refused.")
        )
        XCTAssertEqual(
            AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(), dryRun: false),
            .refused("The adopt finished without naming the result it made.")
        )
    }

    // MARK: - The clock of rnaseq-result.json in the parity cases
    //
    // Sides A, C and C' of the parity cases in FastqIngestCancelReplayTests run `import rnaseq` at three different seconds,
    // and the record states its second in `createdAt`. The cases mask that one key of that one file, a wall-clock time
    // that the Masks row of docs/contracts/CLI-EQUIVALENCE.md already masks. These hold what the mask hides and what it
    // leaves as written.

    private static func rnaSeqResultText(
        kind: String = RNASeqResultManifest.kindName, name: String = "SEQC pair", createdAt: String? = "2026-11-18T18:49:00Z",
        originTime: String? = nil
    ) -> String {
        var lines = ["{", "  \"schemaVersion\" : 1,", "  \"kind\" : \"\(kind)\",", "  \"name\" : \"\(name)\","]
        if let createdAt { lines.append("  \"createdAt\" : \"\(createdAt)\",") }
        let nested = originTime.map { ", \"createdAt\" : \"\($0)\"" } ?? ""
        lines += ["  \"origin\" : { \"kind\" : \"imported\"\(nested) },", "  \"notHost\" : []", "}"]
        return lines.joined(separator: "\n")
    }

    private static func maskedRNASeqResult(_ text: String, named file: String = RNASeqResultManifest.filename) -> String {
        let context = OutputEquivalence.MaskContext(
            rootA: URL(fileURLWithPath: "/a", isDirectory: true), rootB: URL(fileURLWithPath: "/b", isDirectory: true), recordName: file
        )
        return OutputEquivalence.Masks.rnaSeqResultCreatedAt(text, context: context)
    }

    func testTheRNASeqClockMaskHidesTheCreatedAtOfTheResultRecordAndNothingElse() {
        let first = Self.maskedRNASeqResult(Self.rnaSeqResultText(createdAt: "2026-11-18T18:49:00Z"))
        let second = Self.maskedRNASeqResult(Self.rnaSeqResultText(createdAt: "2026-11-18T18:49:01Z"))
        XCTAssertEqual(first, second, "two seconds of one import read the same")
        XCTAssertTrue((first.range(of: "\"createdAt\" : \"<TIMESTAMP>\"") != nil), first)
        XCTAssertNotEqual(first, Self.maskedRNASeqResult(Self.rnaSeqResultText(name: "another")), "every other value is compared as written")
        let both = Self.maskedRNASeqResult(Self.rnaSeqResultText(originTime: "2026-11-18T18:49:00Z"))
        XCTAssertTrue((both.range(of: "\"createdAt\" : \"<TIMESTAMP>\"") != nil), "the top-level time is masked")
        XCTAssertTrue((both.range(of: "\"createdAt\" : \"2026-11-18T18:49:00Z\"") != nil), "a time one level down stays beside it")
    }

    func testTheRNASeqClockMaskLeavesAnythingThatIsNotThatClockAsWritten() {
        let record = Self.rnaSeqResultText()
        XCTAssertEqual(Self.maskedRNASeqResult(record, named: "esviritu-result.json"), record, "another file")
        XCTAssertEqual(Self.maskedRNASeqResult(record, named: "rnaseq-result.json.bak"), record, "another file")
        let other = Self.rnaSeqResultText(kind: "classification-result")
        XCTAssertEqual(Self.maskedRNASeqResult(other), other, "another kind of record")
        for value in ["", "yesterday", "2026-11-18", "18:49:00"] {
            let text = Self.rnaSeqResultText(createdAt: value)
            XCTAssertEqual(Self.maskedRNASeqResult(text), text, "\"\(value)\" is no date-time")
        }
        let nested = Self.rnaSeqResultText(createdAt: nil, originTime: "2026-11-18T18:49:00Z")
        XCTAssertEqual(Self.maskedRNASeqResult(nested), nested, "a time one level down, with none at the top")
        let notJSON = "createdAt: 2026-11-18T18:49:00Z"
        XCTAssertEqual(Self.maskedRNASeqResult(notJSON), notJSON, "text that is no JSON")
    }

    /// The parity cases compare whole folders, so this runs the comparison itself on two folders that differ in the clock
    /// alone. The standard masks leave it, the policy of the parity cases hides it, and a changed name still differs.
    func testTheRNASeqParityPolicyHidesTheClockAndNoOtherDifference() throws {
        let root = try makeTemporaryDirectory()
        func side(_ folder: String, _ text: String) throws -> URL {
            let side = root.appendingPathComponent(folder, isDirectory: true)
            let result = side.appendingPathComponent("Project.lungfish/Analyses/SEQC_pair.lungfishrnaseq", isDirectory: true)
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            try text.write(to: result.appendingPathComponent(RNASeqResultManifest.filename), atomically: true, encoding: .utf8)
            return side
        }
        let a = try side("a", Self.rnaSeqResultText(createdAt: "2026-11-18T18:49:00Z"))
        let b = try side("b", Self.rnaSeqResultText(createdAt: "2026-11-18T18:49:01Z"))
        let renamed = try side("c", Self.rnaSeqResultText(name: "another", createdAt: "2026-11-18T18:49:01Z"))

        XCTAssertFalse(try OutputEquivalence.differences(a, b, kind: .bundle).isEmpty, "the standard masks leave the second as it is")
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle, masks: .rnaSeqImport), [])
        XCTAssertFalse(
            try OutputEquivalence.differences(a, renamed, kind: .bundle, masks: .rnaSeqImport).isEmpty,
            "a changed name still differs under the parity policy"
        )
        let standard = OutputEquivalence.MaskPolicy.standard
        let policy = OutputEquivalence.MaskPolicy.rnaSeqImport
        XCTAssertEqual(policy.payloads.map(\.name), standard.payloads.map(\.name) + ["rnaSeqResultCreatedAt"])
        XCTAssertEqual(policy.provenance.map(\.name), standard.provenance.map(\.name))
        XCTAssertEqual(policy.records.map(\.name), standard.records.map(\.name))
        XCTAssertEqual(policy.names.map(\.name), standard.names.map(\.name))
    }

    /// A refusal of the command reaches the Operations row and the outcome in the command's own words (X5). The
    /// stand-in prints what `lungfish-cli import rnaseq` prints when the sheet's ids differ from the folders, and the
    /// real command's words are held in `FastqIngestCancelReplayTests`.
    func testARefusalOfTheRNASeqCommandReachesTheRowInItsOwnWords() async throws {
        let tempDir = try makeTemporaryDirectory()
        let words = "The sample ids of the files and the sample sheet differ. Only in the files: SRR1, SRR2. Only in the sheet: A, B."
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        try """
        #!/bin/sh
        echo '{"event":"start","message":"Starting","progress":0,"schemaVersion":2}'
        echo '{"event":"failed","message":"\(words)","schemaVersion":2}'
        exit 5
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        defer { if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") } }
        let operationID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "RNA-seq Import: refused", detail: "Starting", operationType: .ingestion, cliCommand: nil
            ).rowID
        }
        addTeardownBlock { await Self.finishAndClearOperation(operationID) }

        let outcome = await AppDelegate.runRNASeqImport(
            arguments: ["import", "rnaseq"], operationID: operationID, projectDirectory: tempDir, runner: CLIImportRunner()
        )

        XCTAssertEqual(outcome, .refused(words))
        let item = await MainActor.run { OperationCenter.shared.items.first { $0.id == operationID } }
        XCTAssertEqual(item?.state, .failed)
        XCTAssertEqual(item?.detail, words)
    }

    // MARK: - Argument Building Tests

    func testBuildCLIArgumentsPairedEnd() {
        let r1 = URL(fileURLWithPath: "/data/reads_R1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/reads_R2.fastq.gz")
        let project = URL(fileURLWithPath: "/project")

        let args = CLIImportRunner.buildCLIArguments(
            r1: r1,
            r2: r2,
            projectDirectory: project,
            platform: "illumina",
            recipeName: "vsp2",
            qualityBinning: "illumina4",
            optimizeStorage: true,
            compressionLevel: "balanced"
        )

        XCTAssertTrue(args.starts(with: ["import", "fastq", r1.path]))
        XCTAssertTrue(args.contains(r2.path))
        XCTAssertTrue(args.contains("--project"))
        XCTAssertTrue(args.contains(project.path))
        XCTAssertTrue(args.contains("--platform"))
        XCTAssertTrue(args.contains("illumina"))
        XCTAssertTrue(args.contains("--recipe"))
        XCTAssertTrue(args.contains("vsp2"))
        XCTAssertTrue(args.contains("--quality-binning"))
        XCTAssertTrue(args.contains("--format"))
        XCTAssertTrue(args.contains("json"))
        // --force must never be passed unless the caller explicitly
        // opts in (i.e. the user chose Replace in the duplicate dialog).
        XCTAssertFalse(args.contains("--force"))
        XCTAssertTrue(args.contains("--compression"))
        XCTAssertTrue(args.contains("balanced"))
        XCTAssertTrue(args.contains("illumina4"))
        XCTAssertFalse(args.contains("--no-optimize-storage"))
    }

    func testBuildCLIArgumentsSingleEndNoRecipe() {
        let r1 = URL(fileURLWithPath: "/data/reads.fastq.gz")
        let project = URL(fileURLWithPath: "/project")

        let args = CLIImportRunner.buildCLIArguments(
            r1: r1,
            r2: nil,
            projectDirectory: project,
            platform: "nanopore",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast"
        )

        XCTAssertTrue(args.starts(with: ["import", "fastq", r1.path]))
        XCTAssertFalse(args.contains("--recipe"))
        XCTAssertTrue(args.contains("--no-optimize-storage"))
        XCTAssertTrue(args.contains("none"))
        XCTAssertTrue(args.contains("--format"))
        XCTAssertTrue(args.contains("json"))
        // --force must never be passed unless the caller explicitly
        // opts in (i.e. the user chose Replace in the duplicate dialog).
        XCTAssertFalse(args.contains("--force"))
        XCTAssertTrue(args.contains("--compression"))
        XCTAssertTrue(args.contains("fast"))
    }

    /// Regression: --force is appended only when the caller passes
    /// `force: true` (i.e. after the user explicitly chose Replace).
    func testBuildCLIArgumentsPassesForceOnlyWhenExplicitlyRequested() {
        let base: (URL, URL?, URL, String, String?, String, Bool, String) = (
            URL(fileURLWithPath: "/data/reads.fastq.gz"), nil,
            URL(fileURLWithPath: "/project"), "illumina", nil,
            "illumina4", true, "balanced"
        )

        let withoutForce = CLIImportRunner.buildCLIArguments(
            r1: base.0, r2: base.1, projectDirectory: base.2,
            platform: base.3, recipeName: base.4, qualityBinning: base.5,
            optimizeStorage: base.6, compressionLevel: base.7
        )
        XCTAssertFalse(withoutForce.contains("--force"))

        let withForce = CLIImportRunner.buildCLIArguments(
            r1: base.0, r2: base.1, projectDirectory: base.2,
            platform: base.3, recipeName: base.4, qualityBinning: base.5,
            optimizeStorage: base.6, compressionLevel: base.7,
            force: true
        )
        XCTAssertTrue(withForce.contains("--force"))
    }

    /// Regression: an explicit bundle name reaches the CLI as `--name`,
    /// so Keep Both and sample-sheet names are not silently dropped.
    func testBuildCLIArgumentsForwardsBundleNameAsNameOption() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/project"),
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "illumina4",
            optimizeStorage: true,
            compressionLevel: "balanced",
            bundleName: "Sample1 2"
        )

        let nameIndex = args.firstIndex(of: "--name")
        XCTAssertNotNil(nameIndex)
        if let nameIndex {
            XCTAssertEqual(args[nameIndex + 1], "Sample1 2")
        }
    }

    func testBuildCLIArgumentsIncludesExplicitClumpingTool() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/project"),
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "illumina4",
            optimizeStorage: true,
            clumpingTool: .trimGalore,
            compressionLevel: "balanced"
        )

        XCTAssertTrue(args.contains("--clumping-tool"))
        XCTAssertTrue(args.contains("trim-galore"))
    }

    func testBuildCLIArgumentsCombinesVSP2TargetEnrichmentWithTrimGalore() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/project"),
            platform: "illumina",
            recipeName: "vsp2-target-enrichment",
            qualityBinning: "illumina4",
            optimizeStorage: true,
            clumpingTool: .trimGalore,
            compressionLevel: "balanced"
        )

        let recipeIndex = args.firstIndex(of: "--recipe")!
        let toolIndex = args.firstIndex(of: "--clumping-tool")!
        XCTAssertEqual(args[recipeIndex + 1], "vsp2-target-enrichment")
        XCTAssertEqual(args[toolIndex + 1], "trim-galore")
    }

    func testBuildCLIArgumentsTreatsNoClumpingToolAsNoOptimizeStorage() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/project"),
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "illumina4",
            optimizeStorage: true,
            clumpingTool: .none,
            compressionLevel: "balanced"
        )

        XCTAssertTrue(args.contains("--no-optimize-storage"))
        XCTAssertFalse(args.contains("--clumping-tool"))
    }

    func testCommandLineShellQuotesArguments() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/Volumes/iWES WNPRC/ww test/Sample R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/Volumes/iWES WNPRC/ww test/Sample R2.fastq.gz"),
            projectDirectory: URL(fileURLWithPath: "/Volumes/iWES WNPRC/ww test/ww.lungfish"),
            platform: "illumina",
            recipeName: "wastewater-metagenomics",
            qualityBinning: "illumina4",
            optimizeStorage: true,
            compressionLevel: "balanced"
        )

        let command = CLIImportRunner.commandLine(arguments: args)

        XCTAssertTrue(command.hasPrefix("lungfish-cli import fastq "))
        XCTAssertTrue(command.contains("'/Volumes/iWES WNPRC/ww test/Sample R1.fastq.gz'"))
        XCTAssertTrue(command.contains("--recipe wastewater-metagenomics"))
        XCTAssertTrue(command.contains("--platform illumina"))
        XCTAssertTrue(command.contains("--quality-binning illumina4"))
        XCTAssertTrue(command.contains("--compression balanced"))
    }

    func testFASTQIngestionOperationCommandPreviewMatchesCLIArguments() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R2.fastq.gz")
        )
        let project = URL(fileURLWithPath: "/Volumes/iWES_WNPRC/ww_test/ww.lungfish")
        let config = FASTQImportConfiguration(
            inputFiles: [pair.r1, pair.r2!],
            detectedPlatform: .illumina,
            confirmedPlatform: .illumina,
            pairingMode: .pairedEnd,
            qualityBinning: .illumina4,
            skipClumpify: false,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: "wastewater-metagenomics",
            compressionLevel: .balanced
        )

        let command = FASTQIngestionService.cliImportCommandPreview(
            pair: pair,
            projectDirectory: project,
            importConfig: config
        )

        // --force is no longer appended unconditionally — it is only
        // passed after the user explicitly chooses Replace in the duplicate
        // dialog. This preview reflects the default (no --force) command.
        // The sheet's Pairing choice is pinned as --pairing (2026-09-24). The
        // Platform popup was left on its detection, so --platform auto.
        XCTAssertEqual(
            command,
            "lungfish-cli import fastq /Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R1.fastq.gz /Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R2.fastq.gz --project /Volumes/iWES_WNPRC/ww_test/ww.lungfish --platform auto --pairing paired --format json --quality-binning illumina4 --compression balanced --recipe wastewater-metagenomics"
        )
    }

    func testCancelTerminatesCLIProcessTree() async throws {
        let tempDir = try makeTemporaryDirectory()
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM HUP INT; echo $$ > "$LUNGFISH_TEST_CHILD_PID_FILE"; while true; do sleep 1; done' &
        echo '{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}'
        while true; do sleep 1; done
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        let priorPIDFile = ProcessInfo.processInfo.environment["LUNGFISH_TEST_CHILD_PID_FILE"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        setenv("LUNGFISH_TEST_CHILD_PID_FILE", childPIDFile.path, 1)
        defer {
            if let priorCLIPath {
                setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
            if let priorPIDFile {
                setenv("LUNGFISH_TEST_CHILD_PID_FILE", priorPIDFile, 1)
            } else {
                unsetenv("LUNGFISH_TEST_CHILD_PID_FILE")
            }
        }

        let operationID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "FASTQ Import: cancellation test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await Self.finishAndClearOperation(operationID)
        }

        let runner = CLIImportRunner()
        let runTask = Task {
            await runner.run(
                arguments: [],
                operationID: operationID,
                projectDirectory: tempDir,
                onBundleCreated: { _ in },
                onError: { _ in }
            )
        }

        let childPID = try await waitForPIDFile(childPIDFile)
        addTeardownBlock {
            if Self.isProcessRunning(pid: childPID) {
                kill(childPID, SIGKILL)
            }
        }
        XCTAssertTrue(Self.isProcessRunning(pid: childPID))

        await runner.cancel()

        let childExited = await Self.waitUntilProcessExits(pid: childPID, timeout: 30)
        XCTAssertTrue(childExited, "Cancelling the CLI import must terminate child tool processes, not only lungfish-cli")

        if !childExited {
            kill(childPID, SIGKILL)
        }
        _ = await runTask.value
    }

    func testRunUsesStructuredSampleFailureAsFinalOperationDetail() async throws {
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let structuredError = "Recipe 'Illumina Amplicon Merge' cannot be applied to sample 'Solo': requires paired-end reads (R1 and R2), but only R1 was detected."
        let script = """
        #!/bin/sh
        echo '{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}'
        echo '{"event":"progress","message":"Importing Solo (1/1)","progress":0,"schemaVersion":2}'
        echo '{"event":"log","level":"error","message":"Solo failed: \(structuredError)","schemaVersion":2}'
        echo '{"error":"Solo: \(structuredError)","event":"failed","schemaVersion":2}'
        exit 64
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        defer {
            if let priorCLIPath {
                setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }

        let operationID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "FASTQ Import: structured failure test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await Self.finishAndClearOperation(operationID)
        }

        let errors = CLIImportRunnerStringCollector()
        let runner = CLIImportRunner()

        await runner.run(
            arguments: [],
            operationID: operationID,
            projectDirectory: tempDir,
            onBundleCreated: { _ in },
            onError: { errors.append($0) }
        )

        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == operationID }
        }
        let failedItem = try XCTUnwrap(item)
        XCTAssertEqual(failedItem.state, .failed)
        XCTAssertTrue(
            failedItem.detail.contains("requires paired-end reads"),
            "Final operation detail should preserve the structured sample failure, got: \(failedItem.detail)"
        )
        XCTAssertTrue(
            failedItem.errorMessage?.contains("requires paired-end reads") == true,
            "Final operation error summary should preserve the structured sample failure, got: \(String(describing: failedItem.errorMessage))"
        )
        XCTAssertTrue(errors.snapshot().contains { $0.contains("requires paired-end reads") })
    }

    func testRunReturnsAfterParentCLIExitsWhenDescendantKeepsStdoutPipeOpen() async throws {
        let tempDir = try makeTemporaryDirectory()
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        /bin/sh -c 'echo $$ > "$LUNGFISH_TEST_CHILD_PID_FILE"; sleep 60' &
        echo '{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}'
        echo '{"event":"progress","message":"Sample1: Compute statistics","progress":0.8,"schemaVersion":2}'
        echo '{"event":"log","level":"info","message":"Sample1 — bundle created","schemaVersion":2}'
        echo '{"artifacts":[{"kind":"fastq","path":"/project/Imports/Sample1.lungfishfastq","role":"bundle"}],"event":"complete","outputs":["/project/Imports/Sample1.lungfishfastq"],"schemaVersion":2}'
        exit 0
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        let priorPIDFile = ProcessInfo.processInfo.environment["LUNGFISH_TEST_CHILD_PID_FILE"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        setenv("LUNGFISH_TEST_CHILD_PID_FILE", childPIDFile.path, 1)
        defer {
            if let priorCLIPath {
                setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
            if let priorPIDFile {
                setenv("LUNGFISH_TEST_CHILD_PID_FILE", priorPIDFile, 1)
            } else {
                unsetenv("LUNGFISH_TEST_CHILD_PID_FILE")
            }
        }

        let operationID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "FASTQ Import: stdout pipe lifecycle test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await Self.finishAndClearOperation(operationID)
        }

        let bundles = CLIImportRunnerStringCollector()
        let runner = CLIImportRunner()
        let completion = CLIImportRunnerCompletionFlag()

        let runTask = Task {
            await runner.run(
                arguments: [],
                operationID: operationID,
                projectDirectory: tempDir,
                onBundleCreated: { bundles.append($0.lastPathComponent) },
                onError: { _ in }
            )
            completion.markCompleted()
        }

        let childPID = try await waitForPIDFile(childPIDFile)
        addTeardownBlock {
            if Self.isProcessRunning(pid: childPID) {
                kill(childPID, SIGKILL)
            }
        }

        // The descendant holds stdout for 60 s. A runner that waited for EOF
        // would miss this 30 s window, which leaves room for the parallel unit
        // tier, and the wait returns as soon as the run does.
        let returnedBeforeTimeout = await completion.waitUntilCompleted(timeout: 30)
        if !returnedBeforeTimeout {
            await runner.cancel()
            if Self.isProcessRunning(pid: childPID) {
                kill(childPID, SIGKILL)
            }
        }
        _ = await runTask.value

        XCTAssertTrue(
            returnedBeforeTimeout,
            "CLIImportRunner should return when the parent lungfish-cli exits, even if a descendant still holds stdout open"
        )
        // The output a child process kept open is incomplete, so the run fails, as ToolProcess fails
        // any run whose output it could not finish reading, and no bundle is handed over. The S1
        // runner failed the row the same way but had handed the bundle over as the sample finished.
        XCTAssertEqual(bundles.snapshot(), [])
        let item = await MainActor.run { OperationCenter.shared.items.first { $0.id == operationID } }
        XCTAssertEqual(item?.state, .failed)
        XCTAssertTrue(item?.errorMessage?.contains("a child process kept it open") == true, String(describing: item?.errorMessage))
    }

    func testResolveCLIPathPrefersBundledSiblingExecutable() throws {
        let tempDir = try makeTemporaryDirectory()
        let executableDir = tempDir.appendingPathComponent("Lungfish.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDir, withIntermediateDirectories: true)

        let mainExecutable = executableDir.appendingPathComponent("Lungfish")
        FileManager.default.createFile(atPath: mainExecutable.path, contents: Data())

        let bundledCLI = executableDir.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: bundledCLI.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLI.path)

        let resolved = CLIImportRunner.resolveCLIPath(
            mainExecutableURL: mainExecutable,
            currentWorkingDirectoryURL: nil,
            pathLookup: { nil }
        )

        XCTAssertEqual(resolved, bundledCLI)
    }

    func testResolveCLIPathUsesSwiftPMBinPathForWorkspacePackage() throws {
        let tempDir = try makeTemporaryDirectory()
        let sourceRoot = tempDir.appendingPathComponent("repo", isDirectory: true)
        let binDir = tempDir.appendingPathComponent("swiftpm-bin", isDirectory: true)
        let workingDirectory = sourceRoot.appendingPathComponent("Sources/LungfishApp/Services", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: sourceRoot.appendingPathComponent("Package.swift").path,
            contents: Data("// swift-tools-version: 6.2\n".utf8)
        )

        let debugCLI = binDir.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: debugCLI.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: debugCLI.path)

        let resolved = CLIImportRunner.resolveCLIPath(
            mainExecutableURL: nil,
            currentWorkingDirectoryURL: workingDirectory,
            pathLookup: { nil },
            swiftPMBinPathLookup: { packageRoot in
                XCTAssertEqual(packageRoot, sourceRoot)
                return binDir
            }
        )

        XCTAssertEqual(resolved, debugCLI)
    }

    func testResolveCLIPathPrefersExplicitEnvironmentOverride() throws {
        let tempDir = try makeTemporaryDirectory()
        let explicitCLI = tempDir.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: explicitCLI.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: explicitCLI.path)

        let resolved = CLIImportRunner.resolveCLIPath(
            mainExecutableURL: nil,
            currentWorkingDirectoryURL: nil,
            environment: ["LUNGFISH_CLI_PATH": explicitCLI.path],
            pathLookup: { nil }
        )

        XCTAssertEqual(resolved, explicitCLI)
    }

    /// Finishes, then removes, a row a test began on the shared OperationCenter.
    ///
    /// `CLIImportRunner` fails the row itself when the CLI fails. After a clean exit it
    /// leaves the row running for its caller to complete with the new bundle, as
    /// `FASTQIngestionService.runIngestAndBundle` does. These tests are that caller, so
    /// the row is completed before it is cleared, because `clearItem` skips a running
    /// row. Two tests used to leave a running row behind, and a later suite in the same
    /// process that expected no active row failed.
    @MainActor
    private static func finishAndClearOperation(_ operationID: UUID) {
        OperationCenter.shared.complete(id: operationID, detail: "Test finished")
        OperationCenter.shared.clearItem(id: operationID)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 30.0) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? readRepositorySource(url)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(contents) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "CLIImportRunnerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for fake CLI child PID"]
        )
    }

    private static func waitUntilProcessExits(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessRunning(pid: pid) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !isProcessRunning(pid: pid)
    }

    private static func isProcessRunning(pid: Int32) -> Bool {
        ProcessTreeTerminator.processExists(pid: pid)
    }
}
