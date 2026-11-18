// RNASeqPlanSheetTests.swift - The RNA-seq plan sheets and the adopt card of the Linux route (Phase 5.4 lane EX-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each sheet builds one argv. It parses through the real subcommand, the Operations row records it with the FASTQ plan and
// adopt `OperationType`, and a refusal of the command reaches the row in the command's words. The words of the 10x sheet
// name a supplied barcode list as supplied and never call the introns preset a match for Cell Ranger 7 (exit X4). A run
// that the command refuses or that is cancelled leaves no plan folder.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class RNASeqPlanSheetTests: XCTestCase {
    private let plans = URL(fileURLWithPath: "/data/out/plan-1", isDirectory: true)

    private func bulkModel(staged: Bool = false) -> RNASeqPlanSheetModel {
        let model = RNASeqPlanSheetModel(kind: .bulk, appHasFiles: true)
        model.setID = "ensembl-107"
        model.stagingFolder = "/staging/groups/g/1/lge"
        model.planFolder = plans
        if staged {
            model.reads = .staged
            model.stagedReads = URL(fileURLWithPath: "/data/staged-reads.tsv")
            model.sampleSheet = URL(fileURLWithPath: "/data/samples.csv")
        } else {
            model.bundles = [
                URL(fileURLWithPath: "/data/Project.lungfish/Inputs/a.lungfishfastq", isDirectory: true),
                URL(fileURLWithPath: "/data/Project.lungfish/Inputs/b.lungfishfastq", isDirectory: true),
            ]
        }
        return model
    }

    private func tenXModel() -> RNASeqPlanSheetModel {
        let model = RNASeqPlanSheetModel(kind: .tenX, appHasFiles: true)
        model.setID = "ensembl-107"
        model.stagingFolder = "/staging/groups/g/1/lge"
        model.planFolder = plans
        model.stagedReads = URL(fileURLWithPath: "/data/staged-reads.tsv")
        model.sampleSheet = URL(fileURLWithPath: "/data/samples.csv")
        return model
    }

    // MARK: - The argv round trip

    func testTheBulkSheetsArgvParsesThroughRNASeqQuantSubcommand() throws {
        let model = bulkModel()
        model.chain = "star-2.7.11b-genecounts"
        model.requestMemoryMiB = "4096"
        model.requestDiskGiB = "20"
        model.jobRequirements = "OpSys == \"LINUX\""
        let request = try XCTUnwrap(model.request(dryRun: true))

        XCTAssertEqual(Array(request.arguments.prefix(2)), ["rnaseq", "quant"])
        let leaf = try RNASeqCommand.QuantSubcommand.parse(Array(request.arguments.dropFirst(2)))
        XCTAssertEqual(leaf.bundles, model.bundles.map(\.path))
        XCTAssertEqual(leaf.setID, "ensembl-107")
        XCTAssertNil(leaf.project, "a plan writes no result in a project")
        XCTAssertEqual(leaf.planOptions.writePlan, plans.path)
        XCTAssertEqual(leaf.planOptions.chain?.rawValue, "star-2.7.11b-genecounts")
        XCTAssertEqual(leaf.planOptions.stagingFolder, "/staging/groups/g/1/lge")
        XCTAssertEqual(leaf.planOptions.requestCPUs, 8, "the CLI's own default is shown and sent")
        XCTAssertEqual(leaf.planOptions.requestMemoryMiB, 4096)
        XCTAssertEqual(leaf.planOptions.requestDiskGiB, 20)
        XCTAssertEqual(leaf.planOptions.jobRequirements, "OpSys == \"LINUX\"")
        XCTAssertTrue(leaf.planOptions.dryRun, "Check is --dry-run")
        XCTAssertNil(leaf.planOptions.executorManifest, "the app's own executor is the command's default")
        XCTAssertEqual(leaf.globalOptions.outputFormat, .json)
        XCTAssertTrue(try LungfishCLI.parseAsRoot(request.arguments) is RNASeqCommand.QuantSubcommand)
        XCTAssertEqual(RNASeqPlanSheetModel.chains, RNASeqQuantPlanChain.allCases.map(\.rawValue), "the sheet offers the CLI's chains")

        let written = try XCTUnwrap(model.request(dryRun: false))
        XCTAssertFalse(written.arguments.contains("--dry-run"), "Write Plan is the same argv without --dry-run")
        let wroteLeaf = try RNASeqCommand.QuantSubcommand.parse(Array(written.arguments.dropFirst(2)))
        XCTAssertFalse(wroteLeaf.planOptions.dryRun)
        XCTAssertEqual(wroteLeaf.planOptions.chain?.rawValue, "star-2.7.11b-genecounts")
    }

    func testTheBulkSheetsStagedReadsGoWithTheSampleSheetAndNoBundles() throws {
        let model = bulkModel(staged: true)
        model.executorManifest = URL(fileURLWithPath: "/exec/manifest.json")
        model.image = URL(fileURLWithPath: "/exec/image.json")
        model.imageToolManifest = URL(fileURLWithPath: "/exec/image-manifest.json")
        let request = try XCTUnwrap(model.request(dryRun: false))

        let leaf = try RNASeqCommand.QuantSubcommand.parse(Array(request.arguments.dropFirst(2)))
        XCTAssertTrue(leaf.bundles.isEmpty)
        XCTAssertEqual(leaf.planOptions.stagedReads, "/data/staged-reads.tsv")
        XCTAssertEqual(leaf.planOptions.samplesheet, "/data/samples.csv")
        XCTAssertNil(leaf.planOptions.chain, "the default chain is left to the command")
        XCTAssertEqual(leaf.planOptions.executorManifest, "/exec/manifest.json")
        XCTAssertEqual(leaf.planOptions.image, "/exec/image.json")
        XCTAssertEqual(leaf.planOptions.imageToolManifest, "/exec/image-manifest.json")
        XCTAssertTrue(try LungfishCLI.parseAsRoot(request.arguments) is RNASeqCommand.QuantSubcommand)
    }

    func testTheTenXSheetsArgvParsesThroughRNASeqSoloPlanSubcommand() throws {
        let model = tenXModel()
        model.preset = .threePrimeV3Introns
        model.barcodeList = URL(fileURLWithPath: "/data/3M-february-2018.txt")
        model.tenXFilter = "gencode-2020-A"
        let request = try XCTUnwrap(model.request(dryRun: true))

        XCTAssertEqual(Array(request.arguments.prefix(2)), ["rnaseq", "solo-plan"])
        let parsed = try RNASeqSoloPlanSubcommand.parse(Array(request.arguments.dropFirst(2)))
        XCTAssertEqual(parsed.setReference, "ensembl-107")
        XCTAssertEqual(parsed.preset, "tenx-3p-v3-introns")
        XCTAssertEqual(parsed.barcodeList, "/data/3M-february-2018.txt")
        XCTAssertEqual(parsed.tenxFilter, "gencode-2020-A")
        XCTAssertEqual(parsed.stagedReads, "/data/staged-reads.tsv")
        XCTAssertEqual(parsed.samplesheet, "/data/samples.csv")
        XCTAssertEqual(parsed.outputPath, plans.path)
        XCTAssertEqual(parsed.stagingFolder, "/staging/groups/g/1/lge")
        XCTAssertEqual(parsed.expectedCells, 3000, "the CLI's own default is shown and sent")
        XCTAssertEqual(parsed.requestCPUs, 8)
        XCTAssertTrue(parsed.dryRun)
        XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
        XCTAssertTrue(try LungfishCLI.parseAsRoot(request.arguments) is RNASeqSoloPlanSubcommand)
        XCTAssertEqual(SoloPlanPreset.allCases.map(\.rawValue), ["tenx-3p-v3", "tenx-5p-v2", "tenx-3p-v3-introns"])
    }

    func testTheAdoptCardsArgvParsesThroughImportRNASeqSubcommandWithDryRunAndStorageRoot() throws {
        let folder = URL(fileURLWithPath: "/data/returned/star-2711-genecounts", isDirectory: true)
        let project = URL(fileURLWithPath: "/data/Project.lungfish", isDirectory: true)
        let model = RNASeqAdoptSheetModel(folder: folder, projectURL: project)
        XCTAssertEqual(model.name, "star-2711-genecounts")
        model.storageRoot = URL(fileURLWithPath: "/data/storage", isDirectory: true)
        let request = try XCTUnwrap(model.request(dryRun: true))

        let parsed = try ImportCommand.RNASeqSubcommand.parse(Array(request.arguments.dropFirst(2)))
        XCTAssertEqual(parsed.inputPaths, [folder.path])
        XCTAssertEqual(parsed.projectPath, project.path)
        XCTAssertEqual(parsed.name, "star-2711-genecounts")
        XCTAssertTrue(parsed.adoptOptions.adopt)
        XCTAssertTrue(parsed.adoptOptions.dryRun)
        XCTAssertEqual(parsed.adoptOptions.storageRoot, "/data/storage")
        XCTAssertNil(parsed.adoptRefusal)
        XCTAssertTrue(try LungfishCLI.parseAsRoot(request.arguments) is ImportCommand.RNASeqSubcommand)
        let adopt = try XCTUnwrap(model.request(dryRun: false))
        XCTAssertFalse(adopt.arguments.contains("--dry-run"))
    }

    // MARK: - The words (exit X4)

    func testTheTenXSheetNamesASuppliedListAsSuppliedAndNeverCallsTheIntronsPresetAMatch() {
        let model = tenXModel()
        for preset in SoloPlanPreset.allCases {
            model.preset = preset
            model.barcodeList = nil
            let fromImage = model.barcodeListWords
            XCTAssertTrue(fromImage.contains(preset.barcodeList.name), fromImage)
            XCTAssertTrue(fromImage.contains(SoloPlanBarcodes.fromImage), "a list from the image names its source: \(fromImage)")
            model.barcodeList = URL(fileURLWithPath: "/data/my-whole-list.txt")
            let supplied = model.barcodeListWords
            XCTAssertTrue(supplied.contains("my-whole-list.txt"), supplied)
            XCTAssertTrue(supplied.contains("supplied by you"), supplied)
            XCTAssertTrue(supplied.contains("SHA-256"), "a supplied list is checked by SHA-256: \(supplied)")
            XCTAssertTrue(supplied.contains(SoloPlanBarcodes.supplied), supplied)
            XCTAssertTrue(supplied.contains("never copies"), supplied)
            XCTAssertFalse(supplied.contains(SoloPlanBarcodes.fromImage), "a supplied list is not called the image's: \(supplied)")
            for words in [model.presetWords, fromImage, supplied] {
                XCTAssertNil(words.range(of: "match", options: .caseInsensitive), "no preset is called a match: \(words)")
            }
        }
        model.preset = .threePrimeV3Introns
        XCTAssertTrue(model.presetWords.contains("approximates Cell Ranger 7"), model.presetWords)
        XCTAssertTrue(model.presetWords.contains(RNASeqPlanWords.introsAdopt), "the CLI's sentence about the adopt of this preset")
    }

    func testTheSheetsAskForWhatTheCommandNeedsAndSayWhatIsMissing() {
        let model = RNASeqPlanSheetModel(kind: .bulk, appHasFiles: true)
        XCTAssertEqual(model.missingChoice, "Give the id of the reference set.")
        model.setID = "ens"
        XCTAssertEqual(model.missingChoice, "Choose the FASTQ bundles to plan.")
        model.bundles = [URL(fileURLWithPath: "/data/a.lungfishfastq")]
        XCTAssertEqual(model.missingChoice, "Give the absolute path of the staging folder on the Linux machine.")
        model.stagingFolder = "/staging"
        XCTAssertEqual(model.missingChoice, "Name the new plan folder.")
        model.planFolder = plans
        XCTAssertNil(model.missingChoice)
        model.requestCPUs = "0"
        XCTAssertEqual(model.missingChoice, "CPUs each job asks for is a whole number from 1.")
        XCTAssertNil(model.request(dryRun: false), "a missing value makes no command")
        let bare = RNASeqPlanSheetModel(kind: .bulk, appHasFiles: false)
        bare.setID = "ens"
        bare.bundles = model.bundles
        bare.stagingFolder = "/staging"
        bare.planFolder = plans
        XCTAssertEqual(bare.missingChoice, FASTQPlanSheetModel.noExecutorSentence, "a build with no executor says so")
        XCTAssertEqual(RNASeqPlanSheetModel.defaultRequestCPUs, 8)
        XCTAssertEqual(RNASeqPlanSheetModel.defaultExpectedCells, 3000)
    }

    func testTheCardsOfTheLinuxRouteSitOnTheSequencingReadsTab() throws {
        let cards = ImportCenterViewModel().allCards
        for (id, action) in [
            ("rnaseq-bulk-plan", ImportCardInfo.ImportAction.rnaseqBulkPlan),
            ("rnaseq-tenx-plan", .rnaseqTenXPlan),
            ("rnaseq-linux-run-result", .rnaseqLinuxRunResult),
        ] {
            let card = try XCTUnwrap(cards.first { $0.id == id }, id)
            XCTAssertEqual(card.tab, .sequencingReads)
            XCTAssertEqual(card.importAction, action)
        }
        guard case .openPanel(let panel, _) = try XCTUnwrap(cards.first { $0.id == "rnaseq-linux-run-result" }).importKind else {
            return XCTFail("the adopt card asks for the returned folder first")
        }
        XCTAssertTrue(panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection)
    }

    // MARK: - The Operations row

    func testEachRowNamesItsTypeAndRecordsTheArgvThatRuns() throws {
        let reporter = RecordingOperationReporter()
        var launched: [UUID] = []
        let bulk = try XCTUnwrap(bulkModel().request(dryRun: false))
        let tenX = try XCTUnwrap(tenXModel().request(dryRun: true))
        let adopt = try XCTUnwrap(RNASeqAdoptSheetModel(
            folder: URL(fileURLWithPath: "/data/returned/S1"), projectURL: URL(fileURLWithPath: "/data/Project.lungfish")
        ).request(dryRun: false))

        AppDelegate.beginRNASeqPlanOperation(request: bulk, routeContext: nil, reporter: reporter) { launched.append($0) }
        AppDelegate.beginRNASeqPlanOperation(request: tenX, routeContext: nil, reporter: reporter) { launched.append($0) }
        AppDelegate.beginRNASeqAdoptOperation(request: adopt, routeContext: nil, reporter: reporter) { launched.append($0) }

        XCTAssertEqual(reporter.items.map(\.id), launched)
        XCTAssertEqual(reporter.items.map(\.operationType), [.ingestion, .ingestion, .ingestion])
        XCTAssertEqual(reporter.items.map(\.title), ["Plan for a Linux Machine: plan-1", "Check of the Plan: plan-1", "RNA-seq Linux Run Result: S1"])
        for (item, request) in zip(reporter.items, [bulk.arguments, tenX.arguments, adopt.arguments]) {
            XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), request)
            XCTAssertEqual(try RecordedCLICommand.parseScript(item.cliCommand).count, 1, "one command that the shipped parser accepts")
        }
    }

    private struct StandInPlanRunner: RNASeqPlanCommandRunning {
        let end: RNASeqPlanRunError?
        func run(argv: [String], cancellation: CLIRunCancellation, log: @escaping @Sendable (String) -> Void) async throws {
            log("planning")
            if let end { throw end }
        }
    }

    private func runPlan(_ request: RNASeqPlanRequest, end: RNASeqPlanRunError?, reporter: RecordingOperationReporter) async -> RNASeqPlanOutcome {
        await withCheckedContinuation { continuation in
            let id = AppDelegate.startRNASeqPlan(
                request: request, routeContext: nil, reporter: reporter, runner: StandInPlanRunner(end: end)
            ) { continuation.resume(returning: $0) }
            if id == nil { continuation.resume(returning: .refused("the row was refused")) }
        }
    }

    /// X5. The command refuses a plan, and the refusal shows the command's own words on the Operations row and in the sheet,
    /// which keeps its values. The refused plan leaves no folder.
    func testARefusedPlanReachesTheRowAndTheSheetInTheCommandsWordsAndWritesNoFolder() async throws {
        let model = tenXModel()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-plan-refused-\(UUID().uuidString)")
        model.planFolder = folder
        let words = "The set ensembl-107 has no adopted STAR 2.7.11b index with no 10x filter rule in this storage root, and a plan never builds one."
        let reporter = RecordingOperationReporter()
        let request = try XCTUnwrap(model.request(dryRun: false))

        let outcome = await runPlan(request, end: .failed(words), reporter: reporter)
        model.finish(outcome)

        XCTAssertEqual(outcome, .refused(words))
        XCTAssertEqual(reporter.items.first?.state, .failed)
        XCTAssertEqual(reporter.items.first?.failure?.detail, words, "the Operations row shows the command's words")
        XCTAssertEqual(model.failure, words, "the sheet shows the command's words")
        XCTAssertEqual(model.stagedReads?.lastPathComponent, "staged-reads.tsv", "the sheet keeps its values")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a refused plan writes nothing")
    }

    func testACancelledPlanEndsTheRowCancelledAndLeavesNoFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-plan-cancelled-\(UUID().uuidString)")
        let model = bulkModel()
        model.planFolder = folder
        let reporter = RecordingOperationReporter()
        let request = try XCTUnwrap(model.request(dryRun: false))

        let outcome = await runPlan(request, end: .cancelled, reporter: reporter)
        model.finish(outcome)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(reporter.items.first?.state, .cancelled)
        XCTAssertNotNil(model.note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a cancelled plan leaves no folder")
    }

    func testAFinishedPlanAndAPassedCheckCompleteTheirRows() async throws {
        let reporter = RecordingOperationReporter()
        let model = bulkModel()
        let written = await runPlan(try XCTUnwrap(model.request(dryRun: false)), end: nil, reporter: reporter)
        let checked = await runPlan(try XCTUnwrap(model.request(dryRun: true)), end: nil, reporter: reporter)

        XCTAssertEqual(written, .written(plans))
        XCTAssertEqual(checked, .checked)
        XCTAssertEqual(reporter.items.map(\.state), [.completed, .completed])
    }

    func testTheCommandsWordsAreTheStandardErrorWithoutItsErrorPrefix() {
        XCTAssertEqual(
            CLIRNASeqPlanRunner.words(fromStandardError: "Error: The plan folder x already exists, so name a new folder.\n"),
            "The plan folder x already exists, so name a new folder."
        )
        XCTAssertEqual(CLIRNASeqPlanRunner.words(fromStandardError: "no prefix\n"), "no prefix")
    }

    func testTheAdoptEndsInTheResultACheckOrTheCommandsWords() {
        let bundle = URL(fileURLWithPath: "/data/Project.lungfish/Analyses/S1.lungfishrnaseq")
        XCTAssertEqual(AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(bundles: [bundle]), dryRun: false), .adopted(bundle))
        XCTAssertEqual(AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(), dryRun: true), .checked, "a dry run names no result")
        XCTAssertEqual(AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(error: "Import cancelled"), dryRun: false), .cancelled)
        XCTAssertEqual(
            AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(error: "S1 was refused."), dryRun: true), .refused("S1 was refused.")
        )
        XCTAssertEqual(
            AppDelegate.rnaSeqAdoptEnd(RNASeqImportSeen(), dryRun: false),
            .refused("The adopt finished without naming the result it made.")
        )
    }
}
