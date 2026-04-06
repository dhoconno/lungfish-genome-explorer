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
        let result = try await runner.run(.seqkit, arguments: args, environment: [:], timeout: 1800)

        if !result.isSuccess {
            throw CLIError.conversionFailed(reason: result.stderr)
        }
    }
}
