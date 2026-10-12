// FASTQOperationGroupedRecordTests.swift - The record a grouped FASTQ result carries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A grouped result, such as a demultiplex, keeps its outputs together in one folder. The
// `lungfish-cli` commands that make those outputs write a record beside each of them. When the
// folder holds no record that names every output, the dispatcher writes one itself after the
// commands exit (`FASTQOperationPlanner.ensureGroupedResultProvenance`), from the commands it ran.
//
// The dispatcher runs one command for most grouped requests. A group that mixes FASTA and FASTQ
// inputs cannot share one execution representation, so the planner splits it into one command for
// each input. Before decision D2 of Phase 2.8 the record of those several commands named
// `lungfish-cli gui fastq-grouped-result --operation <kind>`, a command no leaf defines, and
// listed one step that held the same false command. D2 gives the record one step for each
// command, with the real `lungfish-cli` argv, and makes the run command the shell form of those
// commands, although the dispatcher launched each by its argv and no shell ran. The cases of one
// command are unchanged.
//
// Each test here builds the record from a fixture and reads it back, so a change to the record
// shows as a changed value.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQOperationGroupedRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQGroupedRecord")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - One invocation

    func testOneInvocationRecordsItsOwnCommandAsTheRunCommand() throws {
        let run = try makeSingleInvocationRun()
        let record = try writeRecord(for: run)
        let command = try XCTUnwrap(run.commands.first)
        let kind = run.request.batchManifestOperationKind

        XCTAssertEqual(record.argv, command)
        XCTAssertEqual(record.reproducibleCommand, command.map(shellEscape).joined(separator: " "))
        XCTAssertEqual(record.toolName, "lungfish gui grouped FASTQ operation")
        XCTAssertEqual(record.workflowName, "\(kind) grouped FASTQ operation")
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.exitStatus, 0)

        XCTAssertEqual(record.steps.count, 1)
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.toolName, "lungfish gui grouped FASTQ operation")
        XCTAssertEqual(step.argv, command)
        XCTAssertEqual(step.reproducibleCommand, record.reproducibleCommand)
        XCTAssertEqual(step.exitStatus, 0)
        // With one invocation the step is the whole run, so it lists the run's files.
        XCTAssertEqual(step.inputs.map(\.role), [.input])
        XCTAssertEqual(step.inputs.map { tail($0.path, 1) }, ["reads.fastq"])
        XCTAssertEqual(step.outputs.map(\.role), [.output, .output])
        XCTAssertEqual(step.outputs.map { tail($0.path, 2) }, [
            "filtered-a.\(FASTQBundle.directoryExtension)/reads.fastq",
            "filtered-b.\(FASTQBundle.directoryExtension)/reads.fastq",
        ])
        XCTAssertEqual(record.outputs.map(\.path), step.outputs.map(\.path))
        XCTAssertEqual(record.output?.path, step.outputs.first?.path)

        let explicit = record.options.explicit
        XCTAssertEqual(explicit["operationKind"], ParameterValue.string(kind))
        XCTAssertEqual(explicit["outputMode"], ParameterValue.string(FASTQOperationOutputMode.groupedResult.rawValue))
        XCTAssertEqual(explicit["outputCount"], ParameterValue.integer(2))
        XCTAssertEqual(explicit["outputDirectory"], ParameterValue.file(run.group))

        try assertCanonicalAndComplete(record, in: run.group)
    }

    func testOneInvocationRecordsACommandTheShippedParserAccepts() throws {
        let run = try makeSingleInvocationRun()
        let record = try writeRecord(for: run)

        let parsed = try RecordedCLICommand.parse(record.reproducibleCommand)
        XCTAssertTrue(parsed is FastqLengthFilterSubcommand, "Parsed \(type(of: parsed))")
    }

    // MARK: - Several invocations

    func testAMixedFormatGroupSplitsIntoOneInvocationPerInput() throws {
        let planner = FASTQOperationPlanner()
        let mixed = try makeMixedFormatRun()
        let mixedPlans = planner.makeExecutionPlans(
            originalRequest: mixed.request,
            resolvedRequest: mixed.request,
            baseOutputDirectory: mixed.group
        )
        XCTAssertEqual(mixedPlans.map { $0.originalRequest.inputURLs.map(\.lastPathComponent) }, [
            ["sequences.fasta"],
            ["reads.fastq"],
        ])

        let single = try makeSingleInvocationRun()
        let singlePlans = planner.makeExecutionPlans(
            originalRequest: single.request,
            resolvedRequest: single.request,
            baseOutputDirectory: single.group
        )
        XCTAssertEqual(singlePlans.count, 1)
    }

    func testTwoInvocationsRecordOneStepForEachRealCommandAndAShellRunCommand() throws {
        let run = try makeMixedFormatRun()
        let record = try writeRecord(for: run)
        let script = scriptText(of: run.commands)

        // The run command is the shell form of both commands, the script the record already held as its
        // reproducible command. No shell ran.
        XCTAssertEqual(record.argv, ["/bin/sh", "-lc", script])
        XCTAssertEqual(record.reproducibleCommand, script)
        XCTAssertTrue(script.contains(" && "), "The two commands are one script")
        XCTAssertEqual(record.toolName, "lungfish gui grouped FASTQ operation")
        XCTAssertEqual(record.workflowName, "\(run.request.batchManifestOperationKind) grouped FASTQ operation")
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.exitStatus, 0)

        // One step for each command, in the order they ran, with its real argv and no file.
        XCTAssertEqual(record.steps.map(\.argv), run.commands)
        XCTAssertEqual(
            record.steps.map(\.reproducibleCommand),
            run.commands.map { $0.map(shellEscape).joined(separator: " ") }
        )
        XCTAssertEqual(record.steps.map(\.exitStatus), [0, 0])
        XCTAssertTrue(record.steps.allSatisfy { $0.toolName == "lungfish gui grouped FASTQ operation" })
        XCTAssertTrue(record.steps.allSatisfy { $0.inputs.isEmpty && $0.outputs.isEmpty })

        // The run lists every file, because the record is not told which command read or wrote which.
        XCTAssertEqual(
            record.files.filter { $0.role == .input }.map { tail($0.path, 1) },
            ["sequences.fasta", "reads.fastq"]
        )
        XCTAssertEqual(record.outputs.map { tail($0.path, 2) }, [
            "filtered-sequences.\(FASTQBundle.directoryExtension)/reads.fastq",
            "filtered-reads.\(FASTQBundle.directoryExtension)/reads.fastq",
        ])
        XCTAssertEqual(record.output?.path, record.outputs.first?.path)

        // No argv names the grouping command that no leaf defines.
        let words = ([record.argv] + record.steps.map(\.argv)).flatMap { $0 }
        XCTAssertFalse(words.contains("gui"))
        XCTAssertFalse(words.contains("fastq-grouped-result"))

        try assertCanonicalAndComplete(record, in: run.group)
    }

    func testEveryStepOfAMixedFormatGroupIsACommandTheShippedParserAccepts() throws {
        let run = try makeMixedFormatRun()
        let planner = FASTQOperationPlanner()
        // The invocations the service builds, one for each plan, from the real builder.
        let invocations = try planner.makeExecutionPlans(
            originalRequest: run.request,
            resolvedRequest: run.request,
            baseOutputDirectory: run.group
        ).map { plan in
            try FASTQOperationCLIInvocationBuilder().buildInvocation(
                for: plan.resolvedRequest,
                outputTargetPath: plan.outputTarget.path
            )
        }
        XCTAssertEqual(invocations.count, 2)

        try planner.ensureGroupedResultProvenance(
            originalRequest: run.request,
            resolvedRequest: run.request,
            invocations: invocations,
            outputURLs: run.outputs,
            outputDirectory: run.group
        )
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.group))

        XCTAssertEqual(record.steps.count, 2)
        for step in record.steps {
            XCTAssertEqual(step.argv.first, CLICommandIdentity.executableName)
            let parsed = try RecordedCLICommand.parse(step.reproducibleCommand)
            XCTAssertTrue(parsed is FastqLengthFilterSubcommand, "Parsed \(type(of: parsed))")
        }
        // The shell the run names runs those same commands.
        XCTAssertEqual(
            record.argv,
            ["/bin/sh", "-lc", record.steps.map(\.reproducibleCommand).joined(separator: " && ")]
        )
    }

    // MARK: - No command

    func testNoInvocationWritesNoRecordBecauseNoCommandRan() throws {
        let run = try makeSingleInvocationRun()

        XCTAssertThrowsError(
            try FASTQOperationPlanner().ensureGroupedResultProvenance(
                originalRequest: run.request,
                resolvedRequest: run.request,
                invocations: [],
                outputURLs: run.outputs,
                outputDirectory: run.group
            )
        ) { error in
            guard case ProvenanceRehydrationError.missingSourceProvenance = error else {
                return XCTFail("Expected missing source provenance, got \(error)")
            }
        }
        XCTAssertNil(ProvenanceRecorder.loadEnvelope(from: run.group))
    }

    // MARK: - Keeping a record

    func testASecondCallKeepsTheRecordThatAlreadyNamesTheOutputs() throws {
        let run = try makeSingleInvocationRun()
        let first = try writeRecord(for: run)
        let recordURL = run.group.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let firstBytes = try Data(contentsOf: recordURL)

        let second = try writeRecord(for: run)

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try Data(contentsOf: recordURL), firstBytes)
    }

    // MARK: - Fixtures

    /// A grouped request, the commands the dispatcher ran for it, and the folder that holds the
    /// outputs of those commands, each with the record its command wrote.
    private struct GroupedRun {
        let request: FASTQOperationLaunchRequest
        let group: URL
        let outputs: [URL]
        /// One `lungfish-cli` argv for each invocation, in the order they ran.
        let commands: [[String]]

        var invocations: [FASTQCLIInvocation] {
            commands.map { FASTQCLIInvocation(subcommand: $0[1], arguments: Array($0.dropFirst(2))) }
        }
    }

    /// One length filter over one FASTQ file that made two output bundles, the way a demultiplex does.
    private func makeSingleInvocationRun() throws -> GroupedRun {
        let group = try makeGroupFolder()
        let reads = try makeFASTQInput(named: "reads.fastq")
        let outputs = [
            try makeOutputBundle(named: "filtered-a", in: group, from: reads),
            try makeOutputBundle(named: "filtered-b", in: group, from: reads),
        ]
        return GroupedRun(
            request: groupedLengthFilter(inputs: [reads]),
            group: group,
            outputs: outputs,
            commands: [lengthFilterCommand(input: reads, output: group.appendingPathComponent("length-filter.fastq"))]
        )
    }

    /// One length filter over a FASTA file and one over a FASTQ file, the one case in which the
    /// dispatcher runs several commands for a grouped result.
    private func makeMixedFormatRun() throws -> GroupedRun {
        let group = try makeGroupFolder()
        let sequences = root.appendingPathComponent("sequences.fasta")
        try ">read\nACGT\n".write(to: sequences, atomically: true, encoding: .utf8)
        let reads = try makeFASTQInput(named: "reads.fastq")
        let outputs = [
            try makeOutputBundle(named: "filtered-sequences", in: group, from: sequences),
            try makeOutputBundle(named: "filtered-reads", in: group, from: reads),
        ]
        return GroupedRun(
            request: groupedLengthFilter(inputs: [sequences, reads]),
            group: group,
            outputs: outputs,
            commands: [
                lengthFilterCommand(input: sequences, output: group.appendingPathComponent("sequences/length-filter.fastq")),
                lengthFilterCommand(input: reads, output: group.appendingPathComponent("reads/length-filter.fastq")),
            ]
        )
    }

    private func makeGroupFolder() throws -> URL {
        let group = root.appendingPathComponent("group", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        return group
    }

    private func makeFASTQInput(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: url, readCount: 2, readLength: 20)
        return url
    }

    private func groupedLengthFilter(inputs: [URL]) -> FASTQOperationLaunchRequest {
        .derivative(request: .lengthFilter(min: 100, max: 500), inputURLs: inputs, outputMode: .groupedResult)
    }

    private func lengthFilterCommand(input: URL, output: URL) -> [String] {
        [
            CLICommandIdentity.executableName, "fastq", "length-filter", input.path,
            "--min", "100", "--max", "500", "-o", output.path,
        ]
    }

    /// An output bundle with the record its command wrote, so the group counts it as made by a command.
    private func makeOutputBundle(named name: String, in group: URL, from input: URL) throws -> URL {
        let bundle = try FASTQOperationTestHelper.makeBundle(named: name, in: group)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 1, readLength: 20)
        let command = lengthFilterCommand(input: input, output: bundle.fastqURL)
        let startedAt = Date(timeIntervalSince1970: 1_800)
        let endedAt = Date(timeIntervalSince1970: 1_801.25)
        let record = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq length-filter",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "seqkit",
            toolVersion: "2.9.0"
        )
        .argv(command)
        .options(explicit: [:], defaults: [:], resolved: [:])
        .input(input, role: .input)
        .output(bundle.fastqURL, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "seqkit",
                toolVersion: "2.9.0",
                argv: command,
                exitStatus: 0,
                wallTimeSeconds: 1.25,
                startedAt: startedAt,
                completedAt: endedAt
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: endedAt)
        try ProvenanceWriter(signingProvider: nil).write(record, to: bundle.bundleURL)
        return bundle.bundleURL
    }

    // MARK: - Helpers

    private func writeRecord(for run: GroupedRun) throws -> ProvenanceEnvelope {
        try FASTQOperationPlanner().ensureGroupedResultProvenance(
            originalRequest: run.request,
            resolvedRequest: run.request,
            invocations: run.invocations,
            outputURLs: run.outputs,
            outputDirectory: run.group
        )
        return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.group))
    }

    private func assertCanonicalAndComplete(
        _ record: ProvenanceEnvelope,
        in group: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try Data(contentsOf: group.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertNoThrow(try ProvenanceEnvelopeReader.decodeCanonical(data), file: file, line: line)
        XCTAssertEqual(ProvenanceCompleteness.issues(in: record), [], file: file, line: line)
    }

    /// The commands as one shell script, which stops at the first command that fails.
    private func scriptText(of commands: [[String]]) -> String {
        commands.map { $0.map(shellEscape).joined(separator: " ") }.joined(separator: " && ")
    }

    /// The last `count` components of `path`, joined by `/`.
    private func tail(_ path: String, _ count: Int) -> String {
        URL(fileURLWithPath: path).pathComponents.suffix(count).joined(separator: "/")
    }
}
