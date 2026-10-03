// FastqSubsampleSubcommand.swift - Subsample reads by proportion or count
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Subsample

struct FastqSubsampleSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subsample",
        abstract: "Subsample reads by proportion or count"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("proportion"), help: "Fraction of reads to keep (0-1)")
    var proportion: Double?

    @Option(
        name: .customLong("count"),
        help: "Number of reads to keep. On interleaved input this is still a read count: whole pairs are kept, so the count is rounded down to an even number (minimum one pair)."
    )
    var count: Int?

    @Option(
        name: .customLong("seed"),
        help: "Random seed for reproducible subsampling. Omit for a randomly generated seed, which is still recorded in provenance so the run can be replayed exactly."
    )
    var seed: Int64?

    @OptionGroup var pairing: FASTQPairingOptions

    @OptionGroup var output: OutputOptions

    /// The number of pairs reformat.sh must emit so the output holds `count`
    /// reads. `samplereadstarget` counts pairs on interleaved input, so the
    /// GUI's "Keep a fixed number of reads" is halved here, never doubled.
    static func interleavedPairTarget(forReadCount count: Int) -> Int {
        max(1, count / 2)
    }

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "subsample", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        let runner = NativeToolRunner.shared

        if proportion != nil && count != nil {
            throw ValidationError("Specify --proportion or --count, not both")
        }
        guard proportion != nil || count != nil else {
            throw ValidationError("Specify --proportion or --count")
        }
        // Always resolve a seed (random when omitted) and record the
        // actual value, so any run can be replayed exactly from provenance.
        let resolvedSeed = seed ?? Int64.random(in: 0...Int64.max)
        if let proportion {
            guard proportion > 0, proportion <= 1 else {
                throw ValidationError("Proportion must be in (0, 1]")
            }
        }
        if let count {
            guard count > 0 else {
                throw ValidationError("Count must be > 0")
            }
        }

        // Paired imports are stored interleaved (mates on adjacent
        // records). `seqkit sample`/`sample2` samples records independently,
        // which orphans mates in interleaved input. Resolve pairing from the
        // --pairing flag, the bundle metadata, or read names (identical mate
        // names included) and use `reformat.sh` (pair-aware: it samples
        // fragments, keeping both mates together) instead. A file that mixes
        // merged reads with pairs runs as single reads: reformat pairs by
        // position and would mis-pair it.
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, metadataFrom: resolvedInput.pairingMetadataURL)
        let isInterleaved = pairingDecision.pairAware

        let startedAt = Date()
        let toolName: String
        let args: [String]
        let result: NativeToolResult
        if isInterleaved {
            toolName = "reformat"
            var reformatArgs = [
                "in=\(inputURL.path)",
                "out=\(output.output)",
                "interleaved=t",
            ]
            if let proportion {
                reformatArgs.append("samplerate=\(proportion)")
            }
            if let count {
                // With interleaved=t, reformat.sh's samplereadstarget counts
                // output PAIRS. --count is a read count (the dialog says
                // "Keep a fixed number of reads"), so ask for count/2 pairs.
                reformatArgs.append("samplereadstarget=\(Self.interleavedPairTarget(forReadCount: count))")
            }
            reformatArgs.append("sampleseed=\(resolvedSeed)")
            args = reformatArgs
            let env = await bbToolsEnvironment(runner: runner)
            result = try await runner.run(.reformat, arguments: args, environment: env, timeout: 1800)
            guard result.isSuccess else {
                throw CLIError.conversionFailed(reason: "reformat.sh sample failed: \(result.stderr)")
            }
        } else {
            toolName = "seqkit"
            if let proportion {
                var seqkitArgs = ["sample", "-p", String(proportion), "-s", String(resolvedSeed)]
                seqkitArgs += [inputURL.path, "-o", output.output]
                args = seqkitArgs
            } else {
                var seqkitArgs = ["sample2", "-n", String(count!), "-2", "-s", String(resolvedSeed)]
                seqkitArgs += [inputURL.path, "-o", output.output]
                args = seqkitArgs
            }
            result = try await runner.run(.seqkit, arguments: args)
            guard result.isSuccess else {
                let command = count == nil ? "seqkit sample" : "seqkit sample2"
                throw CLIError.conversionFailed(reason: "\(command) failed: \(result.stderr)")
            }
        }

        var cliArguments = ["subsample"]
        if let proportion {
            cliArguments += ["--proportion", String(proportion)]
        }
        if let count {
            cliArguments += ["--count", String(count)]
        }
        cliArguments += ["--seed", String(resolvedSeed)]
        cliArguments += pairing.cliArguments
        cliArguments += [resolvedInput.originalURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq subsample",
            nativeTool: toolName == "reformat" ? .reformat : .seqkit,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "proportion": proportion.map(ParameterValue.number) ?? .null,
                "count": count.map(ParameterValue.integer) ?? .null,
                "seed": .integer(Int(resolvedSeed)),
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(isInterleaved),
                "readLayout": pairingDecision.readLayoutProvenanceValue,
                "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "proportion": .null,
                "count": .null,
                "seed": .null,
                "pairing": FASTQPairingOptions.provenanceDefault,
                "interleaved": .boolean(false),
                "readLayout": FASTQPairingOptions.readLayoutProvenanceDefault,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords(),
            extraSteps: try resolvedInput.materializationSteps(),
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Subsampled reads written to \(output.output)\n".utf8))
    }
}
