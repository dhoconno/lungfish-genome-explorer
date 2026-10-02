// ONTImportOperationCoordinatorOperationTests.swift - The ONT import's Operations panel row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `ONTImportOperationCoordinator` takes its reporter as a parameter (R4), so
// these tests watch the row without touching `OperationCenter.shared`. The
// import locks no bundle, and a reporter that refuses every begin proves that
// a refused row imports nothing. The recorded command is
// `lungfish-cli fastq import-ont`, which reproduces the run, so it must parse
// with the values the run uses.

import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ONTImportOperationCoordinatorOperationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = try TestTempDirectory.make(prefix: "ont-import-operation")
    }

    override func tearDown() {
        if let tempDirectory {
            TestTempDirectory.cleanup(tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Recorded row

    func testImportRecordsAnIngestionRowWithNoLockAndARunnableCommand() async throws {
        let reporter = RecordingOperationReporter()
        let sourceURL = try makeONTSource()
        let projectURL = tempDirectory.appendingPathComponent("project", isDirectory: true)
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
        let coordinator = ONTImportOperationCoordinator(operationCenter: reporter)

        let result = try await coordinator.importDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: true,
            concurrency: 1,
            storageMode: .flattened,
            routeContext: routeContext
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(item.title, "ONT Import: fastq_pass")
        XCTAssertEqual(item.initialDetail, "Detecting layout...")
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.bundleURLs, result.importResult.bundleURLs)

        let expectedOutputURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(tempDirectory.lastPathComponent, isDirectory: true)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqImportONTSubcommand.self)
        XCTAssertEqual(command.input, sourceURL.path)
        XCTAssertEqual(command.output, expectedOutputURL.path)
        XCTAssertTrue(command.includeUnclassified)
        XCTAssertEqual(command.concurrency, 1)
        XCTAssertEqual(command.storageMode, .flattened)
        XCTAssertFalse(command.optimizeStorage)
        XCTAssertEqual(command.qualityBinning, .none)
    }

    func testEveryImportOptionReachesTheRecordedCommand() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Run 7/fastq_pass", isDirectory: true)
        let outputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish/Imports/Run 7", isDirectory: true)
        let arguments = ONTImportOperationCoordinator.cliArgs(
            sourceURL: sourceURL,
            outputURL: outputURL,
            includeUnclassified: true,
            concurrency: 2,
            storageMode: .flattened,
            optimizeStorage: true,
            qualityBinning: .illumina4
        )

        let command = try RecordedCLICommand.parse(
            OperationCenter.buildCLICommand(subcommand: "fastq import-ont", args: arguments),
            as: FastqImportONTSubcommand.self
        )

        XCTAssertEqual(command.input, sourceURL.path)
        XCTAssertEqual(command.output, outputURL.path)
        XCTAssertTrue(command.includeUnclassified)
        XCTAssertEqual(command.concurrency, 2)
        XCTAssertEqual(command.storageMode, .flattened)
        XCTAssertTrue(command.optimizeStorage)
        XCTAssertEqual(command.qualityBinning, .illumina4)
    }

    // MARK: - Refused row

    func testRefusedRowImportsNothing() async throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        let sourceURL = try makeONTSource()
        let projectURL = tempDirectory.appendingPathComponent("project", isDirectory: true)
        let coordinator = ONTImportOperationCoordinator(operationCenter: reporter)

        do {
            _ = try await coordinator.importDirectory(
                sourceURL: sourceURL,
                projectURL: projectURL,
                includeUnclassified: false,
                concurrency: 1,
                routeContext: nil
            )
            XCTFail("a refused begin must stop the import")
        } catch let refused as OperationRefusedError {
            XCTAssertEqual(refused.refusal.blockingOperationTitle, "Importing BAM")
        }

        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        XCTAssertTrue(reporter.items[0].logs.isEmpty, "a refused import reports nothing further")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: projectURL.path),
            "a refused import writes nothing into the project"
        )
    }

    // MARK: - Fixture

    private func makeONTSource() throws -> URL {
        let sourceURL = tempDirectory.appendingPathComponent("fastq_pass", isDirectory: true)
        let text = """
        @read1 runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=barcode01 basecall_model_version_id=dorado-test
        ACGT
        +
        !!!!

        """
        for folder in ["barcode01", "unclassified"] {
            let directory = sourceURL.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: directory.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        }
        return sourceURL
    }
}
