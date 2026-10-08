// FastqContaminantFilterSubcommand.swift - Remove contaminant reads using bbduk
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Contaminant Filter

struct FastqContaminantFilterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contaminant-filter",
        abstract: "Remove contaminant reads using bbduk"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("mode"), help: "Filter mode: phix, custom (default: phix)")
    var mode: String = "phix"

    @Option(name: .customLong("ref"), help: "Reference FASTA for custom mode")
    var reference: String?

    @Option(name: .customLong("kmer"), help: "K-mer size (default: 31)")
    var kmerSize: Int = 31

    @Option(name: .customLong("hdist"), help: "Hamming distance tolerance (default: 1)")
    var hammingDistance: Int = 1

    @OptionGroup var pairing: FASTQPairingOptions

    @OptionGroup var output: OutputOptions

    static func bbdukReferenceURL(
        mode: String,
        reference: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        switch mode {
        case "phix":
            guard let phixReference = CoreToolLocator.bbToolsPhiXReferenceURL(homeDirectory: homeDirectory) else {
                throw ValidationError(
                    "PhiX reference not found in managed BBTools resources: \(CoreToolLocator.bbToolsPhiXReferenceFileName)"
                )
            }
            return phixReference
        case "custom":
            guard let reference else {
                throw ValidationError("Custom mode requires --ref")
            }
            guard FileManager.default.fileExists(atPath: reference) else {
                throw CLIError.inputFileNotFound(path: reference)
            }
            return URL(fileURLWithPath: reference)
        default:
            throw ValidationError("Invalid mode: \(mode). Use: phix, custom")
        }
    }

    static func bbdukArguments(
        inputURL: URL,
        outputPath: String,
        mode: String,
        reference: String?,
        kmerSize: Int,
        hammingDistance: Int,
        interleaved: Bool = false,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [String] {
        var args = [
            "in=\(inputURL.path)",
            "out=\(outputPath)",
            "k=\(kmerSize)",
            "hdist=\(hammingDistance)",
        ]
        // bbduk's own name-based pairing guess reports identical-name mates
        // as "processed as unpaired" and splits them, and pairs /1 /2 or
        // Casava names by position, which aborts on a file that mixes merged
        // reads with pairs. So the layout is always stated: interleaved=t
        // treats adjacent records as a pair and, by its default
        // removeifeitherbad=t, discards both mates when either one matches
        // the contaminant, so no orphan survives; interleaved=f judges every
        // record alone.
        args.append(interleaved ? "interleaved=t" : "interleaved=f")

        let referenceURL = try bbdukReferenceURL(mode: mode, reference: reference, homeDirectory: homeDirectory)
        args.append("ref=\(referenceURL.path)")
        return args
    }

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "contaminant-filter", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        guard kmerSize > 0 else { throw ValidationError("--kmer must be > 0") }
        guard hammingDistance >= 0 else { throw ValidationError("--hdist must be >= 0") }
        let runner = NativeToolRunner.shared
        let pairingDecision = pairing.resolvePairing(inputURL: inputURL, metadataFrom: resolvedInput.pairingMetadataURL)
        let isInterleaved = pairingDecision.pairAware

        let args = try Self.bbdukArguments(
            inputURL: inputURL,
            outputPath: output.output,
            mode: mode,
            reference: reference,
            kmerSize: kmerSize,
            hammingDistance: hammingDistance,
            interleaved: isInterleaved
        )

        let env = await bbToolsEnvironment(runner: runner)
        let resolvedReferenceURL = try Self.bbdukReferenceURL(mode: mode, reference: reference)
        let runClock = ProvenanceRunClock()
        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "bbduk contaminant filter failed: \(result.stderr)")
        }
        var cliArguments = ["contaminant-filter", resolvedInput.originalURL.path, "--mode", mode]
        if let reference {
            cliArguments += ["--ref", reference]
        }
        if kmerSize != 31 {
            cliArguments += ["--kmer", String(kmerSize)]
        }
        if hammingDistance != 1 {
            cliArguments += ["--hdist", String(hammingDistance)]
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
            workflowName: "lungfish fastq contaminant-filter",
            nativeTool: .bbduk,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "mode": .string(mode),
                "reference": .file(resolvedReferenceURL),
                "kmer": .integer(kmerSize),
                "hdist": .integer(hammingDistance),
                "pairing": pairing.provenanceValue,
                "interleaved": .boolean(isInterleaved),
                "readLayout": pairingDecision.readLayoutProvenanceValue,
                "readLayoutReason": pairingDecision.readLayoutReasonProvenanceValue,
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "mode": .string("phix"),
                "reference": .null,
                "kmer": .integer(31),
                "hdist": .integer(1),
                "pairing": FASTQPairingOptions.provenanceDefault,
                "interleaved": .boolean(false),
                "readLayout": FASTQPairingOptions.readLayoutProvenanceDefault,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords()
                + provenanceRecords(for: resolvedReferenceURL, format: .fasta, role: .reference),
            extraSteps: try resolvedInput.materializationSteps(),
            runClock: runClock
        )
        FileHandle.standardError.write(Data("Filtered reads written to \(output.output)\n".utf8))
    }
}
