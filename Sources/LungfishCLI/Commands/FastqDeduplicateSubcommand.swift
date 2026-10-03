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

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "deduplicate", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        let runner = NativeToolRunner.shared
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, metadataFrom: resolvedInput.pairingMetadataURL)
        let isInterleaved = pairingDecision.pairAware

        let heapGB = ManagedJavaHeapPolicy.heapGB(minimumGB: 1)
        var args = [
            "in=\(inputURL.path)",
            "out=\(output.output)",
            "-Xmx\(heapGB)g",
            "dedupe=t",
            "subs=\(substitutions)",
            "ow=t"
        ]
        // interleaved=t: clumpify compares and clusters whole pairs and writes
        // both mates of every surviving pair adjacent to each other.
        // interleaved=f is stated for the single-read case so clumpify's own
        // name detection cannot pair a mixed file by position.
        args.append(isInterleaved ? "interleaved=t" : "interleaved=f")
        if optical {
            args.append("optical=t")
            args.append("dupedist=\(opticalDistance)")
        }

        let startedAt = Date()
        let result = try await runner.run(.clumpify, arguments: args)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "clumpify deduplication failed: \(result.stderr)")
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
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq deduplicate",
            nativeTool: .clumpify,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "subs": .integer(substitutions),
                "optical": .boolean(optical),
                "dupedist": .integer(opticalDistance),
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(isInterleaved),
                "readLayout": pairingDecision.readLayoutProvenanceValue,
                "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
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
            extraSteps: try resolvedInput.materializationSteps(),
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Deduplicated reads written to \(output.output)\n".utf8))
    }
}
