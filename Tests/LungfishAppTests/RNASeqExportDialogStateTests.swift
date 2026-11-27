// RNASeqExportDialogStateTests.swift - The export row of the Workflow Operations dialog, its state half (RS-DIALOG-M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.4, lane RS-DIALOG-M2. `RNASeqExportDialogTests` holds the request, the route and the built-CLI cases. This class holds
// what the dialog adds. The row is a tool of the Workflow Operations dialog, the readiness words name what is missing and say nothing
// the CLI checks, the launch request is the request of the pane and its argv parses through the real subcommand, and a busy result
// refuses the row through the dialog's own service and launches nothing.

import Foundation
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow

@MainActor
final class RNASeqExportDialogStateTests: XCTestCase {
    private var scratch: URL!
    private let first = URL(fileURLWithPath: "/tmp/export-state/Analyses/a.lungfishrnaseq", isDirectory: true)
    private let second = URL(fileURLWithPath: "/tmp/export-state/Analyses/b.lungfishrnaseq", isDirectory: true)

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "rnaseq-export-state")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private func makeState(projectURL: URL?) -> WorkflowOperationDialogState {
        let defaults = makeTestDefaultsSuite(prefix: "RNASeqExportDialogStateTests").defaults
        return WorkflowOperationDialogState(
            projectURL: projectURL,
            initialToolID: WorkflowLibraryCatalog.rnaSeqExportID,
            enablementStore: WorkflowLibraryEnablementStore(userDefaults: defaults),
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults))
    }

    // MARK: the tools

    func testTheTwoRowsAreToolsOfTheDialogAndAvailableWithNothingEnabled() throws {
        let state = makeState(projectURL: nil)
        let export = try XCTUnwrap(state.tools.first { $0.id == "builtin.rnaseq-export" })
        let pseudobulk = try XCTUnwrap(state.tools.first { $0.id == "builtin.rnaseq-pseudobulk" })
        XCTAssertEqual(export.kind, .rnaSeqExport)
        XCTAssertEqual(export.title, "Export Counts and Analysis Scripts")
        XCTAssertEqual(export.availability, .available)
        XCTAssertEqual(pseudobulk.kind, .rnaSeqPseudobulk)
        XCTAssertEqual(pseudobulk.title, "Pseudobulk RNA-seq Cells")
        XCTAssertEqual(pseudobulk.availability, .available)
        XCTAssertEqual(state.selectedToolID, "builtin.rnaseq-export", "the menu item opens the dialog on its own row")
        XCTAssertEqual(state.outputName, "rnaseq-export")
        for id in [WorkflowLibraryCatalog.rnaSeqExportID, WorkflowLibraryCatalog.rnaSeqPseudobulkID] {
            let item = try XCTUnwrap(WorkflowLibraryCatalog.item(id: id))
            XCTAssertEqual(item.categoryID, .rnaSeq, "the item reaches Tools > RNA-seq")
            XCTAssertTrue(item.capabilities.contains(.workflowOperations))
        }
    }

    // MARK: readiness

    func testReadinessNamesWhatIsMissingInOrderAndNothingTheCLIChecks() {
        let state = makeState(projectURL: scratch)
        XCTAssertEqual(state.readinessText, "Select one or more RNA-seq results.")
        XCTAssertFalse(state.isRunEnabled)
        state.rnaSeqExport.resultURLs = [first]
        XCTAssertEqual(state.readinessText, "Ready to run.")
        XCTAssertTrue(state.isRunEnabled)
        state.outputName = "   "
        XCTAssertEqual(state.readinessText, "Enter a name for the export folder.")
        state.outputName = "de"
        state.rnaSeqExport.cutoffText = "five percent"
        XCTAssertEqual(state.readinessText, "Enter the cutoff as a number above 0 and at most 1, such as 0.05.")
        state.rnaSeqExport.cutoffText = "0.1"
        state.rnaSeqExport.lfcBarText = "one"
        XCTAssertEqual(state.readinessText, "Enter the fold-change bar as 0 or more, such as 1, or leave it empty for none.")
        state.rnaSeqExport.lfcBarText = ""
        XCTAssertEqual(state.readinessText, "Ready to run.", "an empty bar means none")
        // The design, the batch and the animals are the CLI's to refuse, in its own words on the row, and so are the levels of a
        // contrast. The pane checks only the three arguments the CLI answers in terminal text (the cutoff range, the sign of the
        // bar and the shape of a contrast), which testTheReadinessAgreesWithTheCLIsArgumentCheck holds against the CLI.
        state.rnaSeqExport.designText = "no-such-column"
        state.rnaSeqExport.contrastsText = "group:TB:HIV"
        state.rnaSeqExport.batchCorrection = .sva
        XCTAssertEqual(state.readinessText, "Ready to run.")
    }

    /// The pane and the CLI refuse the same typing. `RNASeqExportSubcommand.validate()` checks the range of the cutoff, the sign of the
    /// fold-change bar and the shape of each contrast, and the CLI answers a refusal in terminal text on the Operations row, so the
    /// readiness words mirror the three. Each row is what is typed, then the option the CLI names when it refuses it, `nil` when it
    /// accepts. The request of each row is built from the row and not from the pane, so the CLI side does not share the pane's parsing.
    func testTheReadinessAgreesWithTheCLIsArgumentCheck() throws {
        let rows: [(cutoff: String, bar: String, contrasts: [String], refusedBy: String?)] = [
            ("0.05", "", ["group:TB:HIV"], nil),
            ("1", "0", ["a:b:c"], nil),
            ("0.05", "0.5", ["group:TB:HIV", "group:HIV:ctl"], nil),
            ("0", "", [], "--padj-cutoff"),
            ("1.5", "", [], "--padj-cutoff"),
            ("-0.05", "", [], "--padj-cutoff"),
            ("0.05", "-1", [], "--lfc-bar"),
            ("0.05", "", ["TB:HIV"], "--contrast"),
            ("0.05", "", ["TB vs HIV"], "--contrast"),
            ("0.05", "", ["group:TB:"], "--contrast"),
            ("0.05", "", ["group:TB:HIV:ctl"], "--contrast"),
            ("0.05", "", ["group:TB:HIV", "TB:HIV"], "--contrast"),
            // Three parts that are not all given: a doubled, a leading or a trailing colon (BIO-EXPORT-EMPTY-PART). The CLI counted
            // only the parts that hold text, so it took the first three of these into the wrong roles and wrote them into the scripts.
            ("0.05", "", ["group::TB:HIV"], "--contrast"),
            ("0.05", "", ["group:TB::HIV"], "--contrast"),
            ("0.05", "", [":group:TB:HIV"], "--contrast"),
            ("0.05", "", ["group:TB:HIV:"], "--contrast"),
        ]
        let state = makeState(projectURL: scratch)
        state.rnaSeqExport.resultURLs = [first]
        state.outputName = "de"
        for row in rows {
            state.rnaSeqExport.cutoffText = row.cutoff
            state.rnaSeqExport.lfcBarText = row.bar
            state.rnaSeqExport.contrastsText = row.contrasts.joined(separator: "\n")
            let request = RNASeqExportRunRequest(
                resultURLs: [first], outputURL: scratch.appendingPathComponent("de", isDirectory: true),
                contrasts: row.contrasts, padjCutoff: try XCTUnwrap(Double(row.cutoff)), lfcBar: Double(row.bar))
            XCTAssertEqual(
                state.readinessText == WorkflowOperationDialogState.rnaSeqReadyText, row.refusedBy == nil,
                "the pane for \(row) reads: \(state.readinessText)")
            do {
                _ = try RNASeqExportSubcommand.parse(Array(request.argv.dropFirst(2)))
                XCTAssertNil(row.refusedBy, "the CLI accepted \(row)")
            } catch {
                let words = RNASeqExportSubcommand.message(for: error)
                XCTAssertTrue(
                    row.refusedBy.map { words.contains($0) } ?? false,
                    "the CLI refused \(row) in words that do not name its option: \(words)")
            }
        }
    }

    func testWithoutAProjectTheOutputDirectoryIsAskedFor() {
        let state = makeState(projectURL: nil)
        state.rnaSeqExport.resultURLs = [first]
        XCTAssertEqual(state.readinessText, "Choose where the export folder goes.")
        state.setOutputDirectory(scratch)
        XCTAssertEqual(state.readinessText, "Ready to run.")
    }

    func testTheExportRowShowsNoFASTQWordsAtAnyStep() {
        let state = makeState(projectURL: nil)
        func assertNoFASTQWords(_ step: String, line: UInt = #line) {
            for words in [state.readinessText, state.datasetLabel, state.selectedToolSummary] {
                for word in ["fastq", "reference", "read bundle"] {
                    XCTAssertFalse(words.localizedCaseInsensitiveContains(word), "\(step): \(words)", line: line)
                }
            }
        }
        assertNoFASTQWords("nothing chosen")
        state.rnaSeqExport.resultURLs = [first]
        assertNoFASTQWords("one result")
        state.rnaSeqExport.resultURLs = [first, second]
        XCTAssertEqual(state.datasetLabel, "2 RNA-seq results selected")
        assertNoFASTQWords("two results")
        state.setOutputDirectory(scratch)
        assertNoFASTQWords("ready")
    }

    // MARK: the request

    func testTheFieldsStartAtTheCLIsDefaultsAndAnEmptyBarMeansNone() throws {
        let state = makeState(projectURL: scratch)
        XCTAssertEqual(state.rnaSeqExport.cutoffText, "0.05")
        XCTAssertEqual(state.rnaSeqExport.lfcBarText, "")
        state.rnaSeqExport.resultURLs = [first]
        guard case .rnaSeqExport(let request) = try state.makeLaunchRequest() else { return XCTFail("not an export request") }
        XCTAssertEqual(request.padjCutoff, 0.05)
        XCTAssertNil(request.lfcBar)
        XCTAssertNil(request.batch)
        XCTAssertEqual(request.batchCorrection, .none)
        XCTAssertEqual(request.design, [])
        XCTAssertEqual(request.outputURL.lastPathComponent, "rnaseq-export")
        XCTAssertFalse(request.argv.contains("--lfc-bar"))
        XCTAssertTrue(request.argv.contains("0.05"), "the cutoff is always named")
    }

    func testMakeLaunchRequestGivesTheRequestOfThePaneAndItsArgvParsesThroughTheRealSubcommand() throws {
        let state = makeState(projectURL: scratch)
        let sheet = scratch.appendingPathComponent("sheet.tsv")
        state.rnaSeqExport.resultURLs = [first, second]
        state.rnaSeqExport.sampleSheetURL = sheet
        state.rnaSeqExport.designText = "batch, group"
        state.rnaSeqExport.contrastsText = "group:TB:HIV\ngroup:HIV:ctl\n"
        state.rnaSeqExport.cutoffText = "0.1"
        state.rnaSeqExport.lfcBarText = "1"
        state.rnaSeqExport.batchText = " batch "
        state.rnaSeqExport.batchCorrection = .combatSeq
        state.outputName = "de"
        let directory = try XCTUnwrap(state.outputDirectoryURL)
        let expected = RNASeqExportRunRequest(
            resultURLs: [first, second], outputURL: directory.appendingPathComponent("de", isDirectory: true),
            sampleSheetURL: sheet, design: ["batch", "group"], contrasts: ["group:TB:HIV", "group:HIV:ctl"],
            padjCutoff: 0.1, lfcBar: 1, batch: "batch", batchCorrection: .combatSeq)
        XCTAssertEqual(try state.makeLaunchRequest(), .rnaSeqExport(expected))
        let parsed = try RNASeqExportSubcommand.parse(Array(expected.argv.dropFirst(2)))
        XCTAssertEqual(parsed.resultPaths, [first.path, second.path])
        XCTAssertEqual(parsed.outputPath, directory.appendingPathComponent("de").path)
        XCTAssertEqual(parsed.sheetPath, sheet.path)
        XCTAssertEqual(parsed.design, ["batch", "group"])
        XCTAssertEqual(parsed.contrastWords, ["group:TB:HIV", "group:HIV:ctl"])
        XCTAssertEqual(parsed.padjCutoff, 0.1)
        XCTAssertEqual(parsed.lfcBar, 1)
        XCTAssertEqual(parsed.batch, "batch")
        XCTAssertEqual(parsed.batchCorrection, "combat-seq")
    }

    func testARunThatIsNotReadyThrowsTheReadinessWords() {
        let state = makeState(projectURL: scratch)
        XCTAssertThrowsError(try state.makeLaunchRequest()) { error in
            XCTAssertEqual(error as? WorkflowOperationError, .incompleteConfiguration("Select one or more RNA-seq results."))
        }
    }

    // MARK: the service

    func testABusyResultRefusesTheRowThroughTheDialogsServiceAndLaunchesNothing() async throws {
        let center = OperationCenter()
        _ = center.begin(
            title: "Holder", detail: "", operationType: .rnaSeqQuantification, targetBundleURL: first, cliCommand: nil,
            routeContext: nil)
        let request = RNASeqExportRunRequest(
            resultURLs: [first], outputURL: scratch.appendingPathComponent("de", isDirectory: true))
        let service = WorkflowOperationExecutionService(operationCenter: center)
        do {
            _ = try await service.run(.rnaSeqExport(request))
            XCTFail("a result under another row's lock was accepted")
        } catch LocalWorkflowExecutionError.bundleBusy(let words) {
            XCTAssertEqual(words, "The RNA-seq result is busy. Wait for its current operation to finish.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputURL.path), "nothing launched")
    }
}
