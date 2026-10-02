// AssemblyConfigurationViewModelOperationTests.swift - begin() site in AssemblyRunner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The managed assembly launch registers its row through a static begin helper
// (R4). The row locks no bundle, so a reporter that refuses every begin stands
// in for a refusal and proves the launch closure sits behind the `.started`
// case. The recorded command is `lungfish-cli assemble`, built from the
// normalized request and the run's own output folder, and it must parse with
// the values the run uses.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class AssemblyConfigurationViewModelOperationTests: XCTestCase {
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1a2g/Project.lungfish"),
        windowStateScopeID: UUID()
    )
    private let outputDirectory = URL(fileURLWithPath: "/tmp/lane 1a2g/Assembly Output", isDirectory: true)

    /// The folder the managed pipeline writes to, `<output>/<project name>`.
    private func pipelineDirectory(for request: AssemblyRunRequest) -> URL {
        outputDirectory.appendingPathComponent(request.projectName, isDirectory: true)
    }

    func testAssemblyRecordsItsRowAndARunnableAssembleCommand() throws {
        let reporter = RecordingOperationReporter()
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/lane 1a2g/Reads/Sample R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/lane 1a2g/Reads/Sample R2.fastq.gz"),
            ],
            projectName: "Mito Assembly",
            outputDirectory: outputDirectory,
            pairedEnd: true,
            threads: 4,
            memoryGB: 8,
            minContigLength: 500,
            selectedProfileID: "meta",
            extraArguments: ["--only-assembler", "--cov-cutoff", "auto"]
        ).normalizedForExecution()
        let runDirectory = pipelineDirectory(for: request)
        var launchedID: UUID?

        let result = AssemblyRunner.beginAssemblyOperation(
            request: request,
            outputDirectory: runDirectory,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "SPAdes Assembly: Mito Assembly")
        XCTAssertEqual(item.initialDetail, "Initializing...")
        XCTAssertEqual(item.operationType, .assembly)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: AssembleCommand.self)
        XCTAssertEqual(command.fastqFiles, request.inputURLs.map(\.path))
        XCTAssertTrue(command.pairedEnd)
        XCTAssertEqual(command.assembler, "spades")
        XCTAssertEqual(command.readType, "illumina-short-reads")
        XCTAssertEqual(command.projectName, "Mito Assembly")
        XCTAssertEqual(command.outputDir, runDirectory.path, "the command names the folder the pipeline writes to")
        XCTAssertEqual(command.memoryGB, 8)
        XCTAssertEqual(command.minContigLength, 500)
        XCTAssertEqual(command.profile, "meta")
        XCTAssertEqual(command.extraArgs, AdvancedCommandLineOptions.join(request.extraArguments))
        XCTAssertTrue(command.jsonEvents)
        // The root command's global `--threads` option consumes the flag, so the
        // parsed command cannot show it. The recorded string carries it.
        let words = try RecordedCLICommand.arguments(of: item.cliCommand)
        let threadsIndex = try XCTUnwrap(words.firstIndex(of: "--threads"), "no --threads in \(words)")
        XCTAssertEqual(words[threadsIndex + 1], String(request.threads))
    }

    func testSingleInputLongReadAssemblyRecordsAParsableAssembleCommand() throws {
        let reporter = RecordingOperationReporter()
        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .ontReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/lane 1a2g/Reads/ont reads.fastq.gz")],
            projectName: "Long Reads",
            outputDirectory: outputDirectory,
            threads: 6,
            selectedProfileID: "nano-hq",
            profileSelectionBasis: "Median read quality is above Q20"
        ).normalizedForExecution()
        let runDirectory = pipelineDirectory(for: request)

        AssemblyRunner.beginAssemblyOperation(
            request: request,
            outputDirectory: runDirectory,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "Flye Assembly: Long Reads")
        XCTAssertNil(item.routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: AssembleCommand.self)
        XCTAssertEqual(command.fastqFiles, [request.inputURLs[0].path])
        XCTAssertFalse(command.pairedEnd)
        XCTAssertEqual(command.assembler, "flye")
        XCTAssertEqual(command.readType, "ont-reads")
        XCTAssertEqual(command.projectName, "Long Reads")
        XCTAssertEqual(command.outputDir, runDirectory.path)
        XCTAssertEqual(command.profile, "nano-hq")
        XCTAssertEqual(command.profileBasis, "Median read quality is above Q20")
        XCTAssertNil(command.memoryGB)
        XCTAssertNil(command.minContigLength)
        XCTAssertEqual(command.extraArgs, "")
    }

    func testRefusedAssemblyLaunchesNothing() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/lane 1a2g/Reads/Sample.fastq.gz")],
            projectName: "Refused",
            outputDirectory: outputDirectory,
            threads: 2
        )
        var launched = false

        let result = AssemblyRunner.beginAssemblyOperation(
            request: request,
            outputDirectory: pipelineDirectory(for: request),
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(result.startedID)
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
