// FastqSearchMotifSubcommand.swift - CLI subcommand to search FASTQ reads by sequence motif
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqSearchMotifSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-motif",
        abstract: "Search FASTQ reads by sequence motif"
    )

    @Argument(help: "Input FASTQ file path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("pattern"), help: "Sequence motif pattern to search for")
    var pattern: String

    @Flag(name: .customLong("regex"), help: "Treat pattern as a regular expression")
    var regex: Bool = false

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()

        var args = ["grep", "--by-seq", "-p", pattern, inputURL.path, "-o", output.output]

        if regex {
            args.append("-r")
        }

        let runner = NativeToolRunner.shared
        let startedAt = Date()
        let result = try await runner.run(.seqkit, arguments: args, environment: [:], timeout: 1800)

        if !result.isSuccess {
            throw CLIError.conversionFailed(reason: result.stderr)
        }

        var cliArguments = ["search-motif", inputURL.path, "--output", output.output, "--pattern", pattern]
        if regex {
            cliArguments.append("--regex")
        }
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq search-motif",
            nativeTool: .seqkit,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "pattern": .string(pattern),
                "regex": .boolean(regex),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "regex": .boolean(false),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
    }
}
