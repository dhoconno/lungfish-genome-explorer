// AssemblyRunPlanningTests.swift - An assembly that names a bundle's files runs once, as lungfish-cli assemble reads it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
import LungfishTestSupport

/// The FASTQ operations service plans an assembly request into the
/// `lungfish-cli assemble` runs it launches. `assemble` reads any file of a
/// bundle as that whole bundle, so each recorded run goes through the CLI's
/// own parser, its checks before resolution and its input resolution, and the
/// tests compare the reads every run assembles (R3, lane 1q).
final class AssemblyRunPlanningTests: XCTestCase {

    private var root: URL!
    private var shapes: AssemblyBundleShapes!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assembly-run-planning")
        shapes = try AssemblyBundleShapes(in: root.appendingPathComponent("Project.lungfish", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The per-bundle batch names a multi-file bundle by its chunk files. Split
    /// one run per chunk, each run assembled the whole bundle again.
    func testTheFilesOfOneBundleAreAssembledInOneRun() async throws {
        let runs = try await cliRuns(of: assembly(.spades, .illuminaShortReads, inputs: shapes.multiFileChunks))
        XCTAssertEqual(runs.map(\.reads), [[["m1", "m2", "m3", "m4", "m5"]]], "the bundle once, not once per chunk")
    }

    /// Per-input mode still gives each loose file and each bundle its own run.
    func testLooseFilesAndSeparateBundlesAreStillAssembledOneRunEach() async throws {
        let loose = try await cliRuns(of: assembly(.spades, .illuminaShortReads, inputs: shapes.looseFiles))
        XCTAssertEqual(loose.map(\.reads), [[["a1"]], [["b1", "b2"]]])

        let bundles = try await cliRuns(of: assembly(.megahit, .illuminaShortReads, inputs: [shapes.single, shapes.multiFile]))
        XCTAssertEqual(bundles.map(\.reads), [[["s1", "s2", "s3"]], [["m1", "m2", "m3", "m4", "m5"]]])
    }

    // MARK: - Helpers

    /// One `lungfish-cli assemble` run as the CLI reads it.
    private struct CLIRun {
        /// The record names of each file the assembler is handed, in order.
        let reads: [[String]]
        /// Whether the assembler receives the files as R1/R2 mates.
        let pairs: Bool
    }

    private func assembly(
        _ tool: AssemblyTool,
        _ readType: AssemblyReadType,
        inputs: [URL],
        pairedEnd: Bool = false
    ) -> FASTQOperationLaunchRequest {
        .assemble(
            request: AssemblyRunRequest(
                tool: tool,
                readType: readType,
                inputURLs: inputs,
                projectName: "planned",
                outputDirectory: root.appendingPathComponent("unused-output", isDirectory: true),
                pairedEnd: pairedEnd,
                threads: 1
            ),
            outputMode: .perInput
        )
    }

    /// Executes `request` with a runner that records each `lungfish-cli`
    /// invocation, then reads every invocation the way `AssembleCommand.run`
    /// does: the shipped parser, the checks made before anything is resolved,
    /// the input resolution and the pairing.
    private func cliRuns(of request: FASTQOperationLaunchRequest) async throws -> [CLIRun] {
        let runner = RecordingAssembleRunner()
        let workingDirectory = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        _ = try await FASTQOperationExecutionService(commandRunner: runner)
            .execute(request: request, workingDirectory: workingDirectory)

        var runs: [CLIRun] = []
        for invocation in runner.invocations {
            XCTAssertEqual(invocation.subcommand, "assemble")
            let command = try RecordedCLICommand.parse(
                OperationCenter.buildCLICommand(subcommand: invocation.subcommand, args: invocation.arguments),
                as: AssembleCommand.self
            )
            let tool = try XCTUnwrap(AssemblyTool(rawValue: command.assembler))
            let inputs = command.fastqFiles.map { URL(fileURLWithPath: $0) }
            try AssembleCommand.validatePreMaterializationTopology(
                tool: tool,
                inputURLs: inputs,
                pairedEnd: command.pairedEnd
            )
            let resolved = try await AssembleCommand.resolveExecutionInputs(
                for: inputs,
                tempDirectory: root.appendingPathComponent("cli-\(UUID().uuidString)/.lungfish-assembly-inputs", isDirectory: true),
                materializer: FASTQCLIMaterializer(runner: .shared)
            )
            runs.append(CLIRun(
                reads: try resolved.executionInputURLs.map(AssemblyBundleShapes.readNames(in:)),
                pairs: command.pairedEnd || resolved.resolvedAsMatePair
            ))
        }
        return runs
    }
}

/// Records every `lungfish-cli` invocation and reports the run's output folder.
private final class RecordingAssembleRunner: @unchecked Sendable, FASTQOperationCommandRunning {
    private let lock = NSLock()
    private var recorded: [FASTQCLIInvocation] = []

    var invocations: [FASTQCLIInvocation] { lock.withLock { recorded } }

    func run(
        invocation: FASTQCLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        lock.withLock { recorded.append(invocation) }
        return FASTQCLIExecutionResult(outputURLs: [outputDirectory])
    }
}
