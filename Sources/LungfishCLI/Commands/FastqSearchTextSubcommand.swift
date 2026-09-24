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

    @OptionGroup var pairing: FASTQPairingOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()

        // Both pair-aware branches below pair records by fragment NAME, so a
        // file that mixes merged reads with pairs is safe: a matched pair
        // comes back whole and a matched merged read comes back alone.
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, pairsByName: true)
        let isInterleaved = pairingDecision.pairAware
        let searchesDescription = field == "description"
        var searchArgs = ["grep", "-p", query]
        if searchesDescription {
            searchArgs.append("--by-name")
        }
        if regex {
            searchArgs.append("-r")
        }

        let runner = NativeToolRunner.shared
        let startedAt = Date()
        let args: [String]
        let result: NativeToolResult
        if isInterleaved, !searchesDescription {
            // ID queries name a fragment, so match on the fragment key: an
            // exact base name then finds both `NAME/1` and `NAME/2`, and a
            // query can never select one mate without the other.
            args = searchArgs + FastqPairedSearchSupport.fragmentKeyIDArguments + [inputURL.path, "-o", output.output]
            result = try await runner.run(.seqkit, arguments: args, environment: [:], timeout: 1800)
            if !result.isSuccess {
                throw CLIError.conversionFailed(reason: result.stderr)
            }
        } else if isInterleaved {
            // Description text can differ between mates (Casava `1:N:0` vs
            // `2:N:0`), so search first and then extract both mates of every
            // fragment that matched.
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

        var cliArguments = ["search-text", inputURL.path, "--output", output.output, "--query", query]
        if field != "id" {
            cliArguments += ["--field", field]
        }
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
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(isInterleaved),
                "readLayout": pairingDecision.readLayoutProvenanceValue,
                "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "field": .string("id"),
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
