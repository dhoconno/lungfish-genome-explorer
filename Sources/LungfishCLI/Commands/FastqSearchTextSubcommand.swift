// FastqSearchTextSubcommand.swift - CLI subcommand to search FASTQ reads by ID or description
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqSearchTextSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-text",
        abstract: "Search FASTQ reads by ID or description field"
    )

    @Argument(help: "Input FASTQ file path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("query"), help: "Search query string")
    var query: String

    @Option(name: .customLong("field"), help: "Field to search: \"id\" or \"description\" (default: id)")
    var field: String = "id"

    @Flag(name: .customLong("regex"), help: "Treat query as a regular expression")
    var regex: Bool = false

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()

        var args = ["grep", "-p", query, inputURL.path, "-o", output.output]

        if field == "description" {
            args.append("--by-name")
        }

        if regex {
            args.append("-r")
        }

        let runner = NativeToolRunner.shared
        let startedAt = Date()
        let result = try await runner.run(.seqkit, arguments: args, environment: [:], timeout: 1800)

        if !result.isSuccess {
            throw CLIError.conversionFailed(reason: result.stderr)
        }

        var cliArguments = ["search-text", inputURL.path, "--output", output.output, "--query", query]
        if field != "id" {
            cliArguments += ["--field", field]
        }
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
            workflowName: "lungfish fastq search-text",
            nativeTool: .seqkit,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(inputURL),
                "output": .file(outputURL),
                "query": .string(query),
                "field": .string(field),
                "regex": .boolean(regex),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "field": .string("id"),
                "regex": .boolean(false),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
    }
}
