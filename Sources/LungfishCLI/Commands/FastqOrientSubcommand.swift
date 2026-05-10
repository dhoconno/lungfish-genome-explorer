// FastqOrientSubcommand.swift - CLI subcommand to orient reads against a reference sequence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqOrientSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orient",
        abstract: "Orient reads against a reference sequence"
    )

    @Argument(help: "Input FASTQ file path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("reference"), help: "Reference FASTA file path")
    var reference: String

    @Option(name: .customLong("word-length"), help: "Word length for orientation matching (default: 12)")
    var wordLength: Int = 12

    @Option(name: .customLong("db-mask"), help: "Database masking method (default: dust)")
    var dbMask: String = "dust"

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional vsearch arguments passed verbatim"
    )
    var extraArgs: String = ""

    func run() async throws {
        let inputURL = try validateInput(input)
        let referenceURL = try validateInput(reference)
        try output.validateOutput()

        let tabbedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-orient-\(UUID().uuidString).tsv")
        defer {
            try? FileManager.default.removeItem(at: tabbedOutput)
        }

        var args: [String] = [
            "--orient", inputURL.path,
            "--db", referenceURL.path,
            "--fastqout", output.output,
            "--tabbedout", tabbedOutput.path,
            "--wordlength", String(wordLength),
            "--dbmask", dbMask,
            "--qmask", dbMask,
            "--threads", "0",
        ]
        args += try AdvancedCommandLineOptions.parse(extraArgs)

        let runner = NativeToolRunner.shared
        let startedAt = Date()
        let result = try await runner.run(.vsearch, arguments: args, environment: [:], timeout: 1800)
        let wallTime = Date().timeIntervalSince(startedAt)

        if !result.isSuccess {
            throw CLIError.conversionFailed(reason: result.stderr)
        }
        let outputURL = URL(fileURLWithPath: output.output)
        let run = WorkflowRun(
            name: "lungfish fastq orient",
            endTime: Date(),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: "vsearch",
                    toolVersion: "bundled",
                    command: ["vsearch"] + args,
                    inputs: [
                        ProvenanceRecorder.fileRecord(url: inputURL, role: .input),
                        ProvenanceRecorder.fileRecord(url: referenceURL, role: .reference),
                    ],
                    outputs: [ProvenanceRecorder.fileRecord(url: outputURL, role: .output)],
                    exitCode: result.exitCode,
                    wallTime: wallTime,
                    stderr: result.stderr,
                    endTime: Date()
                ),
            ],
            parameters: [
                "wordLength": .integer(wordLength),
                "dbMask": .string(dbMask),
                "extraArgs": .string(extraArgs),
                "argv": .array(CommandLine.arguments.map { .string($0) }),
                "command": .string(CommandLine.arguments.map(shellEscape).joined(separator: " ")),
            ]
        )
        try writeFastqOrientWorkflowRun(run, to: outputURL.deletingLastPathComponent())
    }
}

private func writeFastqOrientWorkflowRun(_ run: WorkflowRun, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(run)
    try data.write(
        to: directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
        options: .atomic
    )
}
