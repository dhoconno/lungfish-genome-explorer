// FastqErrorCorrectSubcommand.swift - Correct sequencing errors using tadpole
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Error Correction

struct FastqErrorCorrectSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "error-correct",
        abstract: "Correct sequencing errors using tadpole"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("kmer"), help: "K-mer size for correction (default: 50, max: 62)")
    var kmerSize: Int = 50

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "error-correct", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        guard kmerSize > 0, kmerSize <= 62 else {
            throw ValidationError("K-mer size must be between 1 and 62")
        }
        let runner = NativeToolRunner.shared

        let args = [
            "in=\(inputURL.path)",
            "out=\(output.output)",
            "mode=correct",
            "ecc=t",
            "k=\(kmerSize)",
            // Per record, as FASTQConsumerRegistry declares. Left to guess,
            // tadpole pairs /1 /2 names by position and aborts on an odd
            // record count.
            "interleaved=f",
        ]

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.tadpole, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "tadpole error correction failed: \(result.stderr)")
        }
        var cliArguments = ["error-correct", resolvedInput.originalURL.path]
        if kmerSize != 50 {
            cliArguments += ["--kmer", String(kmerSize)]
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq error-correct",
            nativeTool: .tadpole,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "kmer": .integer(kmerSize),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "kmer": .integer(50),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords(),
            extraSteps: try resolvedInput.materializationSteps(),
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Error-corrected reads written to \(output.output)\n".utf8))
    }
}
