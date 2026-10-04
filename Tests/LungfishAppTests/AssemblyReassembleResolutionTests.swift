// AssemblyReassembleResolutionTests.swift - The in-process assembly reads what its recorded lungfish-cli assemble command reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Reassemble from the sidebar runs `AssemblyRunner` in process and records
/// the `lungfish-cli assemble` command that reproduces it. For every bundle
/// shape the run hands the assembler the reads the recorded command would,
/// paired the same way (R3, lane 1q). The CLI side goes through the shipped
/// parser and the steps `AssembleCommand.run` takes before it assembles.
@MainActor
final class AssemblyReassembleResolutionTests: XCTestCase {

    private var root: URL!
    private var shapes: AssemblyBundleShapes!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assembly-reassemble-resolution")
        shapes = try AssemblyBundleShapes(in: root.appendingPathComponent("Project.lungfish", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The run read one primary file per input: chunk 0 of a multi-file
    /// bundle, the merged file of a fullMixed bundle, R1 alone of a
    /// fullPaired bundle, and R1 twice for the R1 and R2 files Reassemble
    /// lists from a fullPaired run's provenance.
    func testTheRunReadsEveryReadOfEachBundleShapeAsItsRecordedCommandDoes() async throws {
        let cases: [(shape: String, inputs: [URL], pairedEnd: Bool, reads: [[String]], pairing: AssemblyReadPairing)] = [
            ("root single", [shapes.single], false, [["s1", "s2", "s3"]], .single),
            ("root multi-file", [shapes.multiFile], false, [["m1", "m2", "m3", "m4", "m5"]], .single),
            ("virtual orientMap", [shapes.oriented], false, [["s1", "s3"]], .single),
            ("derived fullPaired", [shapes.paired], false, [["p1/1", "p2/1"], ["p1/2", "p2/2"]], .pairedFiles),
            ("derived fullMixed", [shapes.mixed], false, [["x1", "x2", "x3", "u1/1", "u1/2"]], .single),
            ("fullPaired R1 and R2 files", shapes.pairedFiles, true, [["p1/1", "p2/1"], ["p1/2", "p2/2"]], .pairedFiles),
        ]
        for testCase in cases {
            let run = try await inProcessRun(testCase.inputs, pairedEnd: testCase.pairedEnd)
            let recorded = try await recordedCommandRun(run.recordedCommand)
            XCTAssertEqual(recorded.reads, testCase.reads, "\(testCase.shape): the recorded command")
            XCTAssertEqual(recorded.pairing, testCase.pairing, "\(testCase.shape): the recorded command")
            XCTAssertEqual(try run.reads, recorded.reads, "\(testCase.shape): the in-process run reads the same files")
            XCTAssertEqual(run.pairing, recorded.pairing, "\(testCase.shape): the in-process run pairs them the same way")
        }
    }

    /// The run's provenance names the reads it assembled. A joined bundle is
    /// recorded as the bundle, with a `cat` step from its files as the
    /// recorded command's provenance has, so Reassemble finds the bundle
    /// again. The R1 and R2 files of a mate pair are recorded as themselves.
    func testTheRunRecordsAJoinedBundleAsTheBundleAndTheJoinAsACatStep() async throws {
        let joined = try await inProcessRun([shapes.multiFile], pairedEnd: false).result
        let records = AssemblyRunner.managedAssemblyInputRecords(
            originalInputURLs: joined.originalInputURLs,
            executionInputURLs: joined.request.inputURLs
        )
        XCTAssertEqual(records.map(\.originalPath), [shapes.multiFile.standardizedFileURL.path])
        XCTAssertNotNil(records.first?.sha256)
        let steps = try AssemblyRunner.managedAssemblyMaterializationSteps(
            originalInputURLs: joined.originalInputURLs,
            executionInputURLs: joined.request.inputURLs,
            startedAt: joined.materializationStartedAt,
            endedAt: joined.materializationEndedAt
        )
        XCTAssertEqual(steps.map(\.toolName), [SequenceInputConcatenation.toolName])
        XCTAssertEqual(steps.first?.inputs.map(\.path), shapes.multiFileChunks.map(\.standardizedFileURL.path))
        XCTAssertEqual(steps.first?.outputs.map(\.path), joined.request.inputURLs.map(\.path))

        let mates = try await inProcessRun([shapes.paired], pairedEnd: false).result
        XCTAssertEqual(
            AssemblyRunner.managedAssemblyInputRecords(
                originalInputURLs: mates.originalInputURLs,
                executionInputURLs: mates.request.inputURLs
            ).map(\.originalPath),
            shapes.pairedFiles.map(\.standardizedFileURL.path)
        )
    }

    /// The run assembled one file as single reads whatever its layout, while
    /// the recorded command resolves the layout (bundle metadata, then the
    /// records) or passes the one the request carries with `--read-layout`.
    /// `runValidated` dropped that layout from the request it ran, and so did
    /// the input resolution.
    func testTheRunPairsAnInterleavedFileAsItsRecordedCommandDoes() async throws {
        let auto = try await inProcessRun([shapes.interleaved], pairedEnd: false)
        let autoRecorded = try await recordedCommandRun(auto.recordedCommand)
        XCTAssertFalse(auto.recordedCommand.contains("--read-layout"))
        XCTAssertEqual(autoRecorded.pairing, .interleaved, "the CLI scans the records and finds mates")
        XCTAssertEqual(auto.pairing, autoRecorded.pairing)

        let stated = try await inProcessRun([shapes.single], pairedEnd: false, inputLayout: .strictlyInterleaved)
        let statedRecorded = try await recordedCommandRun(stated.recordedCommand)
        XCTAssertTrue(stated.recordedCommand.contains("--read-layout interleaved"), stated.recordedCommand)
        XCTAssertEqual(statedRecorded.pairing, .interleaved)
        XCTAssertEqual(stated.pairing, statedRecorded.pairing)

        let pooled = try await inProcessRun([shapes.multiFile], pairedEnd: false)
        let pooledRecorded = try await recordedCommandRun(pooled.recordedCommand)
        XCTAssertEqual(pooled.result.request.inputLayout, .singleEnd, "a joined bundle keeps its pooled single reads")
        XCTAssertEqual(pooled.pairing, pooledRecorded.pairing)
    }

    /// The layout the recorded command carries is the layout of the request
    /// `runValidated` hands the pipeline.
    func testTheRunKeepsTheLayoutItsRecordedCommandCarries() {
        let layouts: [FASTQInputLayout?] = [nil] + FASTQInputLayout.allCases.map { $0 }
        for layout in layouts {
            let request = AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [shapes.single],
                projectName: "kept",
                outputDirectory: root,
                threads: 1,
                minContigLength: 0,
                inputLayout: layout
            ).normalizedForExecution()
            let executed = AssemblyRunner.executionRequest(for: request)
            XCTAssertEqual(executed.inputLayout, layout)
            XCTAssertEqual(executed.outputDirectory, root.appendingPathComponent("kept", isDirectory: true))
            XCTAssertEqual(executed.minContigLength, 1)
        }
    }

    /// `lungfish-cli assemble` and the in-process run resolve the layout of
    /// one file with one function, `AssemblyRunRequest.resolveInputLayout`,
    /// since lane 1q-2 deleted the CLI's own copy. Over the six bundle shapes,
    /// every assembler, read type and stated layout, it gives the 75 answers
    /// that copy gave. Only a short-read assembler reading Illumina reads from
    /// one file, not one of a mate pair, resolves a layout, and a stated
    /// layout wins over the one the bundle's reads show.
    func testTheSharedLayoutRuleAnswersAsTheCLIsOwnCopyDid() async throws {
        let unstated: [(bundle: URL, answer: (layout: FASTQInputLayout, source: FASTQInputLayoutResolution.Source)?)] = [
            (shapes.single, (.singleEnd, .contentScan)),
            (shapes.multiFile, (.singleEnd, .pooledFiles)),
            (shapes.oriented, (.singleEnd, .contentScan)),
            (shapes.paired, nil),
            (shapes.mixed, (.singleEnd, .pooledFiles)),
            (shapes.interleaved, (.strictlyInterleaved, .contentScan)),
        ]
        let layouts: [FASTQInputLayout?] = [nil] + FASTQInputLayout.allCases.map { $0 }
        var resolvedCount = 0
        for shape in unstated {
            let resolved = try await ResolvedSequenceInputs.resolveForAssembly(
                inputURLs: [shape.bundle],
                materializationDirectory: root.appendingPathComponent("layout-\(UUID().uuidString)", isDirectory: true),
                materializer: FASTQCLIMaterializer(runner: .shared)
            )
            for tool in AssemblyTool.allCases {
                for readType in AssemblyReadType.allCases {
                    for explicit in layouts {
                        let answer = AssemblyRunRequest.resolveInputLayout(
                            tool: tool,
                            readType: readType,
                            pairedEnd: resolved.resolvedAsMatePair,
                            explicit: explicit,
                            originalInputURLs: resolved.originalInputURLs,
                            executionInputURLs: resolved.executionInputURLs,
                            pooled: resolved.pooledLayoutResolution
                        )
                        let label = "\(shape.bundle.lastPathComponent) \(tool.rawValue) \(readType) \(String(describing: explicit))"
                        guard [AssemblyTool.spades, .megahit, .skesa].contains(tool),
                              readType == .illuminaShortReads,
                              let unstatedAnswer = shape.answer else {
                            XCTAssertNil(answer, label)
                            continue
                        }
                        resolvedCount += 1
                        XCTAssertEqual(answer?.layout, explicit ?? unstatedAnswer.layout, label)
                        XCTAssertEqual(answer?.source, explicit == nil ? unstatedAnswer.source : .explicit, label)
                    }
                }
            }
        }
        XCTAssertEqual(resolvedCount, 75, "the cases that resolve a layout, of 450")
    }

    // MARK: - Helpers

    private struct Run {
        /// The record names of each file the assembler is handed, in order.
        let reads: [[String]]
        let pairing: AssemblyReadPairing
    }

    private struct InProcessRun {
        /// The `lungfish-cli assemble` command the Operations panel records.
        let recordedCommand: String
        let result: AssemblyRunner.ManagedAssemblyMaterializationResult

        var reads: [[String]] {
            get throws { try result.request.inputURLs.map(AssemblyBundleShapes.readNames(in:)) }
        }

        var pairing: AssemblyReadPairing { result.request.readPairing }
    }

    /// The command `AssemblyRunner` records and the request it hands the
    /// managed pipeline, for a normalized request as the wizard builds it.
    private func inProcessRun(
        _ inputs: [URL],
        pairedEnd: Bool,
        inputLayout: FASTQInputLayout? = nil
    ) async throws -> InProcessRun {
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: inputs,
            projectName: "reassembled",
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
            pairedEnd: pairedEnd,
            threads: 1,
            inputLayout: inputLayout
        ).normalizedForExecution()
        // `runValidated`: the recorded command, then the request the pipeline runs.
        let executionRequest = AssemblyRunner.executionRequest(for: request)
        let recordedCommand = AssemblyRunner.cliCommandPreview(request: request, outputDirectory: executionRequest.outputDirectory)
        let result = try await AssemblyRunner.materializedManagedAssemblyRequestResult(
            from: executionRequest,
            tempDirectory: executionRequest.outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
            materialize: { bundleURL, tempDirectory, progress in
                try await FASTQCLIMaterializer(runner: .shared).materialize(
                    bundleURL: bundleURL,
                    tempDirectory: tempDirectory,
                    progress: progress
                )
            }
        )
        return InProcessRun(recordedCommand: recordedCommand, result: result)
    }

    /// What `lungfish-cli assemble` hands its assembler for `command`.
    private func recordedCommandRun(_ command: String) async throws -> Run {
        let parsed = try RecordedCLICommand.parse(command, as: AssembleCommand.self)
        let tool = try XCTUnwrap(AssemblyTool(rawValue: parsed.assembler ?? ""))
        let readType = try XCTUnwrap(parsed.readType.flatMap(AssemblyReadType.init(cliArgument:)))
        let inputs = parsed.fastqFiles.map { URL(fileURLWithPath: $0) }
        try AssembleCommand.validatePreMaterializationTopology(tool: tool, inputURLs: inputs, pairedEnd: parsed.pairedEnd)
        let resolved = try await ResolvedSequenceInputs.resolveForAssembly(
            inputURLs: inputs,
            materializationDirectory: root.appendingPathComponent("cli-\(UUID().uuidString)/.lungfish-assembly-inputs", isDirectory: true),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        let pairedEnd = parsed.pairedEnd || resolved.resolvedAsMatePair
        let layout = AssemblyRunRequest.resolveInputLayout(
            tool: tool,
            readType: readType,
            pairedEnd: pairedEnd,
            explicit: parsed.readLayout.explicitLayout,
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs,
            pooled: resolved.pooledLayoutResolution
        )
        let request = AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: resolved.executionInputURLs,
            projectName: "recorded",
            outputDirectory: root.appendingPathComponent("cli-out", isDirectory: true),
            pairedEnd: pairedEnd,
            threads: 1,
            inputLayout: layout?.layout
        )
        return Run(
            reads: try resolved.executionInputURLs.map(AssemblyBundleShapes.readNames(in:)),
            pairing: request.readPairing
        )
    }
}
