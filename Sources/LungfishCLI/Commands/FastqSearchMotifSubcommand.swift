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

    @OptionGroup var pairing: FASTQPairingOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()

        // The pair-aware branch re-extracts by fragment NAME, so a file that
        // mixes merged reads with pairs is safe: a merged read that carries
        // the motif comes back alone, a pair comes back whole.
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, pairsByName: true)
        let isInterleaved = pairingDecision.pairAware
        var searchArgs = ["grep", "--by-seq", "-p", pattern]
        if regex {
            searchArgs.append("-r")
        }

        let runner = NativeToolRunner.shared
        let startedAt = Date()
        let args: [String]
        let result: NativeToolResult
        if isInterleaved {
            // A motif is a property of the fragment, not of one mate: when
            // either mate carries it, both mates are extracted, in their
            // original interleaved order.
            let paired = try await FastqPairedSearchSupport.runPairedSearch(
                searchArguments: searchArgs,
                sourceURL: inputURL,
                outputPath: output.output,
                runner: runner
            )
            args = paired.nativeArguments
            result = paired.result
        } else {
            args = searchArgs + [inputURL.path, "-o", output.output]
            result = try await runner.run(.seqkit, arguments: args, environment: [:], timeout: 1800)
            if !result.isSuccess {
                throw CLIError.conversionFailed(reason: result.stderr)
            }
        }

        var cliArguments = ["search-motif", inputURL.path, "--output", output.output, "--pattern", pattern]
        if regex {
            cliArguments.append("--regex")
        }
        cliArguments += pairing.cliArguments
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
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(isInterleaved),
                "readLayout": pairingDecision.readLayoutProvenanceValue,
                "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "regex": .boolean(false),
                "pairing": FASTQPairingOptions.provenanceDefault,
                "interleaved": .boolean(false),
                "readLayout": FASTQPairingOptions.readLayoutProvenanceDefault,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            startedAt: startedAt
        )
    }
}
