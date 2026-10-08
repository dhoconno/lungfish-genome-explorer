// FastqDeinterleaveSubcommand.swift - Split interleaved FASTQ into separate R1/R2 files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Deinterleave

struct FastqDeinterleaveSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deinterleave",
        abstract: "Split interleaved FASTQ into separate R1/R2 files",
        discussion: """
            A strictly interleaved file (every record followed by its mate) is \
            split by position with reformat.sh. A file that mixes merged single \
            reads with pairs, such as the output of the VSP2 or Illumina Amplicon \
            Merge recipes, is split by read name instead: each adjacent mate pair \
            goes to --out1 and --out2, and every read without an adjacent mate \
            goes to --unpaired, which is required for such a file. A single-end \
            file is refused.
            """
    )

    @Argument(help: "Input interleaved FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("out1"), help: "Output R1 file (required)")
    var out1: String

    @Option(name: .customLong("out2"), help: "Output R2 file (required)")
    var out2: String

    @Option(
        name: .customLong("unpaired"),
        help: "Output file for reads without an adjacent mate (merged or orphan reads). Required when the input mixes merged reads with pairs."
    )
    var unpaired: String?

    /// The message printed when a mixed file is given without `--unpaired`.
    static func mixedInputRequiresUnpairedMessage(reason: String) -> String {
        "The input mixes merged reads with pairs (\(reason)) Pass --unpaired <file> to receive the reads that have no mate; "
            + "the pairs then go to --out1 and --out2, matched by read name."
    }

    func run() async throws {
        let out1URL = URL(fileURLWithPath: out1)
        let out2URL = URL(fileURLWithPath: out2)
        let unpairedURL = unpaired.map { URL(fileURLWithPath: $0) }
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "deinterleave", contextURL: out1URL)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        var cliArguments = ["deinterleave", resolvedInput.originalURL.path, "--out1", out1, "--out2", out2]
        if let unpaired {
            cliArguments += ["--unpaired", unpaired]
        }

        let resolution = FASTQInputLayoutResolver.resolve(fastqURL: inputURL, metadataFrom: resolvedInput.pairingMetadataURL)
        var parameters: [String: ParameterValue] = [
            "input": .file(resolvedInput.originalURL),
            "out1": .file(out1URL),
            "out2": .file(out2URL),
            "unpaired": unpairedURL.map(ParameterValue.file) ?? .null,
            "readLayout": .string(resolution.layout.rawValue),
            "readLayoutReason": .string(resolution.reason),
        ]

        switch resolution.layout {
        case .strictlyInterleaved:
            let runner = NativeToolRunner.shared
            let args = [
                "in=\(inputURL.path)",
                "out1=\(out1)",
                "out2=\(out2)",
                "interleaved=t",
            ]
            let env = await bbToolsEnvironment(runner: runner)
            let runClock = ProvenanceRunClock()
            let result = try await runner.run(.reformat, arguments: args, environment: env, timeout: 1800)
            guard result.isSuccess else {
                throw CLIError.conversionFailed(reason: "reformat.sh deinterleave failed: \(result.stderr)")
            }
            if let unpairedURL {
                // Nothing lacks a mate; leave an empty file so a script that
                // asked for the third output finds it.
                FileManager.default.createFile(atPath: unpairedURL.path, contents: nil)
            }
            try await recordFASTQNativeToolProvenance(
                workflowName: "lungfish fastq deinterleave",
                nativeTool: .reformat,
                cliArguments: cliArguments,
                nativeArguments: args,
                result: result,
                inputURLs: [resolvedInput.originalURL],
                outputURLs: [out1URL, out2URL] + (unpairedURL.map { [$0] } ?? []),
                parameters: parameters,
                inputRecords: try resolvedInput.inputRecords(),
                extraSteps: try resolvedInput.materializationSteps(),
                runClock: runClock
            )
            FileHandle.standardError.write(Data("Deinterleaved: R1 → \(out1), R2 → \(out2)\n".utf8))

        case .mixedMergedAndPairs:
            guard let unpairedURL else {
                throw ValidationError(Self.mixedInputRequiresUnpairedMessage(reason: resolution.reason))
            }
            let runClock = ProvenanceRunClock()
            let counts = try await Self.partitionMixedInput(
                inputURL: inputURL,
                out1: out1URL,
                out2: out2URL,
                unpaired: unpairedURL
            )
            parameters["pairs"] = .integer(counts.pairs)
            parameters["unpairedReads"] = .integer(counts.unpaired)
            let outputs = [out1URL, out2URL, unpairedURL]
            _ = try await CLIProvenanceSupport.recordSingleStepRun(
                name: "lungfish fastq deinterleave",
                parameters: parameters,
                toolName: "lungfish",
                toolVersion: WorkflowRun.currentAppVersion,
                command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
                stepCommand: ["LungfishWorkflow", "partition-mixed-fastq", inputURL.path, out1, out2, unpairedURL.path],
                extraSteps: try resolvedInput.materializationSteps(),
                inputs: try resolvedInput.inputRecords(),
                outputs: outputs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) },
                exitCode: 0,
                wallTime: runClock.elapsed,
                stderr: nil,
                status: .completed,
                outputDirectory: out1URL.deletingLastPathComponent()
            )
            FileHandle.standardError.write(Data(
                "Deinterleaved by read name: \(counts.pairs) pairs → \(out1) and \(out2), \(counts.unpaired) reads without a mate → \(unpairedURL.path)\n".utf8
            ))

        case .singleEnd, .pairedFiles:
            throw ValidationError(
                "The input is not interleaved (\(resolution.reason)) Nothing was written."
            )
        }
    }

    /// Splits a mixed file by read name, gzipping any output whose name ends
    /// in `.gz`. Exposed for tests.
    static func partitionMixedInput(
        inputURL: URL,
        out1: URL,
        out2: URL,
        unpaired: URL
    ) async throws -> FASTQPairInterleaver.MixedCounts {
        let fm = FileManager.default
        let targets = [out1, out2, unpaired]
        // Write plain text first; compress afterwards where the name asks.
        let plainTargets = targets.map { target -> URL in
            target.pathExtension.lowercased() == "gz"
                ? target.deletingLastPathComponent()
                    .appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent).\(UUID().uuidString)")
                : target
        }
        var handles: [FileHandle] = []
        for plain in plainTargets {
            fm.createFile(atPath: plain.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: plain.path) else {
                throw CLIError.conversionFailed(reason: "Cannot open \(plain.path) for writing")
            }
            handles.append(handle)
        }
        let counts: FASTQPairInterleaver.MixedCounts
        do {
            counts = try FASTQPairInterleaver.partitionMixed(
                interleaved: inputURL,
                r1: handles[0],
                r2: handles[1],
                unpaired: handles[2]
            )
        } catch {
            for handle in handles { try? handle.close() }
            for plain in plainTargets { try? fm.removeItem(at: plain) }
            throw error
        }
        for handle in handles { try? handle.close() }

        for (plain, target) in zip(plainTargets, targets) where plain != target {
            _ = try gzipCompressFASTQ(
                sourceURL: plain,
                outputURL: target,
                failureDescription: "deinterleaved output"
            )
            try? fm.removeItem(at: plain)
        }
        return counts
    }
}
