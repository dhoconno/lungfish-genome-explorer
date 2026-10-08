// FastqEntropyFilterSubcommand.swift - Remove low-complexity reads using the bbduk entropy filter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Low-Complexity (Entropy) Filter

struct FastqEntropyFilterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entropy-filter",
        abstract: "Remove low-complexity reads using the bbduk entropy filter",
        discussion: """
            Discards reads whose Shannon entropy falls below a threshold. This
            catches homopolymer runs and tandem repeats (for example ATCATCATC…)
            that per-read complexity metrics miss, and that otherwise inflate
            apparent mapping depth.

            Defaults are entropy 0.6, window 50, k-mer 5, and 4 bbduk threads (--threads).
            """
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("entropy"), help: "Entropy threshold, 0.3-0.9 (default: 0.6)")
    var entropy: Double = FASTQEntropyFilterDefaults.entropy

    @Option(name: .customLong("window"), help: "Entropy sliding window in bases (default: 50)")
    var window: Int = FASTQEntropyFilterDefaults.window

    @Option(name: .customLong("kmer"), help: "K-mer length for entropy estimation (default: 5)")
    var kmer: Int = FASTQEntropyFilterDefaults.kmer

    @OptionGroup var globalOptions: GlobalOptions
    var threads: Int { globalOptions.threads ?? 4 }

    @OptionGroup var pairing: FASTQPairingOptions

    @OptionGroup var output: OutputOptions

    /// Validates the entropy parameters. Factored out so tests can exercise the
    /// bounds without running bbduk.
    static func validate(entropy: Double, window: Int, kmer: Int) throws {
        guard FASTQEntropyFilterDefaults.isValidEntropy(entropy) else {
            throw ValidationError(
                "--entropy must be between \(FASTQEntropyFilterDefaults.minimumEntropy) and \(FASTQEntropyFilterDefaults.maximumEntropy)"
            )
        }
        guard window > 0 else { throw ValidationError("--window must be > 0") }
        guard kmer > 0 else { throw ValidationError("--kmer must be > 0") }
    }

    /// Builds the bbduk argument vector. No reference is involved: entropy
    /// filtering is purely sequence-composition based.
    static func bbdukArguments(
        inputURL: URL,
        outputPath: String,
        entropy: Double,
        window: Int,
        kmer: Int,
        threads: Int,
        heapGB: Int,
        interleaved: Bool = false
    ) -> [String] {
        var args = [
            "in=\(inputURL.path)",
            "out=\(outputPath)",
            "-Xmx\(heapGB)g",
            "entropy=\(entropyArgument(entropy))",
            "entropywindow=\(window)",
            "entropyk=\(kmer)",
            "threads=\(threads)",
            "ow=t",
        ]
        // Pair-aware: bbduk drops both mates when either falls below the
        // entropy threshold (removeifeitherbad=t), so the output never
        // holds an orphan. The layout is always stated: left to its own
        // detection bbduk splits identical-name mates and pairs /1 /2 or
        // Casava names by position, which aborts on a mixed file.
        args.append(interleaved ? "interleaved=t" : "interleaved=f")
        return args
    }

    /// Formats the entropy threshold without trailing zeros so the recorded
    /// command matches what the GUI shows.
    static func entropyArgument(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") && !text.hasSuffix(".0") {
            text.removeLast()
        }
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        return text
    }

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "entropy-filter", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        try Self.validate(entropy: entropy, window: window, kmer: kmer)
        guard threads > 0 else { throw ValidationError("--threads must be > 0") }

        let runner = NativeToolRunner.shared
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, metadataFrom: resolvedInput.pairingMetadataURL)
        let isInterleaved = pairingDecision.pairAware
        let heapGB = ManagedJavaHeapPolicy.heapGB(minimumGB: 4)
        let args = Self.bbdukArguments(
            inputURL: inputURL,
            outputPath: output.output,
            entropy: entropy,
            window: window,
            kmer: kmer,
            threads: threads,
            heapGB: heapGB,
            interleaved: isInterleaved
        )

        let env = await bbToolsEnvironment(runner: runner)
        let runClock = ProvenanceRunClock()
        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "bbduk entropy filter failed: \(result.stderr)")
        }

        let summary = BBDukEntropySummary(stderr: result.stderr)

        var cliArguments = [
            "entropy-filter", resolvedInput.originalURL.path,
            "--entropy", Self.entropyArgument(entropy),
        ]
        if window != FASTQEntropyFilterDefaults.window {
            cliArguments += ["--window", String(window)]
        }
        if kmer != FASTQEntropyFilterDefaults.kmer {
            cliArguments += ["--kmer", String(kmer)]
        }
        if threads != 4 {
            cliArguments += ["--threads", String(threads)]
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
            "entropy": .number(entropy),
            "entropyWindow": .integer(window),
            "entropyKmer": .integer(kmer),
            "threads": .integer(threads),
            "pairing": pairing.provenanceValue,
            "interleaved": .boolean(isInterleaved),
            "readLayout": pairingDecision.readLayoutProvenanceValue,
            "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
            "force": .boolean(output.force),
            "compress": .boolean(output.compress),
        ]
        if let summary {
            parameters["inputReads"] = .integer(summary.inputReads)
            parameters["discardedReads"] = .integer(summary.discardedReads)
            parameters["outputReads"] = .integer(summary.outputReads)
        }

        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq entropy-filter",
            nativeTool: .bbduk,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: parameters,
            defaults: [
                "entropy": .number(FASTQEntropyFilterDefaults.entropy),
                "entropyWindow": .integer(FASTQEntropyFilterDefaults.window),
                "entropyKmer": .integer(FASTQEntropyFilterDefaults.kmer),
                "threads": .integer(4),
                "pairing": FASTQPairingOptions.provenanceDefault,
                "interleaved": .boolean(false),
                "readLayout": FASTQPairingOptions.readLayoutProvenanceDefault,
                "force": .boolean(false),
                "compress": .boolean(false),
            ],
            inputRecords: try resolvedInput.inputRecords(),
            extraSteps: try resolvedInput.materializationSteps(),
            runClock: runClock
        )

        if let summary {
            FileHandle.standardError.write(Data("\(summary.displaySummary)\n".utf8))
        }
        FileHandle.standardError.write(
            Data("Low-complexity filtered reads written to \(output.output)\n".utf8)
        )
    }
}
