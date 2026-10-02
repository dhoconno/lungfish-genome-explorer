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

    /// Flye and hifiasm take one input. The chunks of one bundle are one
    /// input, the bundle, whose chunks `lungfish-cli assemble` joins.
    func testFlyeAndHifiasmAssembleTheFilesOfOneBundleAsThatBundle() async throws {
        for (tool, readType) in [(AssemblyTool.flye, AssemblyReadType.ontReads), (.hifiasm, .pacBioHiFi)] {
            let runs = try await cliRuns(of: assembly(tool, readType, inputs: shapes.multiFileChunks))
            XCTAssertEqual(runs.map(\.reads), [[["m1", "m2", "m3", "m4", "m5"]]], tool.rawValue)
            XCTAssertEqual(runs.first?.pairs, false, tool.rawValue)
        }
    }

    /// The R1 and R2 files of one bundle bound with `pairedEnd` stay one run,
    /// which `lungfish-cli assemble` assembles as that bundle's pairs.
    func testTheR1AndR2FilesOfOneBundleAreOneRunAssembledAsPairs() async throws {
        let runs = try await cliRuns(
            of: assembly(.spades, .illuminaShortReads, inputs: shapes.pairedFiles, pairedEnd: true)
        )
        XCTAssertEqual(runs.map(\.reads), [[["p1/1", "p2/1"], ["p1/2", "p2/2"]]])
        XCTAssertEqual(runs.map(\.pairs), [true])
    }

    /// Several loose files are still several inputs, which Flye and hifiasm refuse.
    func testFlyeAndHifiasmStillRefuseSeveralLooseFiles() async throws {
        for (tool, readType) in [(AssemblyTool.flye, AssemblyReadType.ontReads), (.hifiasm, .pacBioHiFi)] {
            do {
                _ = try await cliRuns(of: assembly(tool, readType, inputs: shapes.looseFiles))
                XCTFail("\(tool.rawValue) must refuse two loose files")
            } catch let error as FASTQOperationExecutionError {
                guard case .unsupportedAssembly(let reason) = error else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("expects a single"), reason)
            }
        }
    }

    /// The per-bundle batch (`independentAssembleLaunchRequests`) gives each
    /// bundle one child, and the dispatch hands every child to the same
    /// fan-out. A child that named its bundle's two files kept two inputs in
    /// per-input mode, so it fanned out again, without end. A child names its
    /// bundle, so the fan-out leaves it as it is, and `lungfish-cli assemble`
    /// reads every read the bundle holds and pairs its R1 and R2 files itself.
    func testThePerBundleBatchGivesEachBundleOneChildThatNeverFansOutAgain() async throws {
        let batch = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [shapes.single, shapes.multiFile, shapes.paired, shapes.mixed],
                projectName: "batch",
                outputDirectory: root.appendingPathComponent("batch-output", isDirectory: true),
                threads: 1
            ),
            outputMode: .perInput
        )
        let children = batch.independentAssembleLaunchRequests(outputDirectory: root)
        XCTAssertEqual(children.count, 4)

        var reads: [[[String]]] = []
        var pairs: [Bool] = []
        var fannedOutAgain: [String] = []
        for child in children {
            if child.independentAssembleLaunchRequests(outputDirectory: root) != [child] {
                fannedOutAgain.append(child.inputURLs.map(\.lastPathComponent).joined(separator: " "))
            }
            let runs = try await cliRuns(of: child)
            reads.append(contentsOf: runs.map(\.reads))
            pairs.append(contentsOf: runs.map(\.pairs))
        }
        XCTAssertEqual(fannedOutAgain, [], "children the fan-out splits again")
        XCTAssertEqual(reads, [
            [["s1", "s2", "s3"]],
            [["m1", "m2", "m3", "m4", "m5"]],
            [["p1/1", "p2/1"], ["p1/2", "p2/2"]],
            [["x1", "x2", "x3", "u1/1", "u1/2"]],
        ], "one run per bundle, each with every read the bundle holds")
        XCTAssertEqual(pairs, [false, false, true, false])
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
            let resolved = try await ResolvedSequenceInputs.resolveForAssembly(
                inputURLs: inputs,
                materializationDirectory: root.appendingPathComponent("cli-\(UUID().uuidString)/.lungfish-assembly-inputs", isDirectory: true),
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
