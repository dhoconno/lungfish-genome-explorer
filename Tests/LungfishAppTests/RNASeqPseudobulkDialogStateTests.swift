// RNASeqPseudobulkDialogStateTests.swift - The pseudobulk row of the Workflow Operations dialog, its state half (RS-DIALOG-M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.4, lane RS-DIALOG-M2. `RNASeqPseudobulkDialogTests` holds the request, the route and the built-CLI cases. This class holds
// what the dialog adds. The row is a tool of the Workflow Operations dialog, the readiness words name what is missing, the folder
// gets the extension the CLI requires once, the launch request is the request of the pane and its argv parses through the real
// subcommand, and a busy result refuses the row through the dialog's own service and launches nothing.

import Foundation
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow

@MainActor
final class RNASeqPseudobulkDialogStateTests: XCTestCase {
    private var scratch: URL!
    private let single = URL(fileURLWithPath: "/tmp/pb-state/Analyses/cells.lungfishrnaseq", isDirectory: true)
    private let labels = URL(fileURLWithPath: "/tmp/pb-state/labels.tsv")

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "rnaseq-pseudobulk-state")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private func makeState(projectURL: URL?) -> WorkflowOperationDialogState {
        let defaults = makeTestDefaultsSuite(prefix: "RNASeqPseudobulkDialogStateTests").defaults
        return WorkflowOperationDialogState(
            projectURL: projectURL,
            initialToolID: WorkflowLibraryCatalog.rnaSeqPseudobulkID,
            enablementStore: WorkflowLibraryEnablementStore(userDefaults: defaults),
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults))
    }

    func testSelectingTheRowSetsItsNameAndKeepsTheOutputDirectoryInAnalyses() {
        let state = makeState(projectURL: scratch)
        XCTAssertEqual(state.selectedTool?.kind, .rnaSeqPseudobulk)
        XCTAssertEqual(state.outputName, "pseudobulk")
        XCTAssertEqual(state.outputDirectoryURL?.lastPathComponent, "Analyses")
        state.selectTool(WorkflowLibraryCatalog.rnaSeqExportID)
        XCTAssertEqual(state.selectedTool?.kind, .rnaSeqExport)
        XCTAssertEqual(state.outputName, "rnaseq-export")
        state.selectTool(WorkflowLibraryCatalog.rnaSeqPseudobulkID)
        XCTAssertEqual(state.outputName, "pseudobulk")
        XCTAssertTrue(state.selectedToolIsRNASeq)
    }

    func testReadinessNamesWhatIsMissingInOrder() {
        let state = makeState(projectURL: nil)
        XCTAssertEqual(state.readinessText, "Select a single-cell RNA-seq result.")
        state.rnaSeqPseudobulk.resultURL = single
        XCTAssertEqual(state.readinessText, "Choose a labels table.")
        state.rnaSeqPseudobulk.labelsURL = labels
        XCTAssertEqual(state.readinessText, "Choose where the pseudobulk result goes.")
        state.setOutputDirectory(scratch)
        XCTAssertEqual(state.readinessText, "Ready to run.")
        XCTAssertTrue(state.isRunEnabled)
        state.outputName = " "
        XCTAssertEqual(state.readinessText, "Enter a name for the pseudobulk result.")
    }

    func testTheRowShowsNoFASTQWordsAtAnyStep() {
        let state = makeState(projectURL: nil)
        func assertNoFASTQWords(_ step: String, line: UInt = #line) {
            for words in [state.readinessText, state.datasetLabel, state.selectedToolSummary] {
                for word in ["fastq", "reference", "read bundle"] {
                    XCTAssertFalse(words.localizedCaseInsensitiveContains(word), "\(step): \(words)", line: line)
                }
            }
        }
        assertNoFASTQWords("nothing chosen")
        state.rnaSeqPseudobulk.resultURL = single
        XCTAssertEqual(state.datasetLabel, "cells.lungfishrnaseq")
        assertNoFASTQWords("result chosen")
        state.rnaSeqPseudobulk.labelsURL = labels
        assertNoFASTQWords("labels chosen")
    }

    func testMakeLaunchRequestAddsTheExtensionOnceAndItsArgvParsesThroughTheRealSubcommand() throws {
        let state = makeState(projectURL: scratch)
        state.rnaSeqPseudobulk.resultURL = single
        state.rnaSeqPseudobulk.labelsURL = labels
        state.outputName = "pb1"
        let directory = try XCTUnwrap(state.outputDirectoryURL)
        let expected = RNASeqPseudobulkRunRequest(
            resultURL: single, labelsURL: labels,
            outputURL: directory.appendingPathComponent("pb1.lungfishrnaseq", isDirectory: true))
        XCTAssertEqual(try state.makeLaunchRequest(), .rnaSeqPseudobulk(expected))
        state.outputName = "pb1.lungfishrnaseq"
        XCTAssertEqual(try state.makeLaunchRequest(), .rnaSeqPseudobulk(expected), "the extension is added once")
        let parsed = try RNASeqPseudobulkSubcommand.parse(Array(expected.argv.dropFirst(2)))
        XCTAssertEqual(parsed.resultPath, single.path)
        XCTAssertEqual(parsed.labelsPath, labels.path)
        XCTAssertEqual(parsed.outputPath, directory.appendingPathComponent("pb1.lungfishrnaseq").path)
    }

    func testARunThatIsNotReadyThrowsTheReadinessWords() {
        let state = makeState(projectURL: scratch)
        XCTAssertThrowsError(try state.makeLaunchRequest()) { error in
            XCTAssertEqual(error as? WorkflowOperationError, .incompleteConfiguration("Select a single-cell RNA-seq result."))
        }
    }

    func testABusyResultRefusesTheRowThroughTheDialogsServiceAndLaunchesNothing() async throws {
        let center = OperationCenter()
        _ = center.begin(
            title: "Holder", detail: "", operationType: .rnaSeqQuantification, targetBundleURL: single, cliCommand: nil,
            routeContext: nil)
        let request = RNASeqPseudobulkRunRequest(
            resultURL: single, labelsURL: labels,
            outputURL: scratch.appendingPathComponent("pb1.lungfishrnaseq", isDirectory: true))
        let service = WorkflowOperationExecutionService(operationCenter: center)
        do {
            _ = try await service.run(.rnaSeqPseudobulk(request))
            XCTFail("a result under another row's lock was accepted")
        } catch LocalWorkflowExecutionError.bundleBusy(let words) {
            XCTAssertEqual(words, "The RNA-seq result is busy. Wait for its current operation to finish.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputURL.path), "nothing launched")
    }

    // MARK: Import Embedding (CM-IMPORT-APP)

    private let projection = URL(fileURLWithPath: "/tmp/pb-state/given/projection.csv")
    private let clusters = URL(fileURLWithPath: "/tmp/pb-state/given/clusters.csv")

    private func makeImportState(projectURL: URL?) -> WorkflowOperationDialogState {
        let defaults = makeTestDefaultsSuite(prefix: "RNASeqPseudobulkDialogStateTests").defaults
        return WorkflowOperationDialogState(
            projectURL: projectURL,
            initialToolID: WorkflowLibraryCatalog.rnaSeqCellMapImportID,
            enablementStore: WorkflowLibraryEnablementStore(userDefaults: defaults),
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults))
    }

    func testSelectingTheImportRowNamesTheCellMapAndReadinessNamesWhatIsMissingInOrder() {
        let state = makeImportState(projectURL: nil)
        XCTAssertEqual(state.selectedTool?.kind, .rnaSeqCellMapImport)
        XCTAssertEqual(state.outputName, "cell-map")
        XCTAssertTrue(state.selectedToolIsRNASeq)
        XCTAssertEqual(state.readinessText, "Select a single-cell RNA-seq result.")
        state.rnaSeqCellMapImport.resultURL = single
        XCTAssertEqual(state.datasetLabel, "cells.lungfishrnaseq")
        XCTAssertEqual(state.readinessText, "Choose a coordinates file.")
        state.rnaSeqCellMapImport.coordinateURLs = [projection]
        XCTAssertEqual(state.readinessText, "Choose where the cell map goes.")
        state.setOutputDirectory(scratch)
        XCTAssertEqual(state.readinessText, "Ready to run.")
        XCTAssertTrue(state.isRunEnabled)
        state.outputName = " "
        XCTAssertEqual(state.readinessText, "Enter a name for the cell map.")
    }

    func testTheImportLaunchRequestCarriesTheFlagsAddsTheExtensionOnceAndItsArgvParses() throws {
        let state = makeImportState(projectURL: scratch)
        state.rnaSeqCellMapImport.resultURL = single
        state.rnaSeqCellMapImport.coordinateURLs = [projection]
        state.rnaSeqCellMapImport.clusterURLs = [clusters]
        state.rnaSeqCellMapImport.labelColumnsText = "clusters, celltype"
        state.rnaSeqCellMapImport.barcodeSuffix = .drop
        state.rnaSeqCellMapImport.skipBarcodesNotHeld = true
        state.rnaSeqCellMapImport.otherCounts = true
        state.rnaSeqCellMapImport.tool = " Seurat "
        state.rnaSeqCellMapImport.toolVersion = "5.5.1"
        state.outputName = "map1"
        let directory = try XCTUnwrap(state.outputDirectoryURL)
        let expected = RNASeqCellMapImportRunRequest(
            resultURL: single, coordinateURLs: [projection], clusterURLs: [clusters], labelColumns: ["clusters", "celltype"],
            barcodeSuffix: .drop, skipBarcodesNotHeld: true, otherCounts: true, tool: "Seurat", toolVersion: "5.5.1",
            outputURL: directory.appendingPathComponent("map1.lungfishrnaseq", isDirectory: true))
        XCTAssertEqual(try state.makeLaunchRequest(), .rnaSeqCellMapImport(expected))
        state.outputName = "map1.lungfishrnaseq"
        XCTAssertEqual(try state.makeLaunchRequest(), .rnaSeqCellMapImport(expected), "the extension is added once")
        let parsed = try RNASeqCellMapImportSubcommand.parse(Array(expected.argv.dropFirst(3)))
        XCTAssertEqual(parsed.outputPath, directory.appendingPathComponent("map1.lungfishrnaseq").path)
        XCTAssertEqual(parsed.barcodeSuffix, .drop)
        XCTAssertEqual(parsed.labelColumns, ["clusters", "celltype"])
        XCTAssertTrue(parsed.skipBarcodesNotHeld)
        XCTAssertTrue(parsed.otherCounts)
        XCTAssertEqual(parsed.tool, "Seurat")
    }

    func testABusyResultRefusesTheImportRowThroughTheDialogsServiceAndLaunchesNothing() async throws {
        let center = OperationCenter()
        _ = center.begin(
            title: "Holder", detail: "", operationType: .rnaSeqQuantification, targetBundleURL: single, cliCommand: nil,
            routeContext: nil)
        let request = RNASeqCellMapImportRunRequest(
            resultURL: single, coordinateURLs: [projection],
            outputURL: scratch.appendingPathComponent("map1.lungfishrnaseq", isDirectory: true))
        let service = WorkflowOperationExecutionService(operationCenter: center)
        do {
            _ = try await service.run(.rnaSeqCellMapImport(request))
            XCTFail("a result under another row's lock was accepted")
        } catch LocalWorkflowExecutionError.bundleBusy(let words) {
            XCTAssertEqual(words, "The RNA-seq result is busy. Wait for its current operation to finish.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputURL.path), "nothing launched")
    }
}
