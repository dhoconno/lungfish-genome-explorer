// MainSplitFASTQImportOperationTests.swift - begin() sites in MainSplitViewController+FASTQImport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The two ONT import recipes that the import sheet routes to a FASTQ operation
// register their Operations panel row through `beginONTImportRecipeOperation`
// (R4). Neither declares a bundle lock, so a real center never refuses them,
// and a recording reporter that holds a lock stands in for the refusal. Both
// record a `lungfish-cli fastq` command that reproduces the run, so the tests
// parse it with the real CLI parser, compare it with the invocation the
// execution service runs for the same request and check the values.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class MainSplitFASTQImportOperationTests: XCTestCase {
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1a2l3/Project.lungfish"),
        windowStateScopeID: UUID()
    )
    private let runFolder = URL(fileURLWithPath: "/tmp/lane 1a2l3/Run 7/fastq_pass", isDirectory: true)
    private let barcodeSheet = URL(fileURLWithPath: "/tmp/lane 1a2l3/Run 7/barcodes.csv")
    private let outputFolder = URL(
        fileURLWithPath: "/tmp/lane 1a2l3/Project.lungfish/ONT Demultiplexed FASTQs",
        isDirectory: true
    )

    private var fluidigmRequest: FASTQOperationLaunchRequest {
        .ontFluidigmSampleSplit(
            inputFASTQURL: runFolder.standardizedFileURL,
            barcodeDefinitionsURL: barcodeSheet.standardizedFileURL,
            threads: 6
        )
    }

    private var pacBioRequest: FASTQOperationLaunchRequest {
        .ontPacBioBarcodeDemux(
            inputFASTQURL: runFolder.standardizedFileURL,
            barcodeDefinitionsURL: barcodeSheet.standardizedFileURL,
            threads: 1,
            chunkJobs: ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs,
            maxReadsPerSlice: 100_000,
            maxBytesPerCutadapt: 512 * 1024 * 1024
        )
    }

    /// Registers the row on a recording reporter and checks what both recipe
    /// rows share.
    private func recordedRow(
        _ request: FASTQOperationLaunchRequest,
        title: String,
        workingDirectory: URL? = nil
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        let result = MainSplitViewController.beginONTImportRecipeOperation(
            request: request,
            workingDirectory: workingDirectory ?? outputFolder,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, title)
        XCTAssertEqual(item.initialDetail, "Preparing...")
        XCTAssertEqual(item.operationType, .fastqOperation)
        XCTAssertNil(item.targetBundleURL, "the import locks no bundle")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        return item
    }

    /// Asserts that the recorded command carries `--threads count`.
    ///
    /// Both commands declare their own `--threads` option, which the real parser
    /// never delivers. The root command's global `--threads` option consumes the
    /// flag wherever it appears, so the subcommand keeps its default. The recorded
    /// string is right and the CLI drops the value, a defect for the CLI parity lane.
    private func assertRecordsThreads(
        _ command: String?,
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let words = try RecordedCLICommand.arguments(of: command)
        let index = try XCTUnwrap(words.firstIndex(of: "--threads"), "no --threads in \(words)", file: file, line: line)
        XCTAssertEqual(words[index + 1], String(count), file: file, line: line)
    }

    // MARK: - Fluidigm sample split (site 38)

    func testFluidigmSampleSplitRecordsAFASTQOperationRowWithItsRunnableCommand() throws {
        let item = try recordedRow(fluidigmRequest, title: "FASTQ: ONT Fluidigm Sample Split")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqONTFluidigmSamplesSubcommand.self)
        XCTAssertEqual(command.input, runFolder.standardizedFileURL.path)
        XCTAssertEqual(command.barcodes, barcodeSheet.standardizedFileURL.path)
        XCTAssertEqual(command.output, outputFolder.path, "the command names the folder the run writes into")
        try assertRecordsThreads(item.cliCommand, 6)
    }

    // MARK: - PacBio barcode demultiplex (site 39)

    func testPacBioBarcodeDemuxRecordsAFASTQOperationRowWithItsRunnableCommand() throws {
        let item = try recordedRow(pacBioRequest, title: "FASTQ: ONT PacBio Barcode Demultiplex")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqONTPacBioBarcodeDemuxSubcommand.self)
        XCTAssertEqual(command.input, runFolder.standardizedFileURL.path)
        XCTAssertEqual(command.barcodes, barcodeSheet.standardizedFileURL.path)
        XCTAssertEqual(command.output, outputFolder.path, "the command names the folder the run writes into")
        try assertRecordsThreads(item.cliCommand, 1)
        XCTAssertEqual(command.chunkJobs, ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs)
        XCTAssertEqual(command.maxReadsPerSlice, 100_000)
        XCTAssertEqual(command.maxBytesPerCutadapt, 512 * 1024 * 1024)
        XCTAssertFalse(command.force)
    }

    // MARK: - The command is the invocation the run executes

    /// Records every invocation the execution service hands its command runner
    /// and writes no output.
    private final class RecordingCommandRunner: @unchecked Sendable, FASTQOperationCommandRunning {
        private(set) var invocations: [FASTQCLIInvocation] = []

        func run(
            invocation: FASTQCLIInvocation,
            outputDirectory: URL,
            progress: @escaping FASTQOperationProgressHandler
        ) async throws -> FASTQCLIExecutionResult {
            invocations.append(invocation)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
    }

    func testRecordedCommandsAreTheInvocationsTheExecutionServiceRuns() async throws {
        let directory = try TestTempDirectory.make(prefix: "ont-import-recipe-operation")
        defer { TestTempDirectory.cleanup(directory) }

        let cases: [(String, FASTQOperationLaunchRequest, String)] = [
            ("Fluidigm sample split", fluidigmRequest, "FASTQ: ONT Fluidigm Sample Split"),
            ("PacBio barcode demultiplex", pacBioRequest, "FASTQ: ONT PacBio Barcode Demultiplex"),
        ]
        for (name, request, title) in cases {
            // `uniqueFASTQOperationOutputDirectory` picks a folder that does not exist
            // yet, which the CLI creates itself.
            let workingDirectory = directory.appendingPathComponent(
                "\(name) output", isDirectory: true
            )
            let item = try recordedRow(request, title: title, workingDirectory: workingDirectory)

            let runner = RecordingCommandRunner()
            _ = try await FASTQOperationExecutionService(commandRunner: runner)
                .execute(request: request, workingDirectory: workingDirectory)

            let invocation = try XCTUnwrap(runner.invocations.first, name)
            XCTAssertEqual(runner.invocations.count, 1, name)
            XCTAssertEqual(
                item.cliCommand,
                OperationCenter.buildCLICommand(subcommand: invocation.subcommand, args: invocation.arguments),
                "\(name) records the invocation the run executes"
            )
            let words = try RecordedCLICommand.arguments(of: item.cliCommand)
            let outputIndex = try XCTUnwrap(words.firstIndex(of: "--output"), name)
            XCTAssertEqual(words[outputIndex + 1], workingDirectory.path, "\(name) writes into its working directory")
        }
    }

    // MARK: - Refused rows

    func testRefusedRowsLaunchNothing() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let fluidigm = MainSplitViewController.beginONTImportRecipeOperation(
            request: fluidigmRequest,
            workingDirectory: outputFolder,
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }
        let pacBio = MainSplitViewController.beginONTImportRecipeOperation(
            request: pacBioRequest,
            workingDirectory: outputFolder,
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(fluidigm.startedID)
        XCTAssertNil(pacBio.startedID)
        XCTAssertFalse(launched)
        XCTAssertEqual(reporter.items.map(\.state), [.refused, .refused])
    }
}
