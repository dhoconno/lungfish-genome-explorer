// FASTQSplitByNameRunner.swift - Runs a tool on the mate pairs and the single reads of a mixed FASTQ apart
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A tool that pairs records by position (BBTools `interleaved=t`, cutadapt
// `--interleaved`) mis-pairs a file that mixes adjacent mate pairs with
// single reads, and the same tool run per record judges each mate alone, so
// a mate it drops orphans its partner. This runner gives such a tool a mixed
// file the way FastpPairedRunner gives one to fastp and the import clumpify
// step to clumpify. The file is partitioned by NAME
// (FASTQPairInterleaver.partitionMixed) into a strictly interleaved file of
// pairs and a file of single reads. The caller runs its tool on each, the
// pairs in the tool's paired mode and the single reads in its single mode.
// The two outputs are joined, pairs first, and the joined record count is
// checked against the two outputs before the run is reported done.

import Foundation
import LungfishCore
import LungfishIO

/// A split-by-name run that did not finish, with the message the caller shows.
public struct FASTQSplitByNameRunError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum FASTQSplitByNameRunner {
    /// Runs the caller's tool on one part of the split input and returns its
    /// result and its argv without the executable. `paired` is true for the
    /// strictly interleaved file of mate pairs.
    public typealias PartRunner = @Sendable (
        _ input: URL,
        _ output: URL,
        _ paired: Bool
    ) async throws -> (result: NativeToolResult, arguments: [String])

    /// One tool run on one part of the split input.
    public struct PartRun: Sendable {
        public let result: NativeToolResult
        /// The argv without the executable.
        public let arguments: [String]
        public let inputURL: URL
        public let outputURL: URL
        public let startedAt: Date
        public let completedAt: Date
    }

    /// What ``run(inputURL:outputPath:counts:tool:toolVersion:failureLabel:stepNamePrefix:runPart:)`` did.
    public struct Outcome: Sendable {
        /// The pairs and single reads the input was split into.
        public let counts: FASTQPairInterleaver.MixedCounts
        /// The run on the mate pairs, recorded as the operation's main step.
        public let pairedRun: PartRun
        /// The run on the single reads.
        public let singleRun: PartRun
        /// Provenance ID of the paired run, so the extra steps can depend on it.
        public let stepID: UUID
        /// The files the paired run read and wrote.
        public let stepInputs: [FileRecord]
        public let stepOutputs: [FileRecord]
        /// The single-read run, the join and any gzip, in dependency order.
        public let extraSteps: [ProvenanceStep]
    }

    /// Splits `inputURL` by name, runs `runPart` on its pairs and on its
    /// single reads, and writes the joined result to `outputPath`, gzip
    /// compressed when the path ends in `.gz`.
    ///
    /// - Parameters:
    ///   - counts: the by-name counts of `inputURL`
    ///     (``FASTQPairInterleaver/countMixed(interleaved:)``). The split must
    ///     reproduce them, so a file that changed underneath fails the run.
    ///   - tool: the tool `runPart` runs, and `toolVersion` its version, for
    ///     the single-read run's provenance step.
    ///   - failureLabel: names the operation in a thrown error.
    ///   - stepNamePrefix: names the join step in provenance.
    public static func run(
        inputURL: URL,
        outputPath: String,
        counts: FASTQPairInterleaver.MixedCounts,
        tool: NativeTool,
        toolVersion: String,
        failureLabel: String,
        stepNamePrefix: String,
        runPart: PartRunner
    ) async throws -> Outcome {
        let fm = FileManager.default
        let outputURL = URL(fileURLWithPath: outputPath)
        let scratch = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".split-by-name-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let pairsIn = scratch.appendingPathComponent("in_pairs.fastq")
        let singlesIn = scratch.appendingPathComponent("in_single.fastq")
        try await Task.detached(priority: .utility) {
            for url in [pairsIn, singlesIn] {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let pairsHandle = try FileHandle(forWritingTo: pairsIn)
            defer { try? pairsHandle.close() }
            let singlesHandle = try FileHandle(forWritingTo: singlesIn)
            defer { try? singlesHandle.close() }
            let split = try FASTQPairInterleaver.partitionMixed(
                interleaved: inputURL, pairs: pairsHandle, unpaired: singlesHandle
            )
            guard split == counts else {
                throw FASTQSplitByNameRunError(
                    "the pair scan found \(counts.pairs) pairs and \(counts.unpaired) single reads, but the split wrote \(split.pairs) and \(split.unpaired)"
                )
            }
        }.value

        let pairsOut = scratch.appendingPathComponent("out_pairs.fastq")
        let singlesOut = scratch.appendingPathComponent("out_single.fastq")
        let pairedRun = try await runOnePart(
            input: pairsIn, output: pairsOut, paired: true,
            what: "the mate pairs", failureLabel: failureLabel, runPart: runPart
        )
        let singleRun = try await runOnePart(
            input: singlesIn, output: singlesOut, paired: false,
            what: "the single reads", failureLabel: failureLabel, runPart: runPart
        )

        let stepID = UUID()
        let singleStep = ProvenanceStep(
            toolName: tool.rawValue,
            toolVersion: toolVersion,
            argv: singleRun.result.arguments.isEmpty
                ? [tool.executableName] + singleRun.arguments
                : singleRun.result.arguments,
            inputs: [descriptor(singlesIn, role: .input)],
            outputs: [descriptor(singlesOut, role: .output)],
            exitStatus: Int(singleRun.result.exitCode),
            wallTimeSeconds: singleRun.completedAt.timeIntervalSince(singleRun.startedAt),
            stderr: singleRun.result.stderr.isEmpty ? nil : singleRun.result.stderr,
            startedAt: singleRun.startedAt,
            completedAt: singleRun.completedAt
        )

        // Join the pairs and the single reads, pairs first, into the plain
        // output or into a scratch file that gzip then writes.
        let compress = outputPath.lowercased().hasSuffix(".gz")
        let plainTarget = compress ? scratch.appendingPathComponent("joined.fastq") : outputURL
        let joinStarted = Date()
        let expected = try await Task.detached(priority: .utility) {
            try join([pairsOut, singlesOut], into: plainTarget)
        }.value
        let written = try await Task.detached(priority: .utility) {
            try FASTQPairInterleaver.countRecords(in: plainTarget)
        }.value
        guard written == expected else {
            throw FASTQSplitByNameRunError(
                "\(failureLabel) wrote \(written) reads where \(expected) were expected after joining the pairs and the single reads"
            )
        }
        let joinCompleted = Date()
        let joinStep = ProvenanceStep(
            toolName: "\(stepNamePrefix) join",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: ["/bin/cat", pairsOut.path, singlesOut.path],
            inputs: [descriptor(pairsOut, role: .input), descriptor(singlesOut, role: .input)],
            outputs: [descriptor(plainTarget, role: .output)],
            exitStatus: 0,
            wallTimeSeconds: joinCompleted.timeIntervalSince(joinStarted),
            dependsOn: [stepID, singleStep.id],
            startedAt: joinStarted,
            completedAt: joinCompleted
        )
        var extraSteps = [singleStep, joinStep]

        if compress {
            let gzip = try gzipCompressFASTQ(
                sourceURL: plainTarget,
                outputURL: outputURL,
                failureDescription: "the joined reads of"
            )
            let gzipCompleted = Date()
            extraSteps.append(ProvenanceStep(
                toolName: gzip.command.first ?? "/usr/bin/gzip",
                toolVersion: "system",
                argv: gzip.command,
                inputs: [descriptor(plainTarget, role: .input)],
                outputs: [descriptor(outputURL, role: .output)],
                exitStatus: Int(gzip.exitCode),
                wallTimeSeconds: gzip.wallTime,
                stderr: gzip.stderr?.isEmpty == false ? gzip.stderr : nil,
                dependsOn: [joinStep.id],
                startedAt: gzipCompleted.addingTimeInterval(-gzip.wallTime),
                completedAt: gzipCompleted
            ))
        }

        return Outcome(
            counts: counts,
            pairedRun: pairedRun,
            singleRun: singleRun,
            stepID: stepID,
            stepInputs: [ProvenanceRecorder.fileRecord(url: pairsIn, format: .fastq, role: .input)],
            stepOutputs: [ProvenanceRecorder.fileRecord(url: pairsOut, format: .fastq, role: .output)],
            extraSteps: extraSteps
        )
    }

    private static func runOnePart(
        input: URL,
        output: URL,
        paired: Bool,
        what: String,
        failureLabel: String,
        runPart: PartRunner
    ) async throws -> PartRun {
        let startedAt = Date()
        let run = try await runPart(input, output, paired)
        let completedAt = Date()
        guard run.result.isSuccess else {
            throw FASTQSplitByNameRunError("\(failureLabel) failed on \(what): \(run.result.stderr)")
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw FASTQSplitByNameRunError("\(failureLabel) wrote no output for \(what)")
        }
        return PartRun(
            result: run.result,
            arguments: run.arguments,
            inputURL: input,
            outputURL: output,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// Writes `parts` one after another into `target` and returns how many
    /// records they hold together.
    private static func join(_ parts: [URL], into target: URL) throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        fm.createFile(atPath: target.path, contents: nil)
        let sink = try FileHandle(forWritingTo: target)
        defer { try? sink.close() }
        var records = 0
        for part in parts {
            records += try FASTQPairInterleaver.countRecords(in: part)
            let source = try FileHandle(forReadingFrom: part)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                try sink.write(contentsOf: chunk)
            }
        }
        return records
    }

    private static func descriptor(_ url: URL, role: FileRole) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: role))
    }
}
