// FastqTrimSubcommand.swift - Trim adapters and low-quality bases in one fastp pass
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Combined fastp Trim

struct FastqTrimSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trim",
        abstract: "Trim adapters and low-quality bases in one fastp pass"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("threshold"), help: "Quality threshold (default: 20)")
    var threshold: Int = 20

    @Option(name: .customLong("window"), help: "Sliding window size (default: 4)")
    var windowSize: Int = 4

    @Option(name: .customLong("mode"), help: "Quality trim mode: cut-right, cut-front, cut-tail, cut-both (default: cut-right)")
    var mode: String = "cut-right"

    @Flag(
        name: .customLong("adapter-trimming"),
        inversion: .prefixedNo,
        help: "Run fastp adapter trimming in the same pass (default: enabled)"
    )
    var adapterTrimming: Bool = true

    @Option(name: .customLong("adapter"), help: "Adapter sequence (omit for auto-detect)")
    var adapterSequence: String?

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional fastp arguments passed verbatim"
    )
    var extraArgs: String = ""

    @OptionGroup var pairing: FASTQPairingOptions

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "trim", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        let started = Date()
        let options = try fastpOptions()
        // Paired input runs fastp in its paired mode so both mates are kept
        // or dropped together (FastqFastpPairedRun.swift).
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, pairsByName: true, metadataFrom: resolvedInput.pairingMetadataURL)
        let plan = try await Task.detached(priority: .utility) {
            try FastpReadLayoutPlan.resolve(inputURL: inputURL, decision: pairingDecision)
        }.value
        let outcome = try await FastpPairedRunner.run(
            inputURL: inputURL,
            outputPath: output.output,
            plan: plan,
            options: options,
            detectPairedAdapters: adapterTrimming && adapterSequence == nil,
            failureLabel: "fastp combined trim",
            stepNamePrefix: "lungfish fastq trim"
        )
        try await writeProvenance(input: resolvedInput, outcome: outcome, pairingDecision: pairingDecision, started: started)
        FileHandle.standardError.write(Data("Adapter and quality trimmed reads written to \(output.output)\n".utf8))
    }

    /// The single-end fastp argv (`-i`, `-o`, then the options).
    func fastpArgumentsForTesting(inputURL: URL) throws -> [String] {
        FastpPairedRunner.fastpArguments(
            inputPath: inputURL.path,
            outputPath: output.output,
            mateOutputPath: nil,
            options: try fastpOptions(),
            detectPairedAdapters: false
        )
    }

    /// The operation the window and this subcommand both render through
    /// ``FastpTrimOptions``.
    func trimOperation() throws -> FastpTrimOperation {
        .combined(
            threshold: threshold,
            window: windowSize,
            mode: try parseQualityTrimMode(mode),
            adapterTrimming: adapterTrimming,
            adapterSequence: adapterSequence
        )
    }

    /// The fastp arguments other than the input and output flags.
    func fastpOptions() throws -> [String] {
        FastpTrimOptions.options(
            for: try trimOperation(),
            extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
        )
    }

    private func writeProvenance(
        input: FASTQSubcommandInput,
        outcome: FastpPairedRunOutcome,
        pairingDecision: FASTQPairingDecision,
        started: Date
    ) async throws {
        let inputURL = input.originalURL
        let outputURL = URL(fileURLWithPath: output.output)
        var cliArguments = ["trim", inputURL.path]
        if threshold != 20 {
            cliArguments += ["--threshold", String(threshold)]
        }
        if windowSize != 4 {
            cliArguments += ["--window", String(windowSize)]
        }
        if mode != "cut-right" {
            cliArguments += ["--mode", mode]
        }
        if !adapterTrimming {
            cliArguments.append("--no-adapter-trimming")
        }
        if let adapterSequence {
            cliArguments += ["--adapter", adapterSequence]
        }
        if !extraArgs.isEmpty {
            cliArguments += ["--extra-args", extraArgs]
        }
        cliArguments += pairing.cliArguments
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq trim",
            nativeTool: .fastp,
            cliArguments: cliArguments,
            nativeArguments: outcome.nativeArguments,
            result: outcome.result,
            inputURLs: [inputURL],
            outputURLs: [outputURL],
            parameters: [
                "threshold": .integer(threshold),
                "window": .integer(windowSize),
                "mode": .string(mode),
                "adapterTrimming": .boolean(adapterTrimming),
                "adapterSequence": adapterSequence.map(ParameterValue.string) ?? .null,
                "operation": .string("combined fastp adapter+quality trim"),
                "output": .file(outputURL),
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(outcome.plan.isPaired),
                "readLayout": pairingDecision.readLayoutProvenanceValue,
                "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
                "fastpLayoutPlan": outcome.plan.provenanceValue,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "threshold": .integer(20),
                "window": .integer(4),
                "mode": .string("cut-right"),
                "adapterTrimming": .boolean(true),
                "adapterSequence": .null,
                "pairing": FASTQPairingOptions.provenanceDefault,
                "interleaved": .boolean(false),
                "readLayout": FASTQPairingOptions.readLayoutProvenanceDefault,
                "fastpLayoutPlan": FastpReadLayoutPlan.singleEnd.provenanceValue,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try input.inputRecords(),
            stepID: outcome.stepID,
            stepInputs: outcome.stepInputs,
            stepOutputs: outcome.stepOutputs,
            extraSteps: outcome.extraSteps + (try input.materializationSteps()),
            startedAt: started
        )
    }

    private var awaitlessFastpVersion: String {
        "managed fastp"
    }
}
