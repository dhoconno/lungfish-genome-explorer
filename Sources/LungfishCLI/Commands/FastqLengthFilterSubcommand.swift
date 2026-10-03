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
        // the HG002 fixture. bbduk interleaved=t pairs by position, so only
        // a strictly interleaved input runs pair-aware (mixed input runs as
        // single reads, FASTQPairingOptions).
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, metadataFrom: resolvedInput.pairingMetadataURL)
        let plan = plan(inputURL: inputURL, decision: pairingDecision)

        let startedAt = Date()
        let result: NativeToolResult
        if plan.isPairAware {
            let env = await bbToolsEnvironment(runner: runner)
            result = try await runner.run(plan.tool, arguments: plan.arguments, environment: env, timeout: plan.timeout)
        } else {
            result = try await runner.run(plan.tool, arguments: plan.arguments, timeout: plan.timeout)
        }
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "\(plan.tool.executableName) length filter failed: \(result.stderr)")
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
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq length-filter",
            nativeTool: plan.tool,
            cliArguments: cliArguments,
            nativeArguments: plan.arguments,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "min": minLength.map(ParameterValue.integer) ?? .null,
                "max": maxLength.map(ParameterValue.integer) ?? .null,
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(plan.isPairAware),
                "readLayout": pairingDecision.readLayoutProvenanceValue,
                "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
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
            extraSteps: try resolvedInput.materializationSteps(),
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Filtered reads written to \(output.output)\n".utf8))
    }
}
