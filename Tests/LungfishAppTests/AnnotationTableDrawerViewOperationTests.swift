// AnnotationTableDrawerViewOperationTests.swift - begin() sites in AnnotationTableDrawerView
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Every stored variant edit (deleting variants, deleting all variants and
// importing sample metadata) registers one row through a static begin helper
// (R4), locks the bundle and records the lungfish-cli command that reproduces
// it (Phase 2.10 lane A43, plan decision C3): `variants delete` for the two
// deletions and `variants import-sample-metadata` for the import. A held bundle
// lock must refuse the row and launch nothing. The rows parse with the real
// parser. VariantStorageWorkerOwnershipTests covers the worker's lease and
// publication, and VariantEditRouteParityTests and
// VariantSampleMetadataCLIGUIParityReplayTests replay the rows.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishOperations
import LungfishWorkflow

@MainActor
final class AnnotationTableDrawerViewOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Sample.lungfishref", isDirectory: true)
    private let metadataURL = URL(fileURLWithPath: "/tmp/lane 1a2/sample data.csv")

    /// A fresh center whose bundle lock is already held, as when another
    /// operation is running on the same bundle.
    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Calling variants with LoFreq",
            detail: "Running",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli variants call"
        ).startedID)
        return center
    }

    func testVariantStorageMutationRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = AnnotationTableDrawerView.beginVariantStorageMutationOperation(
            title: "Variant deletion",
            bundleURL: bundleURL,
            command: VariantDeletionMutationService.deleteAllArguments(bundleURL: bundleURL),
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the stored variant edit")
        }
        XCTAssertFalse(launched, "a refused row must start no worker")
        XCTAssertEqual(refusal.blockingOperationTitle, "Calling variants with LoFreq")
    }

    func testVariantStorageMutationRecordsItsTypeLockAndTheCommandThatReproducesIt() throws {
        let selection: [String: [Int64]] = ["track A": [9, 2], "trackB": [4]]
        let edits: [(title: String, command: [String])] = [
            ("Variant deletion", VariantDeletionMutationService.deleteSelectedArguments(bundleURL: bundleURL, idsByTrack: selection)),
            ("Delete all variants", VariantDeletionMutationService.deleteAllArguments(bundleURL: bundleURL)),
            ("Sample metadata import", VariantSampleMetadataImportService.importMetadataArguments(
                metadataURL: metadataURL, format: .csv, bundleURL: bundleURL
            ) + ["--format", "json"]),
        ]
        var commands: [String: String] = [:]
        for edit in edits {
            let reporter = RecordingOperationReporter()
            let routeContext = OperationRouteContext(
                projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
                windowStateScopeID: UUID()
            )
            var launchedID: UUID?

            AnnotationTableDrawerView.beginVariantStorageMutationOperation(
                title: edit.title,
                bundleURL: bundleURL,
                command: edit.command,
                routeContext: routeContext,
                reporter: reporter
            ) { launchedID = $0 }

            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertEqual(launchedID, item.id)
            XCTAssertEqual(item.title, edit.title)
            XCTAssertEqual(item.initialDetail, "Updating stored data and provenance")
            XCTAssertEqual(item.operationType, .workflow)
            XCTAssertEqual(item.targetBundleURL, bundleURL)
            XCTAssertEqual(item.additionalLockedBundleURLs, [])
            XCTAssertEqual(item.routeContext, routeContext)
            commands[edit.title] = try XCTUnwrap(item.cliCommand, "\(edit.title) records the command that reproduces it")
        }

        let selected = try RecordedCLICommand.parse(commands["Variant deletion"], as: VariantsCommand.DeleteSubcommand.self)
        XCTAssertEqual(selected.bundle, bundleURL.path)
        XCTAssertFalse(selected.all)
        XCTAssertEqual(selected.variantIDs, ["track A:2", "track A:9", "trackB:4"], "each row travels with its track")

        let all = try RecordedCLICommand.parse(commands["Delete all variants"], as: VariantsCommand.DeleteSubcommand.self)
        XCTAssertEqual(all.bundle, bundleURL.path)
        XCTAssertTrue(all.all)
        XCTAssertEqual(all.variantIDs, [])

        let metadata = try RecordedCLICommand.parse(
            commands["Sample metadata import"], as: VariantsCommand.ImportSampleMetadataSubcommand.self
        )
        XCTAssertEqual(metadata.bundle, bundleURL.path)
        XCTAssertEqual(metadata.metadataFile, metadataURL.path)
        XCTAssertEqual(metadata.metadataFormat, "csv", "the row names the format it read the file as")
        XCTAssertEqual(metadata.globalOptions.outputFormat, .json, "the launched command writes events")
    }

    /// The drawer's own entry point registers its row through the helper, on
    /// the center it is given, and runs the worker only for a started row.
    func testRunVariantStorageMutationRegistersItsRowThroughTheHelper() async throws {
        _ = NSApplication.shared
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()

        let task = try XCTUnwrap(drawer.runVariantStorageMutation(
            title: "Variant deletion",
            bundleURL: bundleURL,
            command: VariantDeletionMutationService.deleteAllArguments(bundleURL: bundleURL),
            center: center,
            work: { 7 },
            publish: { _ in }
        ))

        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.title, "Variant deletion")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        _ = try RecordedCLICommand.parse(item.cliCommand, as: VariantsCommand.DeleteSubcommand.self)
        await task.value
        XCTAssertEqual(center.items.first?.state, .completed)
        XCTAssertTrue(center.canStartOperation(on: bundleURL))
    }

    /// The import registers its row with the command it launches, and a command that fails fails
    /// the row with today's words and frees the bundle. The "CLI" is `/usr/bin/false`, so this test
    /// launches no lungfish-cli (VariantSampleMetadataCLIGUIParityReplayTests runs the built one).
    func testImportSampleMetadataRecordsItsLaunchedCommandAndFailsTheRowWhenTheCommandFails() async throws {
        _ = NSApplication.shared
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()

        let task = try XCTUnwrap(drawer.importSampleMetadata(
            fileURL: metadataURL, format: .csv, bundleURL: bundleURL,
            center: center, cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")
        ))

        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.title, "Sample metadata import")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        let metadata = try RecordedCLICommand.parse(item.cliCommand, as: VariantsCommand.ImportSampleMetadataSubcommand.self)
        XCTAssertEqual(metadata.metadataFile, metadataURL.path)
        XCTAssertEqual(metadata.metadataFormat, "csv")
        await task.value
        XCTAssertEqual(center.items.first?.state, .failed)
        XCTAssertEqual(center.items.first?.errorMessage?.isEmpty, false, "the row carries the command's failure")
        XCTAssertTrue(center.canStartOperation(on: bundleURL), "a failed import frees the bundle lock")
    }
}
