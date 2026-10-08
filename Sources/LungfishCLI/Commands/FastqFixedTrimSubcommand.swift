// FastqFixedTrimSubcommand.swift - Trim a fixed number of bases from read ends
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Fixed Trim

struct FastqFixedTrimSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fixed-trim",
        abstract: "Trim fixed number of bases from read ends"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("front"), help: "Bases to trim from 5' end (default: 0)")
    var front: Int = 0

    @Option(name: .customLong("tail"), help: "Bases to trim from 3' end (default: 0)")
    var tail: Int = 0

    @OptionGroup var pairing: FASTQPairingOptions

    @OptionGroup var output: OutputOptions

    /// The fastp arguments other than the input and output flags. fastp
    /// applies `--trim_front1` and `--trim_tail1` to read 2 as well unless
    /// `--trim_front2`/`--trim_tail2` are given, so a paired run trims both
    /// mates alike.
    /// The operation the window and this subcommand both render through
    /// ``FastpTrimOptions``.
    var trimOperation: FastpTrimOperation {
        .fixed(front: front, tail: tail)
    }

    var fastpOptions: [String] {
        FastpTrimOptions.options(for: trimOperation)
    }

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "fixed-trim", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        guard front >= 0 else { throw ValidationError("--front must be >= 0") }
        guard tail >= 0 else { throw ValidationError("--tail must be >= 0") }
        guard front > 0 || tail > 0 else {
            throw ValidationError("At least one of --front or --tail must be > 0")
        }

        let runClock = ProvenanceRunClock()
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, pairsByName: true, metadataFrom: resolvedInput.pairingMetadataURL)
        let plan = try await Task.detached(priority: .utility) {
            try FastpReadLayoutPlan.resolve(inputURL: inputURL, decision: pairingDecision)
        }.value
        let outcome = try await FastpPairedRunner.run(
            inputURL: inputURL,
            outputPath: output.output,
            plan: plan,
            options: fastpOptions,
            detectPairedAdapters: false,
            failureLabel: "fastp fixed trim",
            stepNamePrefix: "lungfish fastq fixed-trim"
        )
        var cliArguments = ["fixed-trim"]
        if front != 0 {
            cliArguments += ["--front", String(front)]
        }
        if tail != 0 {
            cliArguments += ["--tail", String(tail)]
        }
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
            workflowName: "lungfish fastq fixed-trim",
            nativeTool: .fastp,
            cliArguments: cliArguments,
            nativeArguments: outcome.nativeArguments,
            result: outcome.result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "front": .integer(front),
                "tail": .integer(tail),
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(outcome.plan.isPaired),
                "readLayout": pairingDecision.readLayoutProvenanceValue,
                "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
                "fastpLayoutPlan": outcome.plan.provenanceValue,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "front": .integer(0),
                "tail": .integer(0),
                "pairing": FASTQPairingOptions.provenanceDefault,
                "interleaved": .boolean(false),
                "readLayout": FASTQPairingOptions.readLayoutProvenanceDefault,
                "fastpLayoutPlan": FastpReadLayoutPlan.singleEnd.provenanceValue,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords(),
            stepID: outcome.stepID,
            stepInputs: outcome.stepInputs,
            stepOutputs: outcome.stepOutputs,
            extraSteps: outcome.extraSteps + (try resolvedInput.materializationSteps()),
            runClock: runClock
        )
        FileHandle.standardError.write(Data("Fixed-trimmed reads written to \(output.output)\n".utf8))
    }
}
