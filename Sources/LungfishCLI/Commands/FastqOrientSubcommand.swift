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
        var cliArguments = ["orient", inputURL.path, "--output", output.output, "--reference", referenceURL.path]
        if wordLength != 12 {
            cliArguments += ["--word-length", String(wordLength)]
        }
        if dbMask != "dust" {
            cliArguments += ["--db-mask", dbMask]
        }
        if !extraArgs.isEmpty {
            cliArguments += ["--extra-args", extraArgs]
        }
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let toolVersion = await NativeToolRunner.shared.getToolVersion(.vsearch) ?? "unknown"
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq orient",
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "reference": .file(referenceURL),
                "wordLength": .integer(wordLength),
                "dbMask": .string(dbMask),
                "extraArgs": .string(extraArgs),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "wordLength": .integer(12),
                "dbMask": .string("dust"),
                "extraArgs": .string(""),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            toolName: NativeTool.vsearch.rawValue,
            toolVersion: toolVersion,
            command: ["lungfish", "fastq"] + cliArguments,
            stepCommand: result.arguments.isEmpty ? [NativeTool.vsearch.executableName] + args : result.arguments,
            inputs: [
                ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: referenceURL, format: .fasta, role: .reference)
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, format: .fastq, role: .output)],
            exitCode: result.exitCode,
            wallTime: wallTime,
            stderr: result.stderr,
            status: .completed,
            outputDirectory: outputURL.deletingLastPathComponent()
        )
    }
}
