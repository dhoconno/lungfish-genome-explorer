// FastqQualityTrimSubcommand.swift - Trim low-quality bases using fastp
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Quality Trim

struct FastqQualityTrimSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quality-trim",
        abstract: "Trim low-quality bases using fastp"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("threshold"), help: "Quality threshold (default: 20)")
    var threshold: Int = 20

    @Option(name: .customLong("window"), help: "Sliding window size (default: 4)")
    var windowSize: Int = 4

    @Option(name: .customLong("mode"), help: "Trim mode: cut-right, cut-front, cut-tail, cut-both (default: cut-right)")
    var mode: String = "cut-right"

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional fastp arguments passed verbatim"
    )
    var extraArgs: String = ""

    @OptionGroup var pairing: FASTQPairingOptions

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "quality-trim", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        let options = try fastpOptions()

        let runClock = ProvenanceRunClock()
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, pairsByName: true, metadataFrom: resolvedInput.pairingMetadataURL)
        let plan = try await Task.detached(priority: .utility) {
            try FastpReadLayoutPlan.resolve(inputURL: inputURL, decision: pairingDecision)
        }.value
        let outcome = try await FastpPairedRunner.run(
            inputURL: inputURL,
            outputPath: output.output,
            plan: plan,
            options: options,
            detectPairedAdapters: false,
            failureLabel: "fastp quality trim",
            stepNamePrefix: "lungfish fastq quality-trim"
        )
        var cliArguments = ["quality-trim"]
        if threshold != 20 {
            cliArguments += ["--threshold", String(threshold)]
        }
        if windowSize != 4 {
            cliArguments += ["--window", String(windowSize)]
        }
        if mode != "cut-right" {
            cliArguments += ["--mode", mode]
        }
        if !extraArgs.isEmpty {
            cliArguments += ["--extra-args", extraArgs]
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
            workflowName: "lungfish fastq quality-trim",
            nativeTool: .fastp,
            cliArguments: cliArguments,
            nativeArguments: outcome.nativeArguments,
            result: outcome.result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "threshold": .integer(threshold),
                "windowSize": .integer(windowSize),
                "mode": .string(mode),
                "extraArgs": .string(extraArgs),
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
                "windowSize": .integer(4),
                "mode": .string("cut-right"),
                "extraArgs": .string(""),
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
        FileHandle.standardError.write(Data("Quality-trimmed reads written to \(output.output)\n".utf8))
    }

    var extraArguments: [String] {
        (try? AdvancedCommandLineOptions.parse(extraArgs)) ?? []
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
        .quality(threshold: threshold, window: windowSize, mode: try parseQualityTrimMode(mode))
    }

    /// The fastp arguments other than the input and output flags.
    func fastpOptions() throws -> [String] {
        FastpTrimOptions.options(
            for: try trimOperation(),
            extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
        )
    }

    func provenanceRunForTesting(
        inputURL: URL,
        outputURL: URL,
        argv: [String],
        fastpArguments: [String],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) -> WorkflowRun {
        makeProvenanceRun(
            inputURL: inputURL,
            outputURL: outputURL,
            argv: argv,
            fastpArguments: fastpArguments,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr
        )
    }

    private func makeProvenanceRun(
        inputURL: URL,
        outputURL: URL,
        argv: [String],
        fastpArguments: [String],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) -> WorkflowRun {
        let parameters: [String: ParameterValue] = [
            "threshold": .integer(threshold),
            "windowSize": .integer(windowSize),
            "mode": .string(mode),
            "extraArgs": .string(extraArgs),
            "output": .file(outputURL),
        ]
        let recordedAt = Date()
        let step = StepExecution(
            toolName: "fastp",
            toolVersion: "bundled",
            command: fastpArguments,
            inputs: [ProvenanceRecorder.fileRecord(url: inputURL, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, role: .output)],
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            startTime: recordedAt,
            endTime: recordedAt
        )
        return WorkflowRun(
            name: "lungfish fastq quality-trim",
            startTime: recordedAt,
            endTime: recordedAt,
            status: exitCode == 0 ? .completed : .failed,
            steps: [step],
            parameters: parameters.merging([
                "argv": .array(argv.map { .string($0) }),
                "command": .string(argv.map(shellEscape).joined(separator: " ")),
            ]) { current, _ in current }
        )
    }
}
