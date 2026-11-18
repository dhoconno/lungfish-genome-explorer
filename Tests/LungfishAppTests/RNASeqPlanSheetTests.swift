// RNASeqPlanSheetTests.swift - The words and the choices of the RNA-seq plan sheets and the cards of the Linux route (Phase 5.4 lane EX-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The words of the 10x sheet name a supplied barcode list as supplied and never call the introns preset a match for Cell
// Ranger 7 (exit X4). The sheets ask for what their command needs and say what is missing, and the cards sit on the Sequencing
// Reads tab. The argv round trips of the three sheets are cases of `CLIRunnerArgvRoundTripTests`, their Operations rows and
// the stand-in runs are cases of `FASTQLinuxRunOperationTests`, the end of an adopt is a case of `CLIImportRunnerTests`, and
// the replays, the cancel and the refusal of the real command are cases of `FastqIngestCancelReplayTests` (SAD:95, a new route
// adds cases to the sets of its family).

import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishWorkflow

/// The values a person gives each sheet, which the cases of the families that run the sheets' argv share.
@MainActor
enum RNASeqPlanSheetFixtures {
    static let plans = URL(fileURLWithPath: "/data/out/plan-1", isDirectory: true)

    static func bulkModel(staged: Bool = false) -> RNASeqPlanSheetModel {
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

    static func tenXModel() -> RNASeqPlanSheetModel {
        let model = RNASeqPlanSheetModel(kind: .tenX, appHasFiles: true)
        model.setID = "ensembl-107"
        model.stagingFolder = "/staging/groups/g/1/lge"
        model.planFolder = plans
        model.stagedReads = URL(fileURLWithPath: "/data/staged-reads.tsv")
        model.sampleSheet = URL(fileURLWithPath: "/data/samples.csv")
        return model
    }
}

@MainActor
final class RNASeqPlanSheetTests: XCTestCase {
    // MARK: - The words (exit X4)

    func testTheTenXSheetNamesASuppliedListAsSuppliedAndNeverCallsTheIntronsPresetAMatch() {
        let model = RNASeqPlanSheetFixtures.tenXModel()
        for preset in SoloPlanPreset.allCases {
            model.preset = preset
            model.barcodeList = nil
            let fromImage = model.barcodeListWords
            XCTAssertTrue(fromImage.contains(preset.barcodeList.name), fromImage)
            XCTAssertTrue(fromImage.contains(SoloPlanBarcodes.fromImage), "a list from the image names its source: \(fromImage)")
            // EX-APP-UX SF-2. The sheet cannot know the image of a chosen manifest, and the app's own image holds one list of
            // the two, so it states the rule of the command and not a fact about the image.
            XCTAssertTrue(fromImage.contains("refuses in words when the image holds none"), fromImage)
            XCTAssertFalse(fromImage.contains("Source: the"), "the sheet does not claim the list is in the image: \(fromImage)")
            model.barcodeList = URL(fileURLWithPath: "/data/my-whole-list.txt")
            let supplied = model.barcodeListWords
            XCTAssertTrue(supplied.contains("my-whole-list.txt"), supplied)
            XCTAssertTrue(supplied.contains("supplied by you"), supplied)
            XCTAssertTrue(supplied.contains("SHA-256"), "a supplied list is checked by SHA-256: \(supplied)")
            XCTAssertTrue(supplied.contains(SoloPlanBarcodes.supplied), supplied)
            XCTAssertTrue(supplied.contains("never copies"), supplied)
            XCTAssertFalse(supplied.contains(SoloPlanBarcodes.fromImage), "a supplied list is not called the image's: \(supplied)")
            // ADJ-SC-2 forbids four phrases for the introns preset (R1), so the rule is pinned on every text of the sheet.
            for forbidden in ["match", "equivalent", "compatible", "same counts as"] {
                for words in [model.presetWords, fromImage, supplied, model.introduction, RNASeqPlanWords.introsAdopt] {
                    XCTAssertNil(words.range(of: forbidden, options: .caseInsensitive), "no preset is called \"\(forbidden)\": \(words)")
                }
            }
        }
        model.preset = .threePrimeV3Introns
        XCTAssertTrue(model.presetWords.contains("approximates Cell Ranger 7"), model.presetWords)
        XCTAssertTrue(model.presetWords.contains(RNASeqPlanWords.introsAdopt), "the CLI's sentence about the adopt of this preset")
    }

    func testTheSheetsAskForWhatTheCommandNeedsAndSayWhatIsMissing() {
        let plans = RNASeqPlanSheetFixtures.plans
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
        // EX-APP-UX SF-3. A batch returns one folder a sample, and each needs the files inside result/ copied next to its
        // plan.json before the adopt takes it. The FASTQ card says so, and the adopt card says so before a refusal does.
        let adopt = try XCTUnwrap(cards.first { $0.id == "rnaseq-linux-run-result" })
        let hint = try XCTUnwrap(adopt.fileHint)
        XCTAssertTrue(hint.contains("copy the files inside result/"), hint)
        XCTAssertTrue(hint.contains("next to plan.json"), hint)
    }
}
