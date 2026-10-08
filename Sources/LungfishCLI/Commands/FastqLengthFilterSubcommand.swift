// FastqLengthFilterSubcommand.swift - Filter reads by length
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Length Filter

struct FastqLengthFilterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "length-filter",
        abstract: "Filter reads by length"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("min"), help: "Minimum read length")
    var minLength: Int?

    @Option(name: .customLong("max"), help: "Maximum read length")
    var maxLength: Int?

    @OptionGroup var pairing: FASTQPairingOptions

    @OptionGroup var output: OutputOptions

    /// The command this run executes: bbduk `interleaved=t` when the input
    /// pairs (both mates kept or dropped together), `seqkit seq` for
    /// single reads. The window's in-process filter renders the same plan.
    func plan(inputURL: URL, decision: FASTQPairingDecision) -> FASTQLengthFilterPlan {
        FASTQLengthFilterPlan.make(
            inputPath: inputURL.path,
            outputPath: output.output,
            minLength: minLength,
            maxLength: maxLength,
            pairAware: decision.pairAware
        )
    }

    /// Runs `plan`, bbduk in its BBTools environment.
    private static func runFilter(_ plan: FASTQLengthFilterPlan, runner: NativeToolRunner) async throws -> NativeToolResult {
        let environment = plan.isPairAware ? await bbToolsEnvironment(runner: runner) : nil
        return try await runner.run(plan.tool, arguments: plan.arguments, environment: environment, timeout: plan.timeout)
    }

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "length-filter", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        guard minLength != nil || maxLength != nil else {
            throw ValidationError("Specify --min, --max, or both")
        }
        if let minLength, minLength < 0 { throw ValidationError("--min must be >= 0") }
        if let maxLength, maxLength < 0 { throw ValidationError("--max must be >= 0") }
        if let minLength, let maxLength, minLength > maxLength {
            throw ValidationError("--min (\(minLength)) must be <= --max (\(maxLength))")
        }
        let runner = NativeToolRunner.shared

        // seqkit seq judges every record alone and orphaned 1,856 mates of
        // the HG002 fixture. bbduk interleaved=t pairs by position, so a
        // strictly interleaved input runs it whole. A file that mixes pairs
        // with single reads is split by name (FASTQSplitByNameRunner): its
        // pairs run bbduk interleaved=t and its single reads seqkit, joined
        // pairs first, so a pair is kept or dropped whole. Run per record,
        // such a file orphaned the mate of each pair with one mate out of
        // bounds (final review A, N7).
        let pairingDecision = pairing.resolvePairing(
            inputURL: inputURL,
            pairsByName: true,
            metadataFrom: resolvedInput.pairingMetadataURL
        )
        let layoutPlan = try await Task.detached(priority: .utility) {
            try FastpReadLayoutPlan.resolve(inputURL: inputURL, decision: pairingDecision)
        }.value

        let minLength = self.minLength
        let maxLength = self.maxLength
        let runClock = ProvenanceRunClock()
        let nativeTool: NativeTool
        let nativeArguments: [String]
        let result: NativeToolResult
        var splitOutcome: FASTQSplitByNameRunner.Outcome?
        switch layoutPlan {
        case .singleEnd, .interleaved:
            let wholePlan = FASTQLengthFilterPlan.make(
                inputPath: inputURL.path,
                outputPath: output.output,
                minLength: minLength,
                maxLength: maxLength,
                pairAware: layoutPlan.isPaired
            )
            result = try await Self.runFilter(wholePlan, runner: runner)
            guard result.isSuccess else {
                throw CLIError.conversionFailed(reason: "\(wholePlan.tool.executableName) length filter failed: \(result.stderr)")
            }
            nativeTool = wholePlan.tool
            nativeArguments = wholePlan.arguments
        case .splitMixed(let pairs, let unpaired):
            let outcome = try await FASTQSplitByNameRunner.run(
                inputURL: inputURL,
                outputPath: output.output,
                counts: FASTQPairInterleaver.MixedCounts(pairs: pairs, unpaired: unpaired),
                tool: .seqkit,
                toolVersion: await runner.getToolVersion(.seqkit) ?? "unknown",
                failureLabel: "length filter",
                stepNamePrefix: "lungfish fastq length-filter"
            ) { partInput, partOutput, paired in
                let partPlan = FASTQLengthFilterPlan.make(
                    inputPath: partInput.path,
                    outputPath: partOutput.path,
                    minLength: minLength,
                    maxLength: maxLength,
                    pairAware: paired
                )
                return (try await Self.runFilter(partPlan, runner: runner), partPlan.arguments)
            }
            nativeTool = .bbduk
            nativeArguments = outcome.pairedRun.arguments
            result = outcome.pairedRun.result
            splitOutcome = outcome
        }
        var cliArguments = ["length-filter"]
        if let minLength { cliArguments += ["--min", String(minLength)] }
        if let maxLength { cliArguments += ["--max", String(maxLength)] }
        cliArguments += pairing.cliArguments
        cliArguments += [resolvedInput.originalURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        var parameters: [String: ParameterValue] = [
            "input": .file(resolvedInput.originalURL),
            "output": .file(outputURL),
            "min": minLength.map(ParameterValue.integer) ?? .null,
            "max": maxLength.map(ParameterValue.integer) ?? .null,
            "pairing": pairing.provenanceValue,
            "interleaved": .boolean(layoutPlan.isPaired),
            "readLayout": pairingDecision.readLayoutProvenanceValue,
            "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
            "force": .boolean(output.force),
            "compress": .boolean(output.compress)
        ]
        if let splitOutcome {
            parameters["pairs"] = .integer(splitOutcome.counts.pairs)
            parameters["unpairedReads"] = .integer(splitOutcome.counts.unpaired)
        }
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq length-filter",
            nativeTool: nativeTool,
            cliArguments: cliArguments,
            nativeArguments: nativeArguments,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: parameters,
            defaults: [
                "min": .null,
                "max": .null,
                "pairing": FASTQPairingOptions.provenanceDefault,
                "interleaved": .boolean(false),
                "readLayout": FASTQPairingOptions.readLayoutProvenanceDefault,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords(),
            stepID: splitOutcome?.stepID ?? UUID(),
            stepInputs: splitOutcome?.stepInputs,
            stepOutputs: splitOutcome?.stepOutputs,
            extraSteps: (splitOutcome?.extraSteps ?? []) + (try resolvedInput.materializationSteps()),
            runClock: runClock
        )
        FileHandle.standardError.write(Data("Filtered reads written to \(output.output)\n".utf8))
    }
}
