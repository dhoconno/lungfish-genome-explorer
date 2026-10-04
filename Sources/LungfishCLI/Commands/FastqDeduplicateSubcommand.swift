// FastqDeduplicateSubcommand.swift - Remove duplicate reads using clumpify.sh (BBTools)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Deduplicate

struct FastqDeduplicateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deduplicate",
        abstract: "Remove duplicate reads using clumpify.sh (BBTools)"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("subs"), help: "Substitution tolerance (0=exact, 2=default)")
    var substitutions: Int = 0

    @Flag(name: .customLong("optical"), help: "Optical duplicate mode (patterned flowcells)")
    var optical: Bool = false

    @Option(name: .customLong("dupedist"), help: "Pixel distance for optical duplicates (default: 40)")
    var opticalDistance: Int = 40

    @OptionGroup var pairing: FASTQPairingOptions

    @OptionGroup var output: OutputOptions

    /// The clumpify argv for one run.
    ///
    /// interleaved=t: clumpify compares and clusters whole pairs and writes
    /// both mates of every surviving pair adjacent to each other.
    /// interleaved=f is stated for single reads so clumpify's own name
    /// detection cannot pair a file by position.
    static func clumpifyArguments(
        input: String,
        output: String,
        heapGB: Int,
        substitutions: Int,
        interleaved: Bool,
        optical: Bool,
        opticalDistance: Int
    ) -> [String] {
        var args = [
            "in=\(input)",
            "out=\(output)",
            "-Xmx\(heapGB)g",
            "dedupe=t",
            "subs=\(substitutions)",
            "ow=t"
        ]
        args.append(interleaved ? "interleaved=t" : "interleaved=f")
        if optical {
            args.append("optical=t")
            args.append("dupedist=\(opticalDistance)")
        }
        return args
    }

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "deduplicate", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        let runner = NativeToolRunner.shared
        // A strictly interleaved file is deduplicated by whole pairs and a
        // single-end file read by read, in one clumpify run each. A file
        // that mixes pairs with single reads is partitioned by name: clumpify
        // pairs by position, so run as single reads it separated every mate
        // from its partner and dropped one mate of a pair whose other mate
        // differed. Its pairs are deduplicated as pairs and its single reads
        // as single reads, then joined (FASTQSplitByNameRunner).
        let pairingDecision = pairing.resolvePairing(
            inputURL: inputURL,
            pairsByName: true,
            metadataFrom: resolvedInput.pairingMetadataURL
        )
        let plan = try await Task.detached(priority: .utility) {
            try FastpReadLayoutPlan.resolve(inputURL: inputURL, decision: pairingDecision)
        }.value

        let heapGB = ManagedJavaHeapPolicy.heapGB(minimumGB: 1)
        let substitutions = self.substitutions
        let optical = self.optical
        let opticalDistance = self.opticalDistance
        let startedAt = Date()
        let args: [String]
        let result: NativeToolResult
        var splitOutcome: FASTQSplitByNameRunner.Outcome?
        switch plan {
        case .singleEnd, .interleaved:
            args = Self.clumpifyArguments(
                input: inputURL.path,
                output: output.output,
                heapGB: heapGB,
                substitutions: substitutions,
                interleaved: plan.isPaired,
                optical: optical,
                opticalDistance: opticalDistance
            )
            result = try await runner.run(.clumpify, arguments: args)
            guard result.isSuccess else {
                throw CLIError.conversionFailed(reason: "clumpify deduplication failed: \(result.stderr)")
            }
        case .splitMixed(let pairs, let unpaired):
            let outcome = try await FASTQSplitByNameRunner.run(
                inputURL: inputURL,
                outputPath: output.output,
                counts: FASTQPairInterleaver.MixedCounts(pairs: pairs, unpaired: unpaired),
                tool: .clumpify,
                toolVersion: await runner.getToolVersion(.clumpify) ?? "unknown",
                failureLabel: "clumpify deduplication",
                stepNamePrefix: "lungfish fastq deduplicate"
            ) { partInput, partOutput, paired in
                let partArgs = Self.clumpifyArguments(
                    input: partInput.path,
                    output: partOutput.path,
                    heapGB: heapGB,
                    substitutions: substitutions,
                    interleaved: paired,
                    optical: optical,
                    opticalDistance: opticalDistance
                )
                return (try await runner.run(.clumpify, arguments: partArgs), partArgs)
            }
            args = outcome.pairedRun.arguments
            result = outcome.pairedRun.result
            splitOutcome = outcome
        }
        var cliArguments = ["deduplicate", resolvedInput.originalURL.path]
        if substitutions != 0 {
            cliArguments += ["--subs", String(substitutions)]
        }
        if optical {
            cliArguments.append("--optical")
        }
        if opticalDistance != 40 {
            cliArguments += ["--dupedist", String(opticalDistance)]
        }
        cliArguments += pairing.cliArguments
        cliArguments += ["--output", output.output]
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
            "subs": .integer(substitutions),
            "optical": .boolean(optical),
            "dupedist": .integer(opticalDistance),
            "pairing": pairing.provenanceValue,
            "interleaved": .boolean(plan.isPaired),
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
            workflowName: "lungfish fastq deduplicate",
            nativeTool: .clumpify,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: parameters,
            defaults: [
                "subs": .integer(0),
                "optical": .boolean(false),
                "dupedist": .integer(40),
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
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Deduplicated reads written to \(output.output)\n".utf8))
    }
}
