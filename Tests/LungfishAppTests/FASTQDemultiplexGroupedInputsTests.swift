// FASTQDemultiplexGroupedInputsTests.swift - A grouped run of several datasets of one format reads every one of them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane FIX-GROUP, backlog DEMUX-GROUPED-DROPS-INPUTS (S1). Output Strategy Grouped Result on two datasets
// of one format ran one command that named the first dataset only, so the reads of the second were in no sample and the
// row ended Completed with no words. A grouped run of several inputs is now one plan for each input whatever the formats
// (`FASTQOperationPlanner.splitExecutionRequestsIfNeeded`), each writing `<run>/<input stem>`, and the Operations row
// begins with a command script that names every input (`FASTQOperationExecutionService.buildInvocations`).
//
// This is the stand-in and needs no tool: a spy takes the place of the CLI, and the tests read the plans, the argv the
// service hands the spy and the command the row begins with. `FASTQDemultiplexGroupedInputsConformanceTests` runs the real
// cutadapt on the same two datasets and counts reads.

import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishOperations
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class FASTQDemultiplexGroupedInputsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), which the CLI is handed, so the paths the tests compare agree.
        let made = try TestTempDirectory.make(prefix: "demux-grouped-inputs")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixtures

    /// A reads bundle of one 60-base read in a project's Imports folder, as the sidebar hands it to the dialog.
    private func makePool(_ name: String) throws -> URL {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let bundle = try FASTQOperationTestHelper.makeBundle(named: name, in: imports)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 1, readLength: 60, idPrefix: name)
        return bundle.bundleURL
    }

    private var runFolder: URL {
        root.appendingPathComponent("Project.lungfish/Analyses/demultiplex-run", isDirectory: true)
    }

    /// The Demultiplex Barcodes request the dialog builds (`FASTQOperationDialogState`), with a built-in kit.
    private func demultiplexRequest(_ pools: [URL], mode: FASTQOperationOutputMode) -> FASTQOperationLaunchRequest {
        .derivative(
            request: .demultiplex(
                kitID: "illumina-nextera", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
            ),
            inputURLs: pools,
            outputMode: mode
        )
    }

    /// Registers the dialog row for `launch`, as the launch site does, and returns the command it begins with.
    private func commandAtBegin(of launch: FASTQOperationLaunchRequest, outputTargetPath: String) throws -> String {
        let reporter = RecordingOperationReporter()
        _ = try MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: \(launch.operationDisplayTitle)",
            request: launch,
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            outputTargetPath: outputTargetPath,
            reporter: reporter
        ) { _ in }.requireStarted()
        return try XCTUnwrap(reporter.items.first?.cliCommand)
    }

    // MARK: - The plans

    /// Two datasets of one format in a grouped run are one plan each. Before the fix the planner split a grouped run
    /// only when a FASTA and a FASTQ dataset mixed, so this was one plan that named the first pool.
    func testAGroupedDemultiplexOfTwoPoolsIsOnePlanForEachPool() throws {
        let (poolA, poolB) = (try makePool("poolA"), try makePool("poolB"))
        let request = demultiplexRequest([poolA, poolB], mode: .groupedResult)
        let plans = FASTQOperationPlanner().makeExecutionPlans(
            originalRequest: request, resolvedRequest: request, baseOutputDirectory: runFolder
        )

        XCTAssertEqual(plans.count, 2, "two datasets of one format are two plans: \(plans.map(\.outputTarget.path))")
        XCTAssertEqual(plans.map(\.resolvedRequest.inputURLs), [[poolA], [poolB]], "each plan reads one pool")
        XCTAssertEqual(
            plans.map(\.outputTarget.path),
            [runFolder.appendingPathComponent("poolA").path, runFolder.appendingPathComponent("poolB").path],
            "each plan writes <run>/<input stem>"
        )
    }

    /// One dataset is still the one command with the run folder in `-o`, which the one-input rows and records pin.
    func testAGroupedDemultiplexOfOnePoolStaysOneCommandWithTheRunFolder() async throws {
        let pool = try makePool("poolA")
        let request = demultiplexRequest([pool], mode: .groupedResult)
        let plans = FASTQOperationPlanner().makeExecutionPlans(
            originalRequest: request, resolvedRequest: request, baseOutputDirectory: runFolder
        )
        XCTAssertEqual(plans.map(\.outputTarget.path), [runFolder.path])

        let shown = try XCTUnwrap(
            RecordedCLICommand.parseScript(try commandAtBegin(of: request, outputTargetPath: runFolder.path)).first
                as? FastqDemultiplexSubcommand
        )
        XCTAssertEqual(shown.input, pool.path)
        XCTAssertEqual(shown.output, runFolder.path)
    }

    // MARK: - The run

    /// A run through the service: every pool is in exactly one command, and each command writes its own folder
    /// under the run. The spy makes the folder and one barcode file the way `fastq demultiplex` does.
    func testAGroupedDemultiplexRunHandsEachPoolToExactlyOneCommand() async throws {
        let (poolA, poolB) = (try makePool("poolA"), try makePool("poolB"))
        let request = demultiplexRequest([poolA, poolB], mode: .groupedResult)
        let runner = GroupedSpyCommandRunner { invocation, _ in
            let output = try XCTUnwrap(argumentValue(after: "-o", in: invocation))
            let folder = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let reads = folder.appendingPathComponent("S1.fastq")
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: reads, readCount: 1, readLength: 60)
            let pool = URL(fileURLWithPath: try XCTUnwrap(invocation.arguments.dropFirst().first))
            try writeGroupedSpyProvenance(
                to: folder, name: "lungfish fastq demultiplex", toolName: "cutadapt", invocation: invocation,
                inputURL: pool.appendingPathComponent("reads.fastq"), outputURL: reads
            )
            return FASTQCLIExecutionResult(outputURLs: [folder])
        }
        let service = FASTQOperationExecutionService(
            inputResolver: GroupedSpyInputResolver(resolvedRequest: request),
            commandRunner: runner,
            directImporter: GroupedSpyDirectImporter()
        )

        let result = try await service.execute(request: request, workingDirectory: runFolder)

        XCTAssertEqual(result.executedInvocations.count, 2, "one command for each pool")
        for pool in [poolA, poolB] {
            let naming = result.executedInvocations.filter { $0.arguments.contains(pool.path) }
            XCTAssertEqual(naming.count, 1, "\(pool.lastPathComponent) is in \(naming.count) commands")
        }
        XCTAssertEqual(
            result.executedInvocations.compactMap { argumentValue(after: "-o", in: $0) },
            [runFolder.appendingPathComponent("poolA").path, runFolder.appendingPathComponent("poolB").path],
            "each command writes <run>/<input stem>"
        )
        XCTAssertEqual(result.groupedContainerURL, runFolder, "the result is still the one grouped run folder")
    }

    /// One tool other than a demultiplex, measured: a grouped length filter of two datasets of one format read the
    /// first only for the same reason (`FASTQOperationCLIInvocationBuilder` names `inputURLs.first`).
    func testAGroupedLengthFilterOfTwoDatasetsRunsOneCommandForEach() async throws {
        let (poolA, poolB) = (try makePool("poolA"), try makePool("poolB"))
        let request = FASTQOperationLaunchRequest.derivative(
            request: .lengthFilter(min: 1, max: nil), inputURLs: [poolA, poolB], outputMode: .groupedResult
        )
        let runner = GroupedSpyCommandRunner { invocation, outputDirectory in
            let inputPath = try XCTUnwrap(invocation.arguments.dropFirst().first)
            let stem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
            let bundle = try FASTQOperationTestHelper.makeBundle(named: "filtered-\(stem)", in: outputDirectory)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 1, readLength: 60)
            try writeGroupedSpyProvenance(
                to: bundle.bundleURL, name: "lungfish fastq length-filter", toolName: "seqkit", invocation: invocation,
                inputURL: URL(fileURLWithPath: inputPath).appendingPathComponent("reads.fastq"), outputURL: bundle.fastqURL
            )
            return FASTQCLIExecutionResult(outputURLs: [bundle.bundleURL])
        }
        let service = FASTQOperationExecutionService(
            inputResolver: GroupedSpyInputResolver(resolvedRequest: request),
            commandRunner: runner,
            directImporter: GroupedSpyDirectImporter()
        )

        let result = try await service.execute(request: request, workingDirectory: runFolder)

        XCTAssertEqual(result.executedInvocations.count, 2, "one command for each dataset")
        for pool in [poolA, poolB] {
            let naming = result.executedInvocations.filter { $0.arguments.contains(pool.path) }
            XCTAssertEqual(naming.count, 1, "\(pool.lastPathComponent) is in \(naming.count) commands")
        }
    }

    // MARK: - The Operations row

    /// The row is begun with the command of the whole request, and Copy CLI Command gives that text for a run that
    /// fails. A grouped demultiplex of two pools is a script of two lines, one for each command that runs, and each
    /// line parses with the real CLI parser (docs/contracts/CLI-EQUIVALENCE.md, a command script).
    func testTheLaunchCommandOfAGroupedDemultiplexNamesEveryPool() throws {
        try assertTheLaunchCommandNamesEveryPool(mode: .groupedResult)
    }

    /// The per-input mode already ran one command for each pool but began its row with the first pool's command.
    func testTheLaunchCommandOfAPerInputDemultiplexNamesEveryPool() throws {
        try assertTheLaunchCommandNamesEveryPool(mode: .perInput)
    }

    private func assertTheLaunchCommandNamesEveryPool(
        mode: FASTQOperationOutputMode, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let (poolA, poolB) = (try makePool("poolA"), try makePool("poolB"))
        let row = try commandAtBegin(of: demultiplexRequest([poolA, poolB], mode: mode), outputTargetPath: runFolder.path)

        XCTAssertFalse(row.contains("<derived>"), row, file: file, line: line)
        let shown = try RecordedCLICommand.parseScript(row).compactMap { $0 as? FastqDemultiplexSubcommand }
        XCTAssertEqual(shown.map(\.input), [poolA.path, poolB.path], "one command line for each pool:\n\(row)", file: file, line: line)
        XCTAssertEqual(
            shown.map(\.output),
            [runFolder.appendingPathComponent("poolA").path, runFolder.appendingPathComponent("poolB").path],
            "each line writes <run>/<input stem>", file: file, line: line
        )
    }
}

/// The value after `flag` in the argv of `invocation`.
private func argumentValue(after flag: String, in invocation: FASTQCLIInvocation) -> String? {
    guard let index = invocation.arguments.firstIndex(of: flag), invocation.arguments.indices.contains(index + 1) else {
        return nil
    }
    return invocation.arguments[index + 1]
}

/// The record a CLI command leaves with its output, written with the builder the CLI uses. A grouped run refuses an
/// output that has none (`missingSourceProvenance`), so a spy that takes the place of the CLI writes one.
private func writeGroupedSpyProvenance(
    to directory: URL, name: String, toolName: String, invocation: FASTQCLIInvocation, inputURL: URL, outputURL: URL
) throws {
    let command = [CLICommandIdentity.executableName, invocation.subcommand] + invocation.arguments
    let startedAt = Date(timeIntervalSince1970: 1_800)
    let endedAt = Date(timeIntervalSince1970: 1_801.25)
    let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
    let output = try ProvenanceFileDescriptor.file(url: outputURL, format: .fastq, role: .output)
    let envelope = try ProvenanceRunBuilder(
        workflowName: name, workflowVersion: WorkflowRun.currentAppVersion, toolName: toolName, toolVersion: "1.0"
    )
    .argv(command)
    .options(explicit: [:], defaults: [:], resolved: [:])
    .input(inputURL, format: .fastq, role: .input)
    .output(outputURL, format: .fastq, role: .output)
    .step(
        ProvenanceStep(
            toolName: toolName, toolVersion: "1.0", argv: command, inputs: [input], outputs: [output],
            exitStatus: 0, wallTimeSeconds: 1.25, startedAt: startedAt, completedAt: endedAt
        )
    )
    .runtime(ProvenanceRuntimeIdentity.fixture())
    .complete(exitStatus: 0, startedAt: startedAt, endedAt: endedAt)
    try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
}

private final class GroupedSpyInputResolver: @unchecked Sendable, FASTQOperationInputResolving {
    let resolvedRequest: FASTQOperationLaunchRequest

    init(resolvedRequest: FASTQOperationLaunchRequest) {
        self.resolvedRequest = resolvedRequest
    }

    func resolve(request: FASTQOperationLaunchRequest, tempDirectory: URL) async throws -> FASTQOperationLaunchRequest {
        _ = (request, tempDirectory)
        return resolvedRequest
    }
}

private final class GroupedSpyDirectImporter: @unchecked Sendable, FASTQOperationDirectImporting {
    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL,
        progress: FASTQOperationImportProgressHandler?
    ) async throws -> [URL] {
        _ = (request, originalRequest, outputDirectory, progress)
        return outputURLs
    }
}

private final class GroupedSpyCommandRunner: @unchecked Sendable, FASTQOperationCommandRunning {
    private(set) var invocations: [FASTQCLIInvocation] = []
    private let handler: @Sendable (FASTQCLIInvocation, URL) throws -> FASTQCLIExecutionResult

    init(handler: @escaping @Sendable (FASTQCLIInvocation, URL) throws -> FASTQCLIExecutionResult) {
        self.handler = handler
    }

    func run(
        invocation: FASTQCLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        _ = progress
        invocations.append(invocation)
        return try handler(invocation, outputDirectory)
    }
}
