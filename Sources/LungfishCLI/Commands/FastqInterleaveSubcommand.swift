// FastqInterleaveSubcommand.swift - Interleave separate R1/R2 files into one FASTQ
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Interleave

struct FastqInterleaveSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interleave",
        abstract: "Interleave separate R1/R2 files into one FASTQ"
    )

    @Option(name: .customLong("in1"), help: "Input R1 file (required)")
    var in1: String

    @Option(name: .customLong("in2"), help: "Input R2 file (required)")
    var in2: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        guard FileManager.default.fileExists(atPath: in1) else {
            throw CLIError.inputFileNotFound(path: in1)
        }
        guard FileManager.default.fileExists(atPath: in2) else {
            throw CLIError.inputFileNotFound(path: in2)
        }
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        let args = [
            "in1=\(in1)",
            "in2=\(in2)",
            "out=\(output.output)",
        ]

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.reformat, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "reformat.sh interleave failed: \(result.stderr)")
        }
        let in1URL = URL(fileURLWithPath: in1)
        let in2URL = URL(fileURLWithPath: in2)
        let outputURL = URL(fileURLWithPath: output.output)
        var cliArguments = ["interleave", "--in1", in1, "--in2", in2, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq interleave",
            nativeTool: .reformat,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [in1URL, in2URL],
            outputURLs: [outputURL],
            parameters: [
                "in1": .file(in1URL),
                "in2": .file(in2URL),
                "output": .file(outputURL),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Interleaved reads written to \(output.output)\n".utf8))
    }
}
